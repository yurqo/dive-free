import WatchKit

/// Adopts the extended-runtime session WatchKit creates for a submerged app.
/// `underwater-depth` makes Dive Free eligible for the system's Auto-Launch
/// picker; Core Motion handles the water-state start, while this delegate keeps
/// the system-provided runtime session alive for the dive.
@MainActor
final class DiveFreeWatchApplicationDelegate: NSObject, WKApplicationDelegate, WKExtendedRuntimeSessionDelegate {
    private weak var coordinator: SessionCoordinator?
    private var pendingAutomaticStart = false
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private(set) var wasAutomaticallyLaunched = false

    func configure(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        guard pendingAutomaticStart else { return }
        pendingAutomaticStart = false
        Task { await coordinator.startAutomatically() }
    }

    func handle(_ session: WKExtendedRuntimeSession) {
        // WatchKit calls this for the runtime session associated with a submerged
        // launch. Its delegate must be set before this method returns.
        wasAutomaticallyLaunched = true
        session.delegate = self
        extendedRuntimeSession = session

        guard let coordinator else {
            pendingAutomaticStart = true
            return
        }
        Task { await coordinator.startAutomatically() }
    }

    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {}
}
