import SwiftUI
import SwiftData
import Persistence
import Session

@main
struct DiveFreeWatchApp: App {
    private let store: ModelContainer
    @State private var session: SessionCoordinator

    init() {
        #if DEBUG
        // Screenshot automation (`Scripts/screenshots.sh`): when launched with
        // `--screenshot-demo`, run against a fresh in-memory store seeded with the
        // shared `DemoData` fixtures and a session feed scripted from a fake depth
        // sensor, so the real on-watch database is never touched. Gated on
        // `#if DEBUG` AND the explicit argument, so neither this path nor the code
        // it reaches exists in the App Store binary. Short-circuits before the real
        // store below is opened.
        if WatchScreenshotMode.isEnabled {
            let container = WatchScreenshotMode.makeDemoContainer()
            store = container
            _session = State(
                wrappedValue: SessionCoordinator(
                    modelContext: container.mainContext,
                    sessionManager: WatchScreenshotMode.makeDemoSessionManager(
                        modelContext: container.mainContext
                    )
                )
            )
            // Tell the capture script which localization watchOS actually resolved.
            WatchScreenshotMode.publishResolvedLanguage()
            return
        }
        #endif
        // Force-try is acceptable here: a failed container means irrecoverable
        // storage corruption — the app cannot run safely without it.
        let container = try! DiveStore().container
        store = container
        _session = State(wrappedValue: SessionCoordinator(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(session)
                .unitsAware()
        }
        .modelContainer(store)
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let screen = WatchScreenshotMode.screen {
            // One screen per launch — watchOS has no UI automation to navigate with.
            WatchScreenshotRootView(screen: screen)
        } else {
            normalRootView
        }
        #else
        normalRootView
        #endif
    }

    private var normalRootView: some View {
        WatchRootView()
            // Auto-clean synced sessions off the watch per the retention caps
            // (no-op unless the diver enabled it). Safe: only prunes sessions
            // already confirmed on the iPhone.
            .task { session.pruneForRetention() }
    }
}
