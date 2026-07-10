import Foundation
import Domain

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Transfers completed sessions between the Watch and iPhone over WatchConnectivity.
///
/// The watch enqueues finished `DiveSession`s via `transferUserInfo`, which is
/// background-safe: the OS delivers them even if the phone is unreachable or the
/// watch app is suspended. On top of that this manager tracks each payload until
/// the system confirms delivery (`didFinish`), retries failed transfers, and
/// re-sends anything still outstanding when reachability returns — and exposes a
/// `pendingCount` so the UI can show a pending/synced badge.
///
/// All WatchConnectivity access goes through the injectable `performTransfer`
/// seam, keeping the queue/retry/status logic unit-testable without a real
/// `WCSession`.
public final class SyncManager: NSObject, @unchecked Sendable {
    /// Called on the phone when a session arrives from the watch.
    public var onReceiveSession: (@Sendable (DiveSession) -> Void)?

    /// Called on the phone when the watch deletes a session (by id), so the phone
    /// drops its copy too. WatchConnectivity only *sends* sessions, so a deletion
    /// rides its own lightweight message (`deletedKey`).
    public var onDeleteSession: (@Sendable (UUID) -> Void)?

    /// Called on the phone after a voice-note file has been received and stored
    /// (passed the stored URL). The file is already copied into `audioDirectory`.
    public var onReceiveAudioFile: (@Sendable (URL) -> Void)?

    /// Directory the receiver copies incoming voice-note files into (set by the
    /// phone app). When `nil`, incoming files are ignored.
    public var audioDirectory: URL?

    /// Called on the watch when the iPhone's custom-marker definitions change.
    public var onReceiveCustomMarkers: (@Sendable ([MarkerKind]) -> Void)?

    /// Called on the watch when the iPhone's units preference changes.
    public var onReceiveUnitPreference: (@Sendable (UnitPreference) -> Void)?

    /// Called on the watch when the iPhone's dive-detection config changes.
    public var onReceiveDetectionConfig: (@Sendable (DiveDetectionConfig) -> Void)?

    /// Called on the phone with each live snapshot of an in-progress Watch session
    /// (#118). Coalesced latest-value over the application context, so the phone
    /// can drive an in-app banner + Live Activity and keep the last value while the
    /// Watch is out of range.
    public var onReceiveLiveSession: (@Sendable (LiveSessionSnapshot) -> Void)?

    /// Notified with the new pending count whenever transfer status changes.
    /// Fires on an arbitrary thread; hop to the main actor before touching UI.
    public var onPendingCountChange: (@Sendable (Int) -> Void)?

    /// Notified with a session's id once its transfer is **confirmed delivered**
    /// to the counterpart device — the safe signal watch-side retention uses to
    /// know a session is on the phone and may be pruned locally. Fires on an
    /// arbitrary thread.
    public var onSessionDelivered: (@Sendable (UUID) -> Void)?

