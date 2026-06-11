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
///
/// Also owns the Crown-navigable action menu, so the same focus/confirm state
/// is reachable both from `SessionRootView` and from `AddMarkerIntent` (the
/// Action button), which runs outside the view.
@MainActor
@Observable
final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case active(start: Date)
    }

    /// A single Crown-menu action. On the surface the diver scrolls to one of
    /// these and confirms it (Action button, or a tap); underwater the Action
    /// button drops a `.note` directly and the menu can't be confirmed.
    enum SessionAction: Equatable, Identifiable {
        case mark(EventKind)
        case end

        var id: String {
            switch self {
            case .mark(let kind): "mark.\(kind.rawValue)"
            case .end: "end"
            }
        }

        var title: String {
            switch self {
            case .mark(let kind): kind.rawValue.capitalized
            case .end: "End Session"
            }
        }

        var systemImage: String {
            switch self {
            case .mark: "mappin"
            case .end: "stop.fill"
            }
        }
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

    /// Seconds at the surface since the last dive ended, or `nil` when submerged
    /// or before the first completed dive. Drives the surface-interval timer.
    var surfaceInterval: TimeInterval? { sessionManager.surfaceInterval }

    /// True while the diver is below the surface threshold. The Action button
    /// drops a marker when submerged and confirms the focused menu item when at
    /// the surface.
    var isSubmerged: Bool { sessionManager.currentDiveStart != nil }

    // MARK: - Crown action menu

    /// Menu the Crown scrolls through: one entry per marker kind, then End.
    let menuItems: [SessionAction] = EventKind.allCases.map(SessionAction.mark) + [.end]

    /// Index of the currently highlighted menu item (Crown-driven).
    private(set) var focusedIndex: Int = 0

    func addMarker(kind: EventKind) {
        sessionManager.addMarker(kind: kind)
    }

    /// Highlights a menu item (clamped). The Crown only moves the highlight;
    /// nothing fires until the Action button confirms it.
    func focus(_ index: Int) {
        guard case .active = state, !menuItems.isEmpty else { return }
        focusedIndex = max(0, min(index, menuItems.count - 1))
    }

    /// Confirms the focused menu item: place that marker kind, or end the
    /// session. Invoked by the Action button on the surface.
    func confirmFocused() {
        guard case .active = state, menuItems.indices.contains(focusedIndex) else { return }
        switch menuItems[focusedIndex] {
        case .mark(let kind):
            addMarker(kind: kind)
            DiveHapticPlayer.play(.markerPlaced)
        case .end:
            Task { await stop() }
        }
    }

    /// Context-sensitive Action-button handler. Submerged → drop a `.note`
    /// (screen is water-locked, so the menu can't be confirmed); on the surface
    /// → confirm the focused menu item.
    func handleActionButton() {
        guard case .active = state else { return }
        if isSubmerged {
            addMarker(kind: .note)
            DiveHapticPlayer.play(.markerPlaced)
        } else {
            confirmFocused()
        }
    }

    private let sessionManager: SessionManager
    let workout = WorkoutController()
    private let sync = SyncManager()

    init(modelContext: ModelContext) {
        sessionManager = SessionManager(modelContext: modelContext)
        sessionManager.onHapticEvent = { DiveHapticPlayer.play($0) }
        sync.activate()
        // Let the Action-button intent route into this live coordinator.
        LiveSessionRegistry.shared.coordinator = self
    }

    func start() async {
        guard state == .idle else { return }
        do {
            try await workout.requestAuthorization()
            try await workout.start()
            try await sessionManager.startSession()
            focusedIndex = 0
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
