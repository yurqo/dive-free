import SwiftUI

/// Watch home. When idle it's a horizontally-swipeable pager — **Start ·
/// Sessions · Settings**; during/after a session it shows the full live screen
/// and summary. Also handles the Action-button cold-launch start, since the
/// button can fire while any idle page is showing.
struct WatchRootView: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if case .idle = session.state {
                TabView {
                    StartView()
                    WatchSessionListView()
                    WatchSettingsView()
                }
            } else {
                SessionRootView()
            }
        }
        .task { await startIfPending() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await startIfPending() } }
        }
    }

    /// Starts the session if the Action button requested it before the app was
    /// ready (see `BeginDiveWorkoutIntent`). No-op otherwise.
    private func startIfPending() async {
        guard LiveSessionRegistry.shared.pendingStart else { return }
        LiveSessionRegistry.shared.pendingStart = false
        await session.start()
    }
}
