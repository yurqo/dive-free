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
    @State private var liveSession = LiveSessionMonitor()
    @State private var photoPager = PhotoPagerPresenter()
    @State private var photoSuggestions = PhotoSuggestionPresenter()
    @State private var cloudSync = CloudKitSyncMonitor()
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
                .environment(liveSession)
                .environment(photoPager)
                .environment(photoSuggestions)
                .environment(cloudSync)
                .environment(\.syncManager, sync)
                .unitsAware()
                .onAppear {
                    // Surface CloudKit sync status + errors (the diagnostic for
                    // cross-device photo sync).
                    cloudSync.start()
                    // Reflect an in-progress Watch session on the phone: banner +
                    // Live Activity (#118). Latest-value over the app context.
                    sync.onReceiveLiveSession = { snapshot in
                        Task { @MainActor in liveSession.ingest(snapshot) }
                    }
                    let container = container
                    // Persist sessions arriving from the watch into the shared
                    // container; the importer dedupes by id, so the sync layer's
                    // retries can't create duplicates, and `@Query` refreshes the list.
                    sync.onReceiveSession = { session in
                        Task { @MainActor in
                            try? SessionImporter(
                                context: container.mainContext,
                                mirrorAudio: { VoiceNoteStore.mirrorAudioData(into: $0) }
                            ).importSession(session)
                        }
                    }
                    // Mirror a watch-side deletion: drop the phone's copy (and its
                    // on-disk photo thumbnails + voice notes) so a discarded
                    // session doesn't linger.
                    sync.onDeleteSession = { id in
                        Task { @MainActor in
                            let context = container.mainContext
                            var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
                            descriptor.fetchLimit = 1
                            guard let session = try? context.fetch(descriptor).first else { return }
                            deleteLocalArtifacts(of: session)
                            context.delete(session)
                            try? context.save()
                        }
                    }
                    // Store voice-note files the watch transfers, keyed by the
                    // name the markers reference, so they're playable from detail.
                    sync.audioDirectory = VoiceNoteStore.directory
                    // A clip landed from the watch. Mirror its bytes into the
                    // matching marker's `audioData` so it syncs to the iPad via
                    // CloudKit even if the session's detail view is never opened on
                    // this phone (the reconcile that used to be the only path). Then
                    // tell any open detail view so its play button re-enables
                    // (SwiftUI can't observe the filesystem).
                    sync.onReceiveAudioFile = { url in
                        Task { @MainActor in
                            let context = container.mainContext
                            let fileName = url.lastPathComponent
                            var descriptor = FetchDescriptor<MarkerRecord>(
                                predicate: #Predicate { $0.audioFileName == fileName }
                            )
                            descriptor.fetchLimit = 1
                            if let marker = try? context.fetch(descriptor).first,
                               VoiceNoteStore.mirrorAudioData(into: marker) {
                                try? context.save()
                            }
                            NotificationCenter.default.post(name: .voiceNoteReceived, object: nil)
                        }
                    }
                    sync.activate()
                    // Sweep voice-note files orphaned on disk — e.g. a session
                    // deleted on another device drops out here via CloudKit without
                    // the local delete path running, leaving its clip behind. Also
                    // retroactively cleans anything already leaked. Background
                    // priority, after the store is up.
                    Task(priority: .background) { @MainActor in
                        try? await VoiceNoteSweeper(context: container.mainContext).sweep(directory: VoiceNoteStore.directory)
                    }
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
