import Foundation
import Domain
import OSLog

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Transfers completed sessions between the Watch and iPhone over WatchConnectivity.
///
/// Every completed session uses the background-safe `transferFile` transport.
/// A durable outbox keeps the original payload until
/// the phone confirms it saved the session, including across failed transfers,
/// app restarts, and a successful transport followed by a failed phone save.
///
/// An injectable file transport keeps the queue, recovery, and receipt
/// handling testable without a paired `WCSession`.
public final class SyncManager: NSObject, @unchecked Sendable {
    /// Called on the phone when a session arrives from the watch. `isResync` is
    /// `true` when the watch marked this an *explicit* re-send ("Re-send to
    /// iPhone"/"Re-send all"): a deliberate recovery that must override an earlier
    /// accidental swipe-delete, so the receiver clears its deletion tombstone before
    /// importing. Absent on the wire (older watches) → `false`, i.e. a normal send.
    public var onReceiveSession: (@Sendable (DiveSession, _ isResync: Bool) -> Void)?

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

    public var onSyncError: (@Sendable (String?) -> Void)?
    /// Lets the Watch recover unconfirmed sessions saved by an older app build.
    public var onSessionTransportReady: (@Sendable () -> Void)?

    /// Notified with a session's id once its transfer is **confirmed delivered**
    /// to the counterpart device. Informational only: the phone's saved-session
    /// acknowledgement, `onSessionImported`, is what makes retention safe.
    public var onSessionDelivered: (@Sendable (UUID) -> Void)?

    /// Notified with a voice-note file name once its transfer is **confirmed
    /// delivered** to the counterpart device — the safe signal watch-side
    /// retention uses to know a clip is on the phone before pruning the session
    /// that references it. Fires on an arbitrary thread.
    public var onAudioFileDelivered: (@Sendable (String) -> Void)?

    /// Called on the watch when the phone acknowledges that a session was actually
    /// **imported** (SAVED) — an application-level ACK, distinct from WC's transport
    /// `didFinish` (which fires even if the phone's save then throws). Both the
    /// pending badge and watch-side retention gate on this acknowledgement.
    /// Fires on an arbitrary thread. An OLDER phone never sends these, so a watch on
    /// this version paired with one never marks anything delivered → retention never
    /// prunes (the safe direction — no data loss).
    public var onSessionImported: (@Sendable (UUID) -> Void)?

    /// Called on the watch when the phone acknowledges a voice-note clip was actually
    /// **copied into storage** — the audio counterpart of `onSessionImported`. The
    /// phone's file receiver returns silently on a copy failure, so the transport's
    /// `didFinish` success is not proof the clip persisted; this ack is. Same
    /// old-phone-never-acks safety. Fires on an arbitrary thread.
    public var onAudioImported: (@Sendable (String) -> Void)?

    public var onNoteTransportReady: (@Sendable () -> Void)?
    public var onReceiveNoteMutation: (@Sendable (NoteMutation) -> Void)?
    public var onNoteMutationAcknowledged: (@Sendable (UUID) -> Void)?

