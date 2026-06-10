import Foundation
import Observation
import Domain
import Sensors
import Sync

/// Application-layer coordinator for a live watch session. Owns the sensor stream,
/// runs dive detection over the collected samples, and hands finished sessions to sync.
///
/// Lives in the Watch app (not a package) so the lower layers stay dependency-free:
/// `Sensors` and `Sync` depend on `Domain`, and this glues them together.
@MainActor
@Observable
final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case active(start: Date)
    }

    private(set) var state: State = .idle
    let sensors: SensorManager

    private let detector = DiveDetector()
    private let sync = SyncManager()

    init(sensors: SensorManager = SensorManager()) {
        self.sensors = sensors
        sync.activate()
    }

    var currentDepthMeters: Double { sensors.currentDepthMeters }

    func start() async {
        guard state == .idle else { return }
        do {
            try await sensors.start()
            state = .active(start: Date())
        } catch {
            state = .idle
        }
    }

    /// Stops sensing, builds the session from collected samples, and queues it for the phone.
    @discardableResult
    func stop() -> DiveSession? {
        guard case let .active(start) = state else { return nil }
        sensors.stop()
        let dives = detector.detectDives(from: sensors.samples)
        let session = DiveSession(startTime: start, endTime: Date(), dives: dives)
        try? sync.send(session)
        state = .idle
        return session
    }
}
