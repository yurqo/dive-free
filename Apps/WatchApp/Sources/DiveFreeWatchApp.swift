import SwiftUI

@main
struct DiveFreeWatchApp: App {
    @State private var session = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            SessionRootView()
                .environment(session)
        }
    }
}