    public func sendNoteMutation(_ mutation: NoteMutation) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(mutation) else { return }
        // The persistent SwiftData journal is the outbox. Avoid duplicate OS slots.
        guard !WCSession.default.outstandingUserInfoTransfers.contains(where: {
            $0.userInfo["noteMutationID"] as? String == mutation.id.uuidString
        }) else { return }
        WCSession.default.transferUserInfo(["noteMutation": data, "noteMutationID": mutation.id.uuidString])
        #endif
    }
    public func acknowledgeNoteMutation(_ id: UUID) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["noteMutationAck": id.uuidString])
        #endif
    }

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
    /// Application-level ACK from the phone: this session id was actually imported
    /// (saved), not merely delivered by WC. Rides its own lightweight message (id
    /// only, no `payloadKey`), like a deletion, so adoption/`didFinish`/receive all
    /// treat it as a non-session control message.
    static let ackKey = "importedSessionID"
    /// Application-level ACK from the phone: this voice-note file name was actually
    /// copied into storage. Mirror of `ackKey` for audio clips.
    static let audioAckKey = "importedAudioFileName"
    /// Envelope flag on a session transfer marking it an *explicit* re-send, so the
    /// receiver clears its deletion tombstone before importing. Absent → a normal
    /// send (keeps older watches, which never set it, compatible).
    static let resyncKey = "isResync"
    static let sessionFileKey = "sessionPayloadFile"
    static let sessionIDKey = "sessionID"

    private let outbox: SessionOutbox
    private let log = Logger(subsystem: "org.yurko.divefree", category: "Sync")

    private let lock = NSLock()
    /// A payload not yet confirmed saved. Carries the session id so
    /// `sendDeletion`/`completeTransfer` need not JSON-decode `data` to identify it.
    private struct Pending {
        let sessionID: UUID
        /// The latest encoded payload for this session. Mutable so a dedupe nudge
        /// (`send` of an already-pending session) can refresh it — watch sessions
        /// mutate after save (e.g. the geocode backfill sets `locationName`, part of
        /// the Codable payload), and the fresh encode must win over the stale one.
        var data: Data
        /// True while the OS still owns this transfer's queue slot — set on entries
        /// re-adopted from either WC transport queue at activation. Such entries
        /// must not be re-enqueued (that would enqueue a duplicate); they
        /// become ours (`false`) once their `didFinish` arrives.
        var isSystemOwned: Bool
        /// Whether this payload is an *explicit* resync — carried so a RETRY keeps
        /// the `resyncKey` metadata flag rather than
        /// silently downgrading to a plain send. Without it, a tombstone-clearing
        /// resync that failed its first hop would retry flag-free, be tombstone-rejected
        /// on the phone, yet a later `didFinish` success would still mark it delivered —
        /// letting retention prune the only copy (the exact loss FIX 3's import ack now
        /// also guards against). See `send`/`completeTransfer`/`retryPending`.
        var isResync: Bool
    }
    /// Payloads not yet confirmed saved, keyed by transfer id.
    private var pending: [String: Pending] = [:]
    /// Immediate re-send attempts per payload, to bound retry storms.
    private var attempts: [String: Int] = [:]
    /// Immediate re-send attempts per voice-note file name, to bound file-transfer
    /// retry storms. `transferFile` has no re-adopt/pending queue like sessions do,
    /// so its retry budget is tracked here keyed by the clip's file name. A
    /// persistently-failing or OS-cancelled clip (an unpaired/uninstalled companion
    /// is the common trigger) would otherwise re-send forever — each re-send spawns
    /// its own `didFinish(error:)`, a battery hot-loop. Cleared on success.
    private var fileTransferAttempts: [String: Int] = [:]
    /// Session ids deleted this launch. A tombstone closes the snapshot window in
    /// `retryPending`/`completeTransfer` (which snapshot under the lock but
    /// enqueue after unlocking): a deletion that lands in between must not
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

    /// Monotonically increasing stamp for each pending-count snapshot, so
    /// `onPendingCountChange` never publishes an older count over a newer one.
    /// `onPendingCountChange` fires *after* the lock is released (it's a UI callback
    /// — firing under the lock risks reentrancy/deadlock), so two racing mutations
    /// can reach the callback out of order and leave a transient stale badge. Each
    /// mutation stamps its snapshot under the lock via `nextPendingGeneration()`;
    /// `publishPendingCount` then drops any snapshot older than the newest published,
    /// making the badge monotonic (latest-wins, correct for a count).
    private var pendingCountGeneration: UInt64 = 0
    /// The newest generation actually published to `onPendingCountChange`.
    private var publishedPendingGeneration: UInt64 = 0

    /// Stamps a fresh pending-count snapshot. Call under `lock`.
    private func nextPendingGeneration() -> UInt64 {
        pendingCountGeneration &+= 1
        return pendingCountGeneration
    }

    /// Publishes `count` to `onPendingCountChange`, but only if `generation` is newer
    /// than the last one published — so a slower thread carrying an older snapshot
    /// can't clobber a newer count and leave a stale badge. Call after releasing
    /// `lock` (the callback is UI-facing).
    private func publishPendingCount(_ count: Int, generation: UInt64) {
        lock.lock()
        guard generation > publishedPendingGeneration else { lock.unlock(); return }
        publishedPendingGeneration = generation
        lock.unlock()
        onPendingCountChange?(count)
    }

    /// Replaces the shared application context (latest-wins). Defaults to
    /// `WCSession.updateApplicationContext`; tests inject a stub.
    private let applyContext: (_ context: [String: Any]) -> Void

    /// Sends a session deletion. Defaults to `WCSession.transferUserInfo`; tests
    /// inject a stub.
    private let performDeletion: (_ id: UUID) -> Void

    /// Sends a phone→watch import ACK for a session id. Same background-safe
    /// `transferUserInfo` transport as `performDeletion` (id-only control message);
    /// tests inject a stub.
    private let performAck: (_ id: UUID) -> Void

    /// Sends a phone→watch import ACK for a voice-note file name. Mirror of
    /// `performAck` for audio clips; tests inject a stub.
    private let performAudioAck: (_ fileName: String) -> Void

    /// Cancels matching session transfers in both WC queues. Used by deletion,
    /// import acknowledgements, and migration of legacy dictionaries.
    private let cancelTransfers: (_ ids: Set<String>) -> Void

    /// The system's still-queued userInfo transfers, as `(id, payload)` pairs.
    /// Defaults to mapping `WCSession.outstandingUserInfoTransfers`; tests inject a
    /// stub. Used at activation to re-adopt transfers that outlived a relaunch.
    private let outstandingTransfers: () -> [(id: String, data: Data)]

    private let outstandingSessionFiles: () -> [(url: URL, metadata: [String: Any])]
    private let outstandingResyncIDs: () -> Set<String>

    /// Hands a recording payload or voice-note file to the transport. Defaults to
    /// `WCSession.transferFile`, guarded by `WCSession.isSupported()`; tests inject
    /// a stub so the confirmed-delivery/retry logic is unit-testable without a real
    /// `WCSession`.
    private let performFileTransfer: (_ url: URL, _ metadata: [String: Any]) -> Void

    /// Sessions not yet confirmed saved on the phone.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Session-specific status, so one pending recording doesn't make every
    /// historical session appear to be syncing.
    public var pendingSessionIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.values.map(\.sessionID))
    }

    public init(
        applyContext: ((_ context: [String: Any]) -> Void)? = nil,
        performDeletion: ((_ id: UUID) -> Void)? = nil,
        performAck: ((_ id: UUID) -> Void)? = nil,
        performAudioAck: ((_ fileName: String) -> Void)? = nil,
        cancelTransfers: ((_ ids: Set<String>) -> Void)? = nil,
        outstandingTransfers: (() -> [(id: String, data: Data)])? = nil,
        performFileTransfer: ((_ url: URL, _ metadata: [String: Any]) -> Void)? = nil,
        outstandingSessionFiles: (() -> [(url: URL, metadata: [String: Any])])? = nil,
        outstandingResyncIDs: (() -> Set<String>)? = nil,
        sessionTransferDirectory: URL? = nil
    ) {
        outbox = SessionOutbox(directory: sessionTransferDirectory ?? SessionOutbox.defaultDirectory)
        // Each default transport guards WCSession.isSupported(): WatchConnectivity
        // imports on iPad (canImport is true) but isn't supported there, and calling
        // these on an unactivated session raises an exception. iPad gets its data via
        // CloudKit (#168/#170), so these are correctly no-ops on it.
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
        self.performAck = performAck ?? { id in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            WCSession.default.transferUserInfo([Self.ackKey: id.uuidString])
            #endif
        }
        self.performAudioAck = performAudioAck ?? { fileName in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            WCSession.default.transferUserInfo([Self.audioAckKey: fileName])
            #endif
        }
        self.cancelTransfers = cancelTransfers ?? { ids in
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return }
            for transfer in WCSession.default.outstandingUserInfoTransfers
            where (transfer.userInfo[Self.idKey] as? String).map(ids.contains) == true {
                transfer.cancel()
            }
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?[Self.sessionFileKey] as? Bool == true
                && (transfer.file.metadata?[Self.idKey] as? String).map(ids.contains) == true {
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
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
            WCSession.default.transferFile(url, metadata: metadata)
            #endif
        }
        self.outstandingSessionFiles = outstandingSessionFiles ?? {
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return [] }
            return WCSession.default.outstandingFileTransfers.compactMap {
                guard let metadata = $0.file.metadata, metadata[Self.sessionFileKey] as? Bool == true else { return nil }
                return ($0.file.fileURL, metadata)
            }
            #else
            return []
            #endif
        }
        self.outstandingResyncIDs = outstandingResyncIDs ?? {
            #if canImport(WatchConnectivity)
            guard WCSession.isSupported() else { return [] }
            return Set(WCSession.default.outstandingUserInfoTransfers.compactMap {
                guard $0.userInfo[Self.resyncKey] as? Bool == true else { return nil }
                return $0.userInfo[Self.idKey] as? String
            })
            #else
            return []
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

    /// Queues the complete recording, refreshing an existing entry by session id.
    /// Explicit resync stays sticky across retries and relaunches.
    public func send(_ session: DiveSession, isResync: Bool = false) throws {
        let data = try encoder.encode(session)
        lock.lock()
        guard !deletedSessionIDs.contains(session.id) else { lock.unlock(); return }
        if let existing = pending.first(where: { $0.value.sessionID == session.id }) {
            pending[existing.key]?.data = data
            pending[existing.key]?.isResync = existing.value.isResync || isResync
            lock.unlock()
            transmitPending(existing.key)
            return
        }
        let id = UUID().uuidString
        pending[id] = Pending(sessionID: session.id, data: data, isSystemOwned: false, isResync: isResync)
        let count = pending.count
        let generation = nextPendingGeneration()
        lock.unlock()
        publishPendingCount(count, generation: generation)
        transmitPending(id)
    }

    private func queuedTransferIDs() -> Set<String> {
        Set(outstandingTransfers().map(\.id)).union(outstandingSessionFiles().compactMap { $0.metadata[Self.idKey] as? String })
    }

    /// Persist before enqueueing, and never overwrite an in-flight file snapshot.
    private func transmitPending(_ id: String) {
        let queued = queuedTransferIDs()
        lock.lock()
        guard let entry = pending[id], !deletedSessionIDs.contains(entry.sessionID) else { lock.unlock(); return }
        let snapshot: URL
        do {
            try outbox.save(SessionOutbox.Entry(id: id, sessionID: entry.sessionID, data: entry.data,
                                               isResync: entry.isResync))
            guard !entry.isSystemOwned, !queued.contains(id) else { lock.unlock(); return }
            snapshot = try outbox.makeSnapshot(id: id, data: entry.data)
        } catch {
            lock.unlock()
            reportError(error)
            return // Keep the pending recording; retry when the transport is ready again.
        }
        lock.unlock()
        // A concurrent delete/import acknowledgement must win over this snapshot.
        lock.lock()
        let stillPending = pending[id] != nil && !deletedSessionIDs.contains(entry.sessionID)
        lock.unlock()
        guard stillPending else {
            outbox.removeSnapshot(snapshot)
            return
        }
        log.info("Sending session as file: \(entry.data.count) bytes")
        performFileTransfer(snapshot, [Self.sessionFileKey: true, Self.idKey: id,
                                      Self.sessionIDKey: entry.sessionID.uuidString, Self.resyncKey: entry.isResync])
    }

    private func reportError(_ error: Error) {
        let details = "\(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]"
        log.error("Session sync failed: \(details, privacy: .public)")
        onSyncError?(details)
    }

    /// Called when the Watch app returns to the foreground as well as by WC's
    /// activation/reachability callbacks. No active session means defer to activation.
    public func resumePendingTransfers() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        #endif
        adoptOutstandingTransfers()
        retryPending()
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
    /// Dropping the in-memory entry can't stop the OS's still-queued file copy,
    /// so `cancelTransfers` cancels the dropped transfer ids at the OS level too
    /// — otherwise a relaunch could re-adopt the payload and resurrect the
    /// deleted session. Called after releasing the lock, matching the other seams.
    public func sendDeletion(_ id: UUID) {
        lock.lock()
        deletedSessionIDs.insert(id)
        let staleKeys = pending.filter { $0.value.sessionID == id }.map(\.key)
        var errors: [Error] = []
        for key in staleKeys {
            do { try outbox.remove(key) } catch { errors.append(error) }
            pending[key] = nil; attempts[key] = nil
        }
        let count = pending.count
        let generation = nextPendingGeneration()
        lock.unlock()
        publishPendingCount(count, generation: generation)
        cancelTransfers(Set(staleKeys))
        performDeletion(id)
        errors.forEach(reportError)
    }

    /// Sends an application-level import ACK to the watch (phone → watch): confirms
    /// the phone actually SAVED this session, so watch-side retention may prune it.
    /// Distinct from WC's transport `didFinish`, which fires even when the phone's
    /// save throws — the very gap this closes. Idempotent and background-safe
    /// (`transferUserInfo`); the watch's `markDelivered` de-dupes re-acks.
    /// Fire-and-forget, like the deletion messages: a dropped ack is the SAFE
    /// direction — it leaves the session unprunable on the watch (rather than pruning
    /// a copy the phone never saved) until a re-delivery/re-send re-acks it. Deliberate;
    /// no delivery-guarantee retry here.
    public func sendImportAck(_ id: UUID) {
        performAck(id)
    }

    /// Sends an application-level import ACK for a voice-note clip (phone → watch):
    /// confirms the phone copied the file into storage, so retention may prune the
    /// session that references it. Mirror of `sendImportAck` — likewise fire-and-forget:
    /// a dropped audio ack leaves the clip unprunable (the safe direction) until a
    /// re-send re-acks it.
    public func sendAudioImportAck(_ fileName: String) {
        performAudioAck(fileName)
    }

    /// Sends a voice-note file to the counterpart device. Uses the background-safe
    /// `transferFile`; the `fileName` rides in metadata so the receiver stores it
    /// under the name the session's markers reference — and so `completeFileTransfer`
    /// can identify the clip when the OS confirms (or fails) delivery.
    ///
    /// This is the *top-level* enqueue path (a clip's first send, and again on a
    /// fresh reachability-driven re-send), distinct from the internal re-send that
    /// `completeFileTransfer` performs on a failed `didFinish`. So it resets the
    /// clip's per-file retry budget (`fileTransferAttempts`) — mirroring how
    /// `retryPending` clears the session `attempts` map for a fresh window. Without
    /// this, a clip that exhausted its cap on an earlier give-up stays exhausted
    /// forever: a later fresh send gets no immediate-retry budget, and each
    /// permanently-failed file name leaks a map entry. Resetting here gives every
    /// fresh send a clean budget and clears the leak on the next send of that clip.
    public func sendAudioFile(_ url: URL, fileName: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        lock.lock(); fileTransferAttempts[fileName] = nil; lock.unlock()
        performFileTransfer(url, [Self.fileNameKey: fileName])
    }

    // MARK: - Transport-agnostic core (unit-tested directly)

    /// Transport delivery is not a saved-session acknowledgement. Keep the entry
    /// and its durable copy until `importedSessionID` arrives from the phone.
    func completeTransfer(id: String, error: Error?) {
        lock.lock()
        guard let entry = pending[id] else { lock.unlock(); return }
        pending[id]?.isSystemOwned = false
        if error == nil {
            attempts[id] = nil
            lock.unlock()
            onSessionDelivered?(entry.sessionID)
            return
        }
        let count = (attempts[id] ?? 0) + 1
        attempts[id] = count
        let shouldRetry = !deletedSessionIDs.contains(entry.sessionID) && count <= Self.maxImmediateRetries
        lock.unlock()
        if let error { reportError(error) }
        if shouldRetry { transmitPending(id) }
    }

    private func confirmImport(_ sessionID: UUID) {
        lock.lock()
        let ids = pending.filter { $0.value.sessionID == sessionID }.map(\.key)
        var errors: [Error] = []
        for id in ids {
            do { try outbox.remove(id) } catch { errors.append(error) }
            pending[id] = nil
            attempts[id] = nil
        }
        let count = pending.count
        let generation = nextPendingGeneration()
        lock.unlock()
        cancelTransfers(Set(ids))
        publishPendingCount(count, generation: generation)
        if count == 0 { onSyncError?(nil) }
        errors.forEach(reportError)
        onSessionImported?(sessionID)
    }

    /// Records the outcome of a voice-note file transfer: on success fire
    /// `onAudioFileDelivered` (the safe signal watch-side retention needs before
    /// pruning the clip's only copy) and clear the clip's retry budget; on failure
    /// re-send, provided the source file still exists AND the clip's re-send budget
    /// (`fileTransferAttempts`, capped at `maxImmediateRetries`) isn't spent. Unlike
    /// session payloads, `transferFile` is not re-adopted across relaunches and has
    /// no per-file pending queue, so this can't consult `pending`.
    ///
    /// Each re-send spawns its own `didFinish(error:)`, so without the per-file cap a
    /// persistently-failing / OS-cancelled clip (an unpaired or uninstalled companion
    /// is the common trigger) would re-send forever — a battery hot-loop. The cap
    /// stops it past `maxImmediateRetries`; a missing file also just stops.
    ///
    /// The file name comes from the `fileNameKey` metadata (the name the markers
    /// reference), falling back to the URL's last path component — and keys the
    /// attempts map so the cap follows the clip across re-sends.
    func completeFileTransfer(fileName: String?, fileURL: URL, metadata: [String: Any]?, error: Error?) {
        if metadata?[Self.sessionFileKey] as? Bool == true {
            if let id = metadata?[Self.idKey] as? String {
                completeTransfer(id: id, error: error)
            }
            outbox.removeSnapshot(fileURL)
            return
        }
        let name = fileName ?? (metadata?[Self.fileNameKey] as? String) ?? fileURL.lastPathComponent
        if error == nil {
            lock.lock(); fileTransferAttempts[name] = nil; lock.unlock()
            onAudioFileDelivered?(name)
            return
        }
        // Re-send — but only if the source file is still on disk (otherwise there's
        // nothing to resend and retrying would fail forever) and the clip's re-send
        // budget isn't spent (otherwise a persistently-failing transfer hot-loops).
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        lock.lock()
        let count = (fileTransferAttempts[name] ?? 0) + 1
        fileTransferAttempts[name] = count
        let shouldRetry = count <= Self.maxImmediateRetries
        lock.unlock()
        guard shouldRetry else { return }
        performFileTransfer(fileURL, metadata ?? [Self.fileNameKey: name])
    }

    /// Re-sends everything still outstanding — called when reachability returns
    /// or the session finishes activating, so a backlog drains promptly. Resets
    /// the per-payload retry budget so a fresh reachability window gets new tries.
    func retryPending() {
        onNoteTransportReady?()
        onSessionTransportReady?()
        // Snapshot both OS queues ONCE and use them for both the
        // reclaim below and the duplicate-enqueue guard on the main filter. An id
        // still in `outstandingTransfers` — system-owned OR one of ours the OS hasn't
        // finished yet — must not be re-sent, or a reachability flap would enqueue a
        // duplicate transfer per pending session per flap.
        let stillQueued = queuedTransferIDs()
        lock.lock()
        for (id, entry) in pending where entry.isSystemOwned && !stillQueued.contains(id) {
            // System-owned but the OS no longer lists it: its transfer was dropped
            // without a `didFinish` (unpair, daemon restart), so reclaim it as ours —
            // waiting for a `didFinish` that will never come would starve it forever.
            pending[id]?.isSystemOwned = false
        }
        // Skip entries the OS still owns (it delivers them itself) AND any id still
        // queued in the OS's outstanding set (re-sending would enqueue a duplicate);
        // both rejoin the retry set via a failed `didFinish` (`completeTransfer`) or
        // the reclaim above. Also skip tombstoned (deleted-this-launch) sessions —
        // normally already dropped from `pending` by `sendDeletion`, but the
        // tombstone closes the snapshot window if a deletion lands mid-retry.
        let items = pending.filter {
            !$0.value.isSystemOwned
                && !stillQueued.contains($0.key)
                && !deletedSessionIDs.contains($0.value.sessionID)
        }
        for id in items.keys { attempts[id] = 0 }
        lock.unlock()
        // Route each entry by its stored resync flag so a queued resync keeps carrying
        // the tombstone-clearing envelope across a reachability-driven retry.
        for id in items.keys { transmitPending(id) }
    }

    /// Restore the durable outbox, adopt both WC transport queues, and migrate
    /// legacy dictionaries to files. The original Watch record remains
    /// untouched, and explicit-resync flags survive a restart.
    func adoptOutstandingTransfers() {
        let inline = outstandingTransfers()
        let files = outstandingSessionFiles()
        let fileIDs = Set(files.compactMap { $0.metadata[Self.idKey] as? String })
        let resyncIDs = outstandingResyncIDs()
        var entries = outbox.load(onError: reportError)
        for item in inline where !entries.contains(where: { $0.id == item.id }) {
            guard let session = try? decoder.decode(DiveSession.self, from: item.data) else { continue }
            entries.append(.init(id: item.id, sessionID: session.id, data: item.data,
                                 isResync: resyncIDs.contains(item.id)))
        }
        for item in files {
            guard let id = item.metadata[Self.idKey] as? String, !entries.contains(where: { $0.id == id }),
                  let data = try? Data(contentsOf: item.url),
                  let session = try? decoder.decode(DiveSession.self, from: data) else { continue }
            entries.append(.init(id: id, sessionID: session.id, data: data,
                                 isResync: item.metadata[Self.resyncKey] as? Bool ?? false))
        }
        let legacyIDs = Set(inline.map(\.id)).subtracting(fileIDs)
        lock.lock()
        var changed = false
        var errors: [Error] = []
        var migratedIDs: Set<String> = []
        for entry in entries where pending[entry.id] == nil && !deletedSessionIDs.contains(entry.sessionID) {
            // Validate the saved payload too, so a damaged outbox cannot enqueue
            // invalid bytes forever. The Watch database can rebuild this entry.
            guard let session = try? decoder.decode(DiveSession.self, from: entry.data), session.id == entry.sessionID else { continue }
            pending[entry.id] = Pending(sessionID: entry.sessionID, data: entry.data,
                                        isSystemOwned: fileIDs.contains(entry.id), isResync: entry.isResync)
            do {
                try outbox.save(entry)
                if legacyIDs.contains(entry.id) { migratedIDs.insert(entry.id) }
            } catch { errors.append(error) }
            changed = true
        }
        // A legacy transfer already tracked this launch must also be migrated.
        for id in legacyIDs.subtracting(migratedIDs) {
            guard let entry = pending[id] else { continue }
            do {
                try outbox.save(.init(id: id, sessionID: entry.sessionID, data: entry.data, isResync: entry.isResync))
                migratedIDs.insert(id)
            } catch { errors.append(error) }
        }
        for id in migratedIDs {
            pending[id]?.isSystemOwned = false
        }
        let count = pending.count
        let generation = changed ? nextPendingGeneration() : 0
        lock.unlock()
        // Preserve the OS's only queued copy if durable storage failed.
        if !migratedIDs.isEmpty { cancelTransfers(migratedIDs) }
        outbox.removeUnusedSnapshots(keeping: Set(files.map(\.url)))
        if changed { publishPendingCount(count, generation: generation) }
        errors.forEach(reportError)
    }

    /// Consume incoming session files synchronously before WC deletes its inbox
    /// file. Voice notes remain on their separate path, even with no audio directory.
    func handleReceivedFile(_ url: URL, metadata: [String: Any]?) {
        if metadata?[Self.sessionFileKey] as? Bool == true {
            do {
                let data = try Data(contentsOf: url)
                let session = try decoder.decode(DiveSession.self, from: data)
                guard metadata?[Self.sessionIDKey] as? String == session.id.uuidString else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                onReceiveSession?(session, metadata?[Self.resyncKey] as? Bool ?? false)
            } catch { reportError(error) }
            return
        }
        guard let dir = audioDirectory else { return }
        let fileName = metadata?[Self.fileNameKey] as? String ?? url.lastPathComponent
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: url, to: destination)
            onReceiveAudioFile?(destination)
        } catch { reportError(error) }
    }

    /// Decodes an incoming control/payload message and forwards it: a deletion (id
    /// only) to `onDeleteSession`, an import ACK (id/name only) to
    /// `onSessionImported`/`onAudioImported`, otherwise a session to `onReceiveSession`.
    /// The ack messages carry no `payloadKey`, so — like deletions — adoption,
    /// `didFinish`, and the session decode below all skip them.
    func handleReceived(_ userInfo: [String: Any]) {
        if let data = userInfo["noteMutation"] as? Data,
           let mutation = try? JSONDecoder().decode(NoteMutation.self, from: data) {
            onReceiveNoteMutation?(mutation); return
        }
        if let value = userInfo["noteMutationAck"] as? String, let id = UUID(uuidString: value) {
            onNoteMutationAcknowledged?(id); return
        }
        if let idString = userInfo[Self.deletedKey] as? String, let id = UUID(uuidString: idString) {
            onDeleteSession?(id)
            return
        }
        if let idString = userInfo[Self.ackKey] as? String, let id = UUID(uuidString: idString) {
            confirmImport(id)
            return
        }
        if let fileName = userInfo[Self.audioAckKey] as? String {
            onAudioImported?(fileName)
            return
        }
        guard let data = userInfo[Self.payloadKey] as? Data,
              let decoded = try? decoder.decode(DiveSession.self, from: data) else { return }
        // Absent flag (older watches) decodes as a normal send.
        let isResync = userInfo[Self.resyncKey] as? Bool ?? false
        onReceiveSession?(decoded, isResync)
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
        handleReceivedFile(file.fileURL, metadata: file.metadata)
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleApplicationContext(applicationContext)
    }

    public func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard let (id, _) = Self.sessionTransfer(from: userInfoTransfer.userInfo) else { return }
        completeTransfer(id: id, error: error)
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
