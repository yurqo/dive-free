import Foundation
import Domain

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Transfers completed sessions between the Watch and iPhone over WatchConnectivity.
///
/// The watch enqueues finished `DiveSession`s; the phone receives and persists them.
/// Encoding uses JSON so the payload travels as a plain dictionary.
public final class SyncManager: NSObject, @unchecked Sendable {
    /// Called on the phone when a session arrives from the watch.
    public var onReceiveSession: (@Sendable (DiveSession) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let payloadKey = "session"

    public override init() {
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

    /// Queues a session for delivery to the counterpart device.
    public func send(_ session: DiveSession) throws {
        #if canImport(WatchConnectivity)
        let data = try encoder.encode(session)
        WCSession.default.transferUserInfo([Self.payloadKey: data])
        #endif
    }
}

#if canImport(WatchConnectivity)
extension SyncManager: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[Self.payloadKey] as? Data,
              let decoded = try? decoder.decode(DiveSession.self, from: data) else { return }
        onReceiveSession?(decoded)
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