    /// Notified with a voice-note file name once its transfer is **confirmed
    /// delivered** to the counterpart device — the safe signal watch-side
    /// retention uses to know a clip is on the phone before pruning the session
    /// that references it. Fires on an arbitrary thread.
    public var onAudioFileDelivered: (@Sendable (String) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    static let payloadKey = "session"
    static let idKey = "id"
    static let markersKey = "customMarkers"
    static let unitsKey = "unitPreference"
    static let detectionKey = "diveDetectionConfig"
    static let fileNameKey = "fileName"
    static let deletedKey = "deletedSessionID"
    static let liveSessionKey = "liveSession"

    private let lock = NSLock()
    /// A payload sent but not yet confirmed delivered. Carries the session id so
    /// `sendDeletion`/`completeTransfer` need not JSON-decode `data` to identify it.
    private struct Pending {
        let sessionID: UUID
        /// The latest encoded payload for this session. Mutable so a dedupe nudge
        /// (`send` of an already-pending session) can refresh it — watch sessions
        /// mutate after save (e.g. the geocode backfill sets `locationName`, part of
        /// the Codable payload), and the fresh encode must win over the stale one.
        var data: Data
        /// True while the OS still owns this transfer's queue slot — set on entries
        /// re-adopted from `outstandingUserInfoTransfers` at activation. Such entries
        /// must not be re-`performTransfer`ed (that would enqueue a duplicate); they
        /// become ours (`false`) once their `didFinish` arrives.
        var isSystemOwned: Bool
    }
    /// Payloads sent but not yet confirmed delivered, keyed by transfer id.
    private var pending: [String: Pending] = [:]
    /// Immediate re-send attempts per payload, to bound retry storms.
    private var attempts: [String: Int] = [:]
    /// Session ids deleted this launch. A tombstone closes the snapshot window in
    /// `retryPending`/`completeTransfer` (which snapshot under the lock but
    /// `performTransfer` after unlocking): a deletion that lands in between must not
    /// let the deleted session's payload be re-enqueued *after* the deletion message
    /// and resurrected on the phone. In-memory / process-lifetime; growth is bounded
    /// by the user's deletions (rare), so no eviction is needed.
    private var deletedSessionIDs: Set<UUID> = []
    /// Latest application-context entries we tried to send (markers and/or units),
    /// re-applied on activation. `updateApplicationContext` replaces the whole
    /// dictionary, so both kinds of state must travel together.
    private var outgoingContext: [String: Any] = [:]
    /// After this many back-to-back failures a payload stops auto-retrying and
    /// waits for the next reachability-driven `retryPending`, rather than looping.
    private static let maxImmediateRetries = 5

    /// Hands a payload to the transport. Defaults to `WCSession.transferUserInfo`;
    /// tests inject a stub.
    private let performTransfer: (_ id: String, _ data: Data) -> Void

    /// Replaces the shared application context (latest-wins). Defaults to
    /// `WCSession.updateApplicationContext`; tests inject a stub.
    private let applyContext: (_ context: [String: Any]) -> Void

    /// Sends a session deletion. Defaults to `WCSession.transferUserInfo`; tests
    /// inject a stub.
    private let performDeletion: (_ id: UUID) -> Void

    /// Cancels the OS's still-queued userInfo transfers whose transfer id is in
    /// the set. Defaults to filtering `WCSession.outstandingUserInfoTransfers` by
    /// matching `Self.idKey` and calling `cancel()`; tests inject a stub. Used by
    /// `sendDeletion` so a deleted session's not-yet-delivered payload can't be
    /// re-adopted after a relaunch and resurrected.
    private let cancelTransfers: (_ ids: Set<String>) -> Void

    /// The system's still-queued userInfo transfers, as `(id, payload)` pairs.
    /// Defaults to mapping `WCSession.outstandingUserInfoTransfers`; tests inject a
    /// stub. Used at activation to re-adopt transfers that outlived a relaunch.
    private let outstandingTransfers: () -> [(id: String, data: Data)]

    /// Hands a voice-note file to the transport. Defaults to
    /// `WCSession.transferFile`, guarded by `WCSession.isSupported()`; tests inject
    /// a stub so the confirmed-delivery/retry logic is unit-testable without a real
    /// `WCSession`.
    private let performFileTransfer: (_ url: URL, _ metadata: [String: Any]) -> Void

    /// Sessions queued but not yet confirmed delivered.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public init(
        performTransfer: ((_ id: String, _ data: Data) -> Void)? = nil,
        applyContext: ((_ context: [String: Any]) -> Void)? = nil,
        performDeletion: ((_ id: UUID) -> Void)? = nil,
        cancelTransfers: ((_ ids: Set<String>) -> Void)? = nil,
        outstandingTransfers: (() -> [(id: String, data: Data)])? = nil,
        performFileTransfer: ((_ url: URL, _ metadata: [String: Any]) -> Void)? = nil
    ) {
        // Each default transport guards WCSession.isSupported(): WatchConnectivity
        // imports on iPad (canImport is true) but isn't supported there, and calling
        // these on an unactivated session raises an exception. iPad gets its data via
        // CloudKit (#168/#170), so these are correctly no-ops on it.
        self.performTransfer = performTransfer ?? { id, data in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            WCSession.default.transferUserInfo([Self.payloadKey: data, Self.idKey: id])
            #endif
        }
        self.applyContext = applyContext ?? { context in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            try? WCSession.default.updateApplicationContext(context)
            #endif
        }
        self.performDeletion = performDeletion ?? { id in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            WCSession.default.transferUserInfo([Self.deletedKey: id.uuidString])
            #endif
        }
        self.cancelTransfers = cancelTransfers ?? { ids in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            for transfer in WCSession.default.outstandingUserInfoTransfers
            where (transfer.userInfo[Self.idKey] as? String).map(ids.contains) == true {
                transfer.cancel()
            }
            #endif
        }
        self.outstandingTransfers = outstandingTransfers ?? {
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return [] }
            // Skip deletion messages: they carry `deletedKey` only, no `payloadKey`.
            return WCSession.default.outstandingUserInfoTransfers.compactMap {
                Self.sessionTransfer(from: $0.userInfo)
            }
            #else
            return []
            #endif
        }
        self.performFileTransfer = performFileTransfer ?? { url, metadata in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            WCSession.default.transferFile(url, metadata: metadata)
            #endif
        }
        super.init()
    }

    /// Extracts a session-transfer payload from a userInfo dictionary, or `nil`
    /// for non-session messages (deletions carry `deletedKey` only). Shared by
    /// outstanding-transfer adoption and `didFinish` so the two can never
    /// disagree about the wire shape.
    static func sessionTransfer(from userInfo: [String: Any]) -> (id: String, data: Data)? {
        guard let id = userInfo[Self.idKey] as? String,
              let data = userInfo[Self.payloadKey] as? Data else { return nil }
        return (id, data)
    }

    // MARK: - Preferences (phone → watch)

    /// Pushes the current custom-marker definitions to the counterpart device.
    /// Uses the application context (latest-wins), delivered in the background.
    /// The context is also retained and re-applied once the session activates,
    /// since a call made before activation (e.g. right at launch) is dropped.
    public func sendCustomMarkers(_ kinds: [MarkerKind]) {
        guard let data = try? encoder.encode(kinds) else { return }
        mergeAndApplyContext([Self.markersKey: data])
    }

    /// Pushes the current units preference to the counterpart device (same
    /// latest-wins application-context channel as the custom markers).
    public func sendUnitPreference(_ preference: UnitPreference) {
        guard let data = try? encoder.encode(preference) else { return }
        mergeAndApplyContext([Self.unitsKey: data])
    }

    /// Pushes the current dive-detection config to the counterpart device (same
    /// latest-wins application-context channel as the units preference). The watch
    /// stores it and applies it to its next session.
    public func sendDetectionConfig(_ config: DiveDetectionConfig) {
        guard let data = try? encoder.encode(config) else { return }
        mergeAndApplyContext([Self.detectionKey: data])
    }

    // MARK: - Live session (watch → phone, #118)

    /// Pushes the latest in-progress session snapshot to the phone over the
    /// application context (latest-wins, background-delivered, survives brief
    /// unreachability by overwriting). Send `isActive: false` on stop so the phone
    /// ends its banner/Live Activity promptly. Safe to call before activation — the
    /// retained outgoing context is re-applied once the session activates.
    public func sendLiveSession(_ snapshot: LiveSessionSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        mergeAndApplyContext([Self.liveSessionKey: data])
    }

    /// Merges `entries` into the outgoing application context and re-applies the
    /// whole thing. `updateApplicationContext` is latest-wins over the *entire*
    /// dictionary, so markers and units must be sent together — applying one key
    /// alone would clobber the other.
    private func mergeAndApplyContext(_ entries: [String: Any]) {
        lock.lock()
        outgoingContext.merge(entries) { _, new in new }
        let merged = outgoingContext
        lock.unlock()
        applyContext(merged)
    }

    /// Decodes the marker definitions and units preference from an application
    /// context, forwarding each present key to its callback.
    func handleApplicationContext(_ context: [String: Any]) {
        if let data = context[Self.markersKey] as? Data,
           let kinds = try? decoder.decode([MarkerKind].self, from: data) {
            onReceiveCustomMarkers?(kinds)
        }
        if let data = context[Self.unitsKey] as? Data,
           let preference = try? decoder.decode(UnitPreference.self, from: data) {
            onReceiveUnitPreference?(preference)
        }
        if let data = context[Self.detectionKey] as? Data,
           let config = try? decoder.decode(DiveDetectionConfig.self, from: data) {
            onReceiveDetectionConfig?(config)
        }
        if let data = context[Self.liveSessionKey] as? Data,
           let snapshot = try? decoder.decode(LiveSessionSnapshot.self, from: data) {
            onReceiveLiveSession?(snapshot)
        }
    }

    /// Activates the underlying session if WatchConnectivity is supported.
    public func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Encodes and queues a session for delivery to the counterpart device.
    ///
    /// Tombstoned session ids early-return: a session deleted this launch must
    /// never be re-queued (including via a resync), or it would resurrect on the
    /// phone after its deletion message.
    ///
    /// Deduped by session id: a session already queued (e.g. re-adopted after a
    /// relaunch, or re-sent via "Re-send all") must not spawn a second pending
    /// entry — that would count the same session twice in the badge and enqueue a
    /// duplicate OS transfer. When an entry already exists we refresh its stored
    /// payload with the fresh encode (watch sessions mutate after save — e.g. the
    /// geocode backfill sets `locationName` — so the newest bytes must win) and
    /// reuse it instead of inserting a new one (and don't fire the count callback):
    /// - **system-owned** (the OS still holds the transfer's slot from a prior
    ///   launch): refresh the stored payload only — the OS will deliver it, and
    ///   re-sending would duplicate it; the fresh bytes go out on a later
    ///   reclaim/retry.
    /// - **ours**: refresh the stored payload, then re-`performTransfer` the
    ///   *existing* id with the fresh data as a manual nudge, leaving `attempts`
    ///   untouched (this isn't a fresh reachability window).
    public func send(_ session: DiveSession) throws {
        let data = try encoder.encode(session)
        lock.lock()
        if deletedSessionIDs.contains(session.id) {
            lock.unlock()
            return
        }
        if let existing = pending.first(where: { $0.value.sessionID == session.id }) {
            let existingID = existing.key
            let isSystemOwned = existing.value.isSystemOwned
            pending[existingID]?.data = data
            lock.unlock()
            if !isSystemOwned { performTransfer(existingID, data) }
            return
        }
        let id = UUID().uuidString
        pending[id] = Pending(sessionID: session.id, data: data, isSystemOwned: false)
        let count = pending.count
        lock.unlock()
        onPendingCountChange?(count)
        performTransfer(id, data)
    }

    /// Tells the counterpart device to delete a session by id. First drops any
    /// not-yet-delivered send for that session, so a reachability-driven retry
    /// can't re-deliver it *after* the deletion and resurrect it on the phone;
    /// then sends the (idempotent) deletion via the background-safe transport. This
    /// closes the resurrection path up to a negligible in-flight window: the
    /// tombstone (`deletedSessionIDs`) blocks any later re-queue via `send`/
    /// `retryPending`/`completeTransfer`, leaving only the sub-millisecond TOCTOU
    /// between a concurrent retry's final tombstone check and its `WCSession` call.
    ///
    /// Dropping the in-memory entry can't stop the OS's still-queued
    /// `transferUserInfo` copy, so `cancelTransfers` cancels the dropped transfer
    /// ids at the OS level too — otherwise a relaunch could re-adopt the payload
    /// (it would still be in `outstandingUserInfoTransfers`) and resurrect the
    /// deleted session. Called after releasing the lock, matching the other seams.
    public func sendDeletion(_ id: UUID) {
        lock.lock()
        deletedSessionIDs.insert(id)
        let staleKeys = pending.filter { $0.value.sessionID == id }.map(\.key)
        for key in staleKeys { pending[key] = nil; attempts[key] = nil }
        let count = pending.count
        lock.unlock()
        onPendingCountChange?(count)
        cancelTransfers(Set(staleKeys))
        performDeletion(id)
    }

    /// Sends a voice-note file to the counterpart device. Uses the background-safe
    /// `transferFile`; the `fileName` rides in metadata so the receiver stores it
    /// under the name the session's markers reference — and so `completeFileTransfer`
    /// can identify the clip when the OS confirms (or fails) delivery.
    public func sendAudioFile(_ url: URL, fileName: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        performFileTransfer(url, [Self.fileNameKey: fileName])
    }

    // MARK: - Transport-agnostic core (unit-tested directly)

    /// Records the outcome of a transfer: clear on success, re-send on failure
    /// up to `maxImmediateRetries`, after which the payload waits for the next
    /// `retryPending` instead of looping.
    func completeTransfer(id: String, data: Data, error: Error?) {
        if error == nil {
            lock.lock()
            let entry = pending[id]
            pending[id] = nil; attempts[id] = nil
            let count = pending.count
            lock.unlock()
            onPendingCountChange?(count)
            // Confirmed on the phone — record the session id so retention can
            // safely prune it from the watch. Only ever fires on genuine success.
            // Prefer the stored id; fall back to decoding only for an untracked
            // entry (e.g. a transfer that finished before we could re-adopt it).
            if let sessionID = entry?.sessionID {
                onSessionDelivered?(sessionID)
            } else if let session = try? decoder.decode(DiveSession.self, from: data) {
                onSessionDelivered?(session.id)
            }
            return
        }
        lock.lock()
        // Only track attempts for an entry still in `pending`. If it was dropped
        // (by `sendDeletion`) or was never tracked (an untracked/cancelled
        // transfer's `didFinish`), there's nothing to retry — so don't leak a
        // stale `attempts` counter; clear any left behind instead.
        guard let entry = pending[id] else {
            attempts[id] = nil
            lock.unlock()
            return
        }
        let count = (attempts[id] ?? 0) + 1
        attempts[id] = count
        // `didFinish` arrived → the OS no longer owns this transfer's slot; a
        // re-adopted entry is now ours to retry.
        pending[id]?.isSystemOwned = false
        // Never re-enqueue a tombstoned (deleted-this-launch) session: a deletion
        // that landed after this transfer's snapshot must win.
        let shouldRetry = !deletedSessionIDs.contains(entry.sessionID)
            && count <= Self.maxImmediateRetries
        lock.unlock()
        if shouldRetry { performTransfer(id, data) }
    }

    /// Records the outcome of a voice-note file transfer: on success fire
    /// `onAudioFileDelivered` (the safe signal watch-side retention needs before
    /// pruning the clip's only copy); on failure re-send once, provided the source
    /// file still exists. Unlike session payloads, `transferFile` is not re-adopted
    /// across relaunches and has no per-file pending queue, so this can't consult
    /// `pending`. The re-send doesn't loop: each retry needs a fresh OS-level
    /// `didFinish(error:)` to fire again, and a missing file just stops.
    ///
    /// The file name comes from the `fileNameKey` metadata (the name the markers
    /// reference), falling back to the URL's last path component.
    func completeFileTransfer(fileName: String?, fileURL: URL, metadata: [String: Any]?, error: Error?) {
        let name = fileName ?? (metadata?[Self.fileNameKey] as? String) ?? fileURL.lastPathComponent
        if error == nil {
            onAudioFileDelivered?(name)
            return
        }
        // Re-send once — but only if the source file is still on disk; otherwise
        // there's nothing to resend and retrying would fail forever.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        performFileTransfer(fileURL, metadata ?? [Self.fileNameKey: name])
    }

    /// Re-sends everything still outstanding — called when reachability returns
    /// or the session finishes activating, so a backlog drains promptly. Resets
    /// the per-payload retry budget so a fresh reachability window gets new tries.
    func retryPending() {
        // Reclaim system-owned (re-adopted) entries the OS no longer lists: their
        // transfer was dropped without a `didFinish` (unpair, daemon restart), so
        // waiting for one would starve them forever — badge stuck, session never
        // re-sent. The snapshot is only taken when a system-owned entry exists,
        // i.e. after a real activation.
        lock.lock()
        let hasSystemOwned = pending.contains { $0.value.isSystemOwned }
        lock.unlock()
        if hasSystemOwned {
            let stillQueued = Set(outstandingTransfers().map(\.id))
            lock.lock()
            for (id, entry) in pending where entry.isSystemOwned && !stillQueued.contains(id) {
                pending[id]?.isSystemOwned = false
            }
            lock.unlock()
        }
        lock.lock()
        // Skip entries the OS still owns: it delivers them itself, and re-sending
        // would enqueue a duplicate. They rejoin the retry set via a failed
        // `didFinish` (`completeTransfer`) or the reclaim above. Also skip
        // tombstoned (deleted-this-launch) sessions — normally already dropped from
        // `pending` by `sendDeletion`, but the tombstone closes the snapshot window
        // if a deletion lands mid-retry.
        let items = pending.filter {
            !$0.value.isSystemOwned && !deletedSessionIDs.contains($0.value.sessionID)
        }
        for id in items.keys { attempts[id] = 0 }
        lock.unlock()
        for (id, entry) in items { performTransfer(id, entry.data) }
    }

    /// Re-adopts the system's still-queued userInfo transfers into `pending` so a
    /// relaunch reflects the true backlog (the OS keeps `transferUserInfo` payloads
    /// across process death, but our in-memory `pending` starts empty). Each
    /// re-adopted entry is flagged `isSystemOwned` so `retryPending` won't duplicate
    /// it. Fires `onPendingCountChange` with the corrected count when anything is
    /// adopted. Called at activation, before `retryPending`.
    func adoptOutstandingTransfers() {
        // Decode outside the lock — sessions can be sizeable, and the send/status
        // paths contend on it.
        let outstanding = outstandingTransfers().compactMap { entry -> (id: String, adopted: Pending)? in
            guard let session = try? decoder.decode(DiveSession.self, from: entry.data) else { return nil }
            return (entry.id, Pending(sessionID: session.id, data: entry.data, isSystemOwned: true))
        }
        lock.lock()
        var changed = false
        for entry in outstanding where pending[entry.id] == nil {
            pending[entry.id] = entry.adopted
            changed = true
        }
        let count = pending.count
        lock.unlock()
        if changed { onPendingCountChange?(count) }
    }

    /// Decodes an incoming payload and forwards it: a deletion (id only) to
    /// `onDeleteSession`, otherwise a session to `onReceiveSession`.
    func handleReceived(_ userInfo: [String: Any]) {
        if let idString = userInfo[Self.deletedKey] as? String, let id = UUID(uuidString: idString) {
            onDeleteSession?(id)
            return
        }
        guard let data = userInfo[Self.payloadKey] as? Data,
              let decoded = try? decoder.decode(DiveSession.self, from: data) else { return }
        onReceiveSession?(decoded)
    }
}

