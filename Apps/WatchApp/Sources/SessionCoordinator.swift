import Foundation
import Observation
import SwiftData
import Domain
import Sensors
import Session
import Sync

/// Application-layer coordinator for a live watch session. Delegates capture,
/// dive detection, and local persistence to `SessionManager`, and keeps
/// HealthKit and WatchConnectivity concerns here where they belong.
@MainActor
@Observable
final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case active(start: Date)
    }

    private(set) var state: State = .idle

    var currentDepthMeters: Double { sessionManager.currentDepthMeters }

    // Exposed so `SessionRootView` can bind to elapsed time.
    var elapsedTime: TimeInterval { sessionManager.elapsedTime }

    /// Number of finalized dives detected so far in the current session.
    var diveCount: Int { sessionManager.diveCount }

    /// Running maximum depth (m) observed in the current session.
    var maxDepthMeters: Double { sessionManager.maxDepthMeters }

    /// Number of markers placed in the current session.
    var markerCount: Int { sessionManager.markers.count }

    /// Elapsed time below the surface threshold, or `nil` at the surface.
    var currentDiveElapsed: TimeInterval? { sessionManager.currentDiveElapsed }

    func addMarker(kind: EventKind) {
        sessionManager.addMarker(kind: kind)
    }

    private let sessionManager: SessionManager
    let workout = WorkoutController()
    private let sync = SyncManager()

    init(modelContext: ModelContext) {
        sessionManager = SessionManager(modelContext: modelContext)
        sessionManager.onHapticEvent = { DiveHapticPlayer.play($0) }
        sync.activate()
    }

    func start() async {
        guard state == .idle else { return }
        do {
            try await workout.requestAuthorization()
            try await workout.start()
            try await sessionManager.startSession()
            state = .active(start: sessionManager.startTime ?? Date())
        } catch {
            // Graceful fallback: HealthKit unavailable on simulator,
            // or sensor unavailable — stay idle so the app remains usable.
            state = .idle
        }
    }

    /// Ends the workout, stops the capture loop, persists locally, and queues
    /// the session for delivery to the paired iPhone.
    @discardableResult
    func stop() async -> DiveSession? {
        guard case .active = state else { return nil }
        await workout.end()
        let session = try? sessionManager.stopSession()
        if let session {
            try? sync.send(session)
        }
        state = .idle
        return session
    }
}
