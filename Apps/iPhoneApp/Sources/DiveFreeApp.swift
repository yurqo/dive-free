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
    // No default values: `init` assigns these unconditionally via
    // `State(initialValue:)` after wiring them together. A stored-property default
    // would build (and immediately discard) a throwaway pair on every launch —
    // dead allocations, and a trap waiting to happen if those inits ever gain side
    // effects.
    @State private var sync: SyncManager
    @State private var liveSession: LiveSessionMonitor
    @State private var photoPager = PhotoPagerPresenter()
    @State private var photoSuggestions = PhotoSuggestionPresenter()
    @State private var cloudSync = CloudKitSyncMonitor()
    /// Optional "Support DiveFree" tip jar. Ships dark: it self-activates only when
    /// the App Store Connect products are live AND the remote kill-switch is on
    /// (see `SupportStore`). `start()` runs at launch, background priority.
    @State private var support = SupportStore()
    @State private var strava = StravaAuthManager(
        store: KeychainTokenStore(),
        webAuth: ASWebAuthenticationProvider()
    )
    /// Built once and shared between the scene and the sync importer so incoming
    /// sessions land in the same store the list queries.
    private let container: ModelContainer

    init() {
        let container = Self.makeContainer()
        self.container = container
        // Wire and activate WatchConnectivity at process startup — NOT in the
        // scene's `.onAppear`. When the watch transfers data to a terminated
        // phone, iOS relaunches the app in the *background*, where the scene
        // never renders and `.onAppear` never fires; doing the wiring here means
        // a background launch still ingests sessions/audio and drives the live
        // mirror. Every moved line is scene-independent (SwiftData writes over
        // `container.mainContext`, WCSession, filesystem, notifications) — the
        // only genuinely UI-bound bit, `cloudSync.start()`, stays in `.onAppear`.
        let sync = SyncManager()
        let liveSession = LiveSessionMonitor()
        Self.configureSync(sync, liveSession: liveSession, container: container)
        // Observe the Live Activity push-to-start token (iOS 17.2+, #18 stage 2)
        // from init so a background WC launch captures/rotates it too. Persists the
        // latest token for the background push-to-start fallback in LiveSessionMonitor.
        if #available(iOS 17.2, *) { PushToStartRegistrar.start() }
        _sync = State(initialValue: sync)
        _liveSession = State(initialValue: liveSession)
    }

    /// Builds the shared SwiftData container. CloudKit sync is on by default; the
    /// user can opt out in Settings (applied on next launch). Falls back to a
    /// local store if CloudKit setup fails, so an iCloud/sync error can never
    /// block launch (#168).
    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        // Screenshot automation: when launched with `--screenshot-demo`, bypass
        // the CloudKit/local store entirely and use a fresh in-memory store seeded
        // with deterministic demo content (`DemoData`, in the Persistence package
        // so the watch screenshots seed from the same fixtures). Gated on `#if DEBUG`
        // AND the explicit argument, so this path — and the seeding code — is
        // completely absent from Release builds (the App Store binary never
        // contains it). Short-circuits BEFORE any CloudKit setup below.
        if ProcessInfo.processInfo.arguments.contains("--screenshot-demo") {
            do {
                let store = try DiveStore(inMemory: true)
                DemoData.seed(into: store.container.mainContext)
                return store.container
            } catch {
                fatalError("Failed to create the in-memory demo container: \(error)")
            }
        }
        #endif
        let syncEnabled = UserDefaults.standard.object(forKey: AppStorageKey.iCloudSyncEnabled) as? Bool ?? true
        let log = Logger(subsystem: "org.yurko.divefree", category: "Persistence")
        if syncEnabled {
            do {
                let container = try DiveStore(cloudKitContainerID: DiveSchema.cloudKitContainerID).container
                log.notice("SwiftData container initialized WITH CloudKit (\(DiveSchema.cloudKitContainerID, privacy: .public)).")
                return container
            } catch {
                // Don't crash on a CloudKit failure — fall back to a local store —
                // but log loudly (this was previously a silent `try?`, which hid
                // exactly the kind of failure that leaves the CloudKit schema empty).
                log.error("CloudKit container init FAILED; using local store. Error: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            let container = try DiveStore().container
            log.notice("SwiftData container initialized LOCAL-ONLY (iCloud sync \(syncEnabled ? "failed" : "off", privacy: .public)).")
            return container
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
    }

    /// Installs the WatchConnectivity receive handlers and pushes launch-time
    /// context, then activates the session. Called from `init` so it runs on a
    /// background WC launch too (see `init`). `@MainActor` because it touches the
    /// container's main context and the main-actor `LiveSessionMonitor`; `init`
    /// is already main-actor-isolated (the `App` conformance is).
    @MainActor
    private static func configureSync(
        _ sync: SyncManager,
        liveSession: LiveSessionMonitor,
        container: ModelContainer
    ) {
        // Reflect an in-progress Watch session on the phone: banner + Live
        // Activity (#118). Latest-value over the app context.
        sync.onReceiveLiveSession = { snapshot in
            Task { @MainActor in liveSession.ingest(snapshot) }
        }
        // Persist sessions arriving from the watch into the shared container; the
        // importer dedupes by id, so the sync layer's retries can't create
        // duplicates, and `@Query` refreshes the list.
        sync.onReceiveSession = { session, isResync in
            Task { @MainActor in
                // An explicit watch re-send ("Re-send to iPhone"/"Re-send all") is a
                // deliberate recovery: clear any tombstone first so the import isn't
                // rejected as a stale re-delivery of a session the user removed here.
                if isResync { DeletionTombstones.remove(session.id) }
                let context = container.mainContext
                do {
                    let imported = try SessionImporter(
                        context: context,
                        mirrorAudio: { VoiceNoteStore.mirrorAudioData(into: $0) },
                        // Skip a session the user already deleted here, so a late WC
                        // re-delivery can't resurrect it (see `DeletionTombstones`).
                        isTombstoned: { DeletionTombstones.contains($0) }
                    ).importSession(session)
                    // Application-level ACK — the signal watch retention gates on
                    // (WC's transport didFinish fires even if this save threw, which is
                    // the whole bug this closes). Ack only when the session is genuinely
                    // on the phone now: freshly imported, OR an already-present record
                    // being re-delivered (so re-sends still confirm). Do NOT ack a
                    // tombstoned rejection — the user deleted it here; letting the watch
                    // prune its only copy would lose it. On a throw we skip the ack (the
                    // catch below), so retention keeps the watch copy until a later
                    // delivery succeeds.
                    let present = imported
                        || (!DeletionTombstones.contains(session.id) && sessionExists(session.id, in: context))
                    if present { sync.sendImportAck(session.id) }
                } catch {
                    // Save failed — no ack, so the watch keeps its copy and retries.
                    // Roll back the failed INSERT: `mainContext` is long-lived, so the
                    // pending (unsaved) row survives this closure. On the next
                    // re-delivery the importer's dedupe fetch (which includes pending
                    // changes) would see it and skip the import as a false "duplicate",
                    // and the ack condition's `sessionExists` would likewise see it and
                    // fire an ACK for a record that was never persisted — letting the
                    // watch prune its only copy of a session the phone never saved.
                    // Discarding the pending change restores a clean context so the
                    // retry genuinely re-inserts.
                    context.rollback()
                }
            }
        }
        // Mirror a watch-side deletion: drop the phone's copy (and its on-disk
        // photo thumbnails + voice notes) so a discarded session doesn't linger.
        sync.onDeleteSession = { id in
            Task { @MainActor in
                // Tombstone first, so even if the delete below finds no record (the
                // payload hasn't been imported yet) a later re-delivery is still
                // rejected by the importer.
                DeletionTombstones.record(id)
                let context = container.mainContext
                var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard let session = try? context.fetch(descriptor).first else { return }
                deleteLocalArtifacts(of: session)
                context.delete(session)
                try? context.save()
            }
        }
        // Store voice-note files the watch transfers, keyed by the name the
        // markers reference, so they're playable from detail.
        sync.audioDirectory = VoiceNoteStore.directory
        // A clip landed from the watch. Mirror its bytes into the matching
        // marker's `audioData` so it syncs to the iPad via CloudKit even if the
        // session's detail view is never opened on this phone (the reconcile that
        // used to be the only path). Then tell any open detail view so its play
        // button re-enables (SwiftUI can't observe the filesystem).
        sync.onReceiveAudioFile = { url in
            Task { @MainActor in
                let context = container.mainContext
                let fileName = url.lastPathComponent
                // The file is already copied into storage by the time this fires (the
                // receiver only calls back on a successful copy), so ACK it: this — not
                // the transport didFinish — is the safe signal watch retention gates on
                // before pruning the clip's only copy (the copy can fail silently).
                sync.sendAudioImportAck(fileName)
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
        // Sweep voice-note files orphaned on disk — e.g. a session deleted on
        // another device drops out here via CloudKit without the local delete
        // path running, leaving its clip behind. Also retroactively cleans
        // anything already leaked. Background priority, after the store is up.
        Task(priority: .background) { @MainActor in
            try? await VoiceNoteSweeper(context: container.mainContext).sweep(directory: VoiceNoteStore.directory)
        }
        // Push current custom markers so the Watch carousel has them.
        let descriptor = FetchDescriptor<CustomMarkerRecord>(sortBy: [SortDescriptor(\.createdAt)])
        let markers = (try? container.mainContext.fetch(descriptor)) ?? []
        sync.sendCustomMarkers(markers.map { $0.toMarkerKind() })
        // Push the current units preference so the watch matches the phone.
        sync.sendUnitPreference(.current)
        // Re-push the diver's dive-detection config. `updateApplicationContext`
        // replaces the whole dictionary and `outgoingContext` starts empty each
        // process, so without this the markers/units pushes above would wipe the
        // previously-synced detectionKey. Read the same stored blob the settings
        // screen writes.
        sync.sendDetectionConfig(DiveDetectionSettings.load().config)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(strava)
                .environment(liveSession)
                .environment(photoPager)
                .environment(photoSuggestions)
                .environment(cloudSync)
                .environment(support)
                .environment(\.syncManager, sync)
                .unitsAware()
                // Fetch the remote kill-switch + StoreKit products at launch, off
                // the main path. Best-effort — a miss leaves the tip jar on its
                // cached (default hidden) state.
                .task(priority: .background) { await support.start() }
                .onAppear {
                    // Surface CloudKit sync status + errors (the diagnostic for
                    // cross-device photo sync). UI-only, so it can stay here — the
                    // WatchConnectivity wiring moved to `init` (see `configureSync`)
                    // so a background WC launch runs it without a rendered scene.
                    cloudSync.start()
                }
                // Lets the screenshot UI test verify the language override actually
                // took effect. No-op in Release and outside `--screenshot-demo`.
                .screenshotLanguageProbe()
        }
        .modelContainer(container)
    }
}

extension View {
    /// Publishes the *resolved* localization of this process to the screenshot UI
    /// test, as an accessibility identifier of the form `screenshot.lang.<code>`
    /// (e.g. `screenshot.lang.uk`), where the code is
    /// `Bundle.main.preferredLocalizations.first` — i.e. the localization iOS
    /// actually picked for this launch, not the one we asked for.
    ///
    /// WHY: `Scripts/screenshots.sh` reuses one build across all 8 locales via
    /// `test-without-building -xctestrun`, a path on which `-testLanguage` is
    /// silently ignored. The failure mode is catastrophically quiet — every locale
    /// renders in the simulator's language and 8 identical sets get uploaded to App
    /// Store Connect (which happened once, 80 wrong PNGs). Every indirect proxy for
    /// "did the language apply" is unreliable: the image-diff check the script also
    /// runs was verified to pass on the exact historical data that shipped those 80
    /// Ukrainian screenshots, because a few pixels of map-thumbnail jitter made the
    /// sets differ anyway. So the app states its resolved localization out loud and
    /// `ScreenshotTests` asserts it equals what was requested — a direct check that
    /// cannot be fooled by rendering noise.
    ///
    /// Cost in shipping builds: none. The whole body is `#if DEBUG`, and even in
    /// DEBUG it only renders when the process was launched with
    /// `--screenshot-demo` (the same flag that swaps in the in-memory demo store).
    /// The probe itself is a 1pt clear glyph: present in the accessibility tree,
    /// invisible in the captured PNG.
    func screenshotLanguageProbe() -> some View {
        #if DEBUG
        overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--screenshot-demo") {
                // `Text` (not `Color.clear`) because SwiftUI only surfaces this as a
                // queryable element if it has content; `.foregroundStyle(.clear)`
                // keeps it in the accessibility tree while `.opacity(0)`/`.hidden()`
                // would remove it — the identifier has to stay findable.
                Text(verbatim: "·")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier(
                        "screenshot.lang.\(Bundle.main.preferredLocalizations.first ?? "unknown")"
                    )
            }
        }
        #else
        self
        #endif
    }
}

/// Whether a session record with `id` is present in the store. Used by the import
/// ack path to confirm an already-imported session (a re-delivery) is genuinely on
/// the phone before acking it, so a duplicate re-send still confirms delivery.
@MainActor
private func sessionExists(_ id: UUID, in context: ModelContext) -> Bool {
    var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return (try? context.fetch(descriptor).first) != nil
}