#if canImport(WatchConnectivity)
extension SyncManager: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            // Re-adopt transfers still queued from a prior launch first, so the
            // pending badge is correct and failed ones can recover.
            adoptOutstandingTransfers()
            retryPending()
            // Pick up the latest custom markers that arrived while we were off.
            handleApplicationContext(session.receivedApplicationContext)
            // Re-apply any context we tried to send before activation completed.
            lock.lock(); let outgoing = outgoingContext; lock.unlock()
            if !outgoing.isEmpty { applyContext(outgoing) }
        }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleReceived(userInfo)
    }

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let dir = audioDirectory else { return }
        let fileName = (file.metadata?[Self.fileNameKey] as? String) ?? file.fileURL.lastPathComponent
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: destination)
        // Copy synchronously — the system deletes the temp file once we return.
        guard (try? fileManager.copyItem(at: file.fileURL, to: destination)) != nil else { return }
        onReceiveAudioFile?(destination)
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleApplicationContext(applicationContext)
    }

    public func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard let (id, data) = Self.sessionTransfer(from: userInfoTransfer.userInfo) else { return }
        completeTransfer(id: id, data: data, error: error)
    }

    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let metadata = fileTransfer.file.metadata
        completeFileTransfer(
            fileName: metadata?[Self.fileNameKey] as? String,
            fileURL: fileTransfer.file.fileURL,
            metadata: metadata,
            error: error
        )
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { retryPending() }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a newly paired watch can keep syncing.
        WCSession.default.activate()
    }
    #endif
}
#endif
