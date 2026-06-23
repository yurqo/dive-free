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

    /// Notified with the new pending count whenever transfer status changes.
    /// Fires on an arbitrary thread; hop to the main actor before touching UI.
    public var onPendingCountChange: (@Sendable (Int) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    static let payloadKey = "session"
    static let idKey = "id"
    static let markersKey = "customMarkers"
    static let unitsKey = "unitPreference"
    static let fileNameKey = "fileName"

    private let lock = NSLock()
    /// Payloads sent but not yet confirmed delivered, keyed by transfer id.
    private var pending: [String: Data] = [:]
    /// Immediate re-send attempts per payload, to bound retry storms.
    private var attempts: [String: Int] = [:]
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

    /// Sessions queued but not yet confirmed delivered.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public init(
        performTransfer: ((_ id: String, _ data: Data) -> Void)? = nil,
        applyContext: ((_ context: [String: Any]) -> Void)? = nil
    ) {
        self.performTransfer = performTransfer ?? { id, data in
            #if canImport(WatchConnectivity)
            WCSession.default.transferUserInfo([Self.payloadKey: data, Self.idKey: id])
            #endif
        }
        self.applyContext = applyContext ?? { context in
            #if canImport(WatchConnectivity)
            try? WCSession.default.updateApplicationContext(context)
            #endif
        }
        super.init()
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
    public func send(_ session: DiveSession) throws {
        let data = try encoder.encode(session)
        let id = UUID().uuidString
        lock.lock(); pending[id] = data; let count = pending.count; lock.unlock()
        onPendingCountChange?(count)
        performTransfer(id, data)
    }

    /// Sends a voice-note file to the counterpart device. Uses the background-safe
    /// `transferFile`; the `fileName` rides in metadata so the receiver stores it
    /// under the name the session's markers reference.
    public func sendAudioFile(_ url: URL, fileName: String) {
        #if canImport(WatchConnectivity)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        WCSession.default.transferFile(url, metadata: [Self.fileNameKey: fileName])
        #endif
    }

    // MARK: - Transport-agnostic core (unit-tested directly)

    /// Records the outcome of a transfer: clear on success, re-send on failure
    /// up to `maxImmediateRetries`, after which the payload waits for the next
    /// `retryPending` instead of looping.
    func completeTransfer(id: String, data: Data, error: Error?) {
        if error == nil {
            lock.lock(); pending[id] = nil; attempts[id] = nil; let count = pending.count; lock.unlock()
            onPendingCountChange?(count)
            return
        }
        lock.lock()
        let count = (attempts[id] ?? 0) + 1
        attempts[id] = count
        let shouldRetry = pending[id] != nil && count <= Self.maxImmediateRetries
        lock.unlock()
        if shouldRetry { performTransfer(id, data) }
    }

    /// Re-sends everything still outstanding — called when reachability returns
    /// or the session finishes activating, so a backlog drains promptly. Resets
    /// the per-payload retry budget so a fresh reachability window gets new tries.
    func retryPending() {
        lock.lock()
        let items = pending
        for id in items.keys { attempts[id] = 0 }
        lock.unlock()
        for (id, data) in items { performTransfer(id, data) }
    }

    /// Decodes an incoming payload and forwards the session to `onReceiveSession`.
    func handleReceived(_ userInfo: [String: Any]) {
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
        let info = userInfoTransfer.userInfo
        guard let id = info[Self.idKey] as? String, let data = info[Self.payloadKey] as? Data else { return }
        completeTransfer(id: id, data: data, error: error)
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
