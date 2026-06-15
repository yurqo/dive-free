import SwiftUI
import SwiftData
import Persistence
import Session

@main
struct DiveFreeWatchApp: App {
    private let store: DiveStore
    @State private var session: SessionCoordinator

    init() {
        // Force-try is acceptable here: a failed container means irrecoverable
        // storage corruption — the app cannot run safely without it.
        let store = try! DiveStore()
        self.store = store
        _session = State(wrappedValue: SessionCoordinator(modelContext: store.container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(session)
        }
        .modelContainer(store.container)
    }
}
