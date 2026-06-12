import SwiftUI
import SwiftData
import Domain
import Persistence
import Sync
import Strava

@main
struct DiveFreeApp: App {
    @State private var sync = SyncManager()
    @State private var strava = StravaAuthManager(
        store: KeychainTokenStore(),
        webAuth: ASWebAuthenticationProvider()
    )
    /// Built once and shared between the scene and the sync importer so incoming
    /// sessions land in the same store the list queries.
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(DiveSchema.models))
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(strava)
                .environment(\.syncManager, sync)
                .onAppear {
                    let container = container
                    // Persist sessions arriving from the watch into the shared
                    // container; the importer dedupes by id, so the sync layer's
                    // retries can't create duplicates, and `@Query` refreshes the list.
                    sync.onReceiveSession = { session in
                        Task { @MainActor in
                            try? SessionImporter(context: container.mainContext).importSession(session)
                        }
                    }
                    sync.activate()
                    // Push current custom markers so the Watch carousel has them.
                    let descriptor = FetchDescriptor<CustomMarkerRecord>(sortBy: [SortDescriptor(\.createdAt)])
                    let markers = (try? container.mainContext.fetch(descriptor)) ?? []
                    sync.sendCustomMarkers(markers.map { $0.toMarkerKind() })
                }
        }
        .modelContainer(container)
    }
}
