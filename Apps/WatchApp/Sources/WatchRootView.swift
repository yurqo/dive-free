import SwiftUI
import CoreMotion
import WatchKit

/// Watch home. When idle it's a horizontally-swipeable pager — **Start ·
/// Sessions · Settings**; during/after a session it shows the full live screen
/// and summary. Also handles the Action-button cold-launch start, since the
/// button can fire while any idle page is showing.
struct WatchRootView: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoLaunchReminderEnabled") private var autoLaunchReminderEnabled = true
    @State private var showAutoLaunchReminder = false
    @State private var checkedAutoLaunchThisLaunch = false

    /// A submerged launch already means Auto-Launch is working; don't interrupt
    /// the in-water session with setup guidance.
    var wasAutomaticallyLaunched = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await startIfPending()
            await checkAutoLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await startIfPending()
                    await checkAutoLaunch()
                }
            }
        }
        .sheet(isPresented: $showAutoLaunchReminder) {
            AutoLaunchReminderView(reminderEnabled: $autoLaunchReminderEnabled)
        }
    }

    /// Starts the session if the Action button requested it before the app was
    /// ready (see `BeginDiveWorkoutIntent`). No-op otherwise.
    private func startIfPending() async {
        guard LiveSessionRegistry.shared.pendingStart else { return }
        LiveSessionRegistry.shared.pendingStart = false
        await session.start()
    }

    /// WatchKit's status request may show Apple's one-time system authorization
    /// prompt. Respect the user's reminder switch before making the request, and
    /// only offer setup guidance when the watch reports that Dive Free is not the
    /// default app for its underwater session type.
    private func checkAutoLaunch() async {
        guard !checkedAutoLaunchThisLaunch,
              autoLaunchReminderEnabled,
              !wasAutomaticallyLaunched,
              scenePhase == .active,
              case .idle = session.state,
              CMWaterSubmersionManager.waterSubmersionAvailable else { return }

        checkedAutoLaunchThisLaunch = true
        do {
            let status = try await WKExtendedRuntimeSession.requestAutoLaunchAuthorizationStatus()
            guard status == .inactive,
                  autoLaunchReminderEnabled,
                  case .idle = session.state else { return }
            showAutoLaunchReminder = true
        } catch {
            // Unknown or unavailable status is not a reason to interrupt startup.
        }
    }
}
