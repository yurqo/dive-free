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

    /// Notified with the new pending count whenever transfer status changes.
    /// Fires on an arbitrary thread; hop to the main actor before touching UI.
    public var onPendingCountChange: (@Sendable (Int) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    static let payloadKey = "session"
    static let idKey = "id"

    private let lock = NSLock()
    /// Payloads sent but not yet confirmed delivered, keyed by transfer id.
    private var pending: [String: Data] = [:]
    /// Immediate re-send attempts per payload, to bound retry storms.
    private var attempts: [String: Int] = [:]
    /// After this many back-to-back failures a payload stops auto-retrying and
    /// waits for the next reachability-driven `retryPending`, rather than looping.
    private static let maxImmediateRetries = 5

    /// Hands a payload to the transport. Defaults to `WCSession.transferUserInfo`;
    /// tests inject a stub.
    private let performTransfer: (_ id: String, _ data: Data) -> Void

    /// Sessions queued but not yet confirmed delivered.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public init(performTransfer: ((_ id: String, _ data: Data) -> Void)? = nil) {
        self.performTransfer = performTransfer ?? { id, data in
            #if canImport(WatchConnectivity)
            WCSession.default.transferUserInfo([Self.payloadKey: data, Self.idKey: id])
            #endif
        }
        super.init()
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
        if activationState == .activated { retryPending() }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleReceived(userInfo)
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
