import SwiftUI
import SwiftData
import Domain
import Persistence
import Sync
import Strava
import os

/// App-level `@AppStorage` keys.
enum AppStorageKey {
    /// User's iCloud Sync opt-out (default on). Read at launch to choose the
    /// CloudKit vs local store (#168).
    static let iCloudSyncEnabled = "iCloudSyncEnabled"
}

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
        // CloudKit sync is on by default; the user can opt out in Settings
        // (applied on next launch). Fall back to a local store if CloudKit setup
        // fails, so an iCloud/sync error can never block launch (#168).
        let syncEnabled = UserDefaults.standard.object(forKey: AppStorageKey.iCloudSyncEnabled) as? Bool ?? true
        let log = Logger(subsystem: "org.yurko.divefree", category: "Persistence")
        if syncEnabled {
            do {
                container = try DiveStore(cloudKitContainerID: DiveSchema.cloudKitContainerID).container
                log.notice("SwiftData container initialized WITH CloudKit (\(DiveSchema.cloudKitContainerID, privacy: .public)).")
                return
            } catch {
                // Don't crash on a CloudKit failure — fall back to a local store —
                // but log loudly (this was previously a silent `try?`, which hid
                // exactly the kind of failure that leaves the CloudKit schema empty).
                log.error("CloudKit container init FAILED; using local store. Error: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            container = try DiveStore().container
            log.notice("SwiftData container initialized LOCAL-ONLY (iCloud sync \(syncEnabled ? "failed" : "off", privacy: .public)).")
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(strava)
                .environment(\.syncManager, sync)
                .unitsAware()
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
                    // Mirror a watch-side deletion: drop the phone's copy (and its
                    // photo thumbnails) so a discarded session doesn't linger.
                    sync.onDeleteSession = { id in
                        Task { @MainActor in
                            let context = container.mainContext
                            var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
                            descriptor.fetchLimit = 1
                            guard let session = try? context.fetch(descriptor).first else { return }
                            for photo in (session.photos ?? []) { PhotoStore.delete(photo.thumbnailFileName) }
                            context.delete(session)
                            try? context.save()
                        }
                    }
                    // Store voice-note files the watch transfers, keyed by the
                    // name the markers reference, so they're playable from detail.
                    sync.audioDirectory = VoiceNoteStore.directory
                    // Tell any open detail view a clip landed so its play button
                    // re-enables (SwiftUI can't observe the filesystem).
                    sync.onReceiveAudioFile = { _ in
                        Task { @MainActor in
                            NotificationCenter.default.post(name: .voiceNoteReceived, object: nil)
                        }
                    }
                    sync.activate()
                    // Push current custom markers so the Watch carousel has them.
                    let descriptor = FetchDescriptor<CustomMarkerRecord>(sortBy: [SortDescriptor(\.createdAt)])
                    let markers = (try? container.mainContext.fetch(descriptor)) ?? []
                    sync.sendCustomMarkers(markers.map { $0.toMarkerKind() })
                    // Push the current units preference so the watch matches the phone.
                    sync.sendUnitPreference(.current)
                }
        }
        .modelContainer(container)
    }
}
