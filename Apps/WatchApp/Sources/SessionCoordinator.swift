import Foundation
import Observation
import SwiftData
import WatchKit
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
        /// Stopped: showing the post-session summary until the diver dismisses it.
        case summary(DiveSession)
    }

    /// A single Crown-menu action. On the surface the diver scrolls to one of
    /// these and confirms it (Action button, or a tap); underwater the Action
    /// button drops a `.note` directly and the menu can't be confirmed.
    enum SessionAction: Equatable, Identifiable {
        case voiceNote
        case mark(MarkerKind)
        case end

        var id: String {
            switch self {
            case .voiceNote: "voiceNote"
            case .mark(let kind): "mark.\(kind.id)"
            case .end: "end"
            }
        }

        var title: String {
            switch self {
            case .voiceNote: "Voice Note"
            case .mark(let kind): kind.label
            case .end: "End Session"
            }
        }

        /// Emoji for marker actions; `nil` for Voice Note / End (which use `systemImage`).
        var emoji: String? {
            switch self {
            case .voiceNote: nil
            case .mark(let kind): kind.emoji
            case .end: nil
            }
        }

        var systemImage: String {
            switch self {
            case .voiceNote: "mic.fill"
            case .mark: "mappin"
            case .end: "stop.fill"
            }
        }
    }

    private(set) var state: State = .idle

    /// Guards `start()` against re-entry during its async setup (see `start()`).
    @ObservationIgnored private var isStarting = false

    var currentDepthMeters: Double { sessionManager.currentDepthMeters }

    // Exposed so `SessionRootView` can bind to elapsed time.
    var elapsedTime: TimeInterval { sessionManager.elapsedTime }

    /// Number of finalized dives detected so far in the current session.
    var diveCount: Int { sessionManager.diveCount }

    /// Running maximum depth (m) observed in the current session.
    var maxDepthMeters: Double { sessionManager.maxDepthMeters }

    /// Maximum depth (m) reached during the dive currently in progress.
    var currentDiveMaxDepth: Double { sessionManager.currentDiveMaxDepth }

    /// Total surface distance traveled this session (meters).
    var surfaceDistanceMeters: Double { sessionManager.surfaceDistanceMeters }

    /// Number of markers placed in the current session.
    var markerCount: Int { sessionManager.markers.count }

    /// Markers placed during the dive currently in progress.
    var currentDiveMarkerCount: Int { sessionManager.currentDiveMarkerCount }

    /// Elapsed time below the surface threshold, or `nil` at the surface.
    var currentDiveElapsed: TimeInterval? { sessionManager.currentDiveElapsed }

    /// Seconds at the surface since the last dive ended, or `nil` when submerged
    /// or before the first completed dive. Drives the surface-interval timer.
    var surfaceInterval: TimeInterval? { sessionManager.surfaceInterval }

    /// True while the diver is below the surface threshold. The Action button
    /// drops a marker when submerged and confirms the focused menu item when at
    /// the surface.
    var isSubmerged: Bool { sessionManager.currentDiveStart != nil }

    /// When the most recent GPS fix arrived this session, or `nil` if none yet.
    /// Drives the live GPS-status indicator on the active screen.
    var lastLocationFixAt: Date? { sessionManager.lastLocationFixAt }

    /// Horizontal accuracy (meters) of the most recent GPS fix, or `nil` if
    /// unknown. Drives the "±N m" accuracy readout next to the GPS icon.
    var lastLocationAccuracy: Double? { sessionManager.lastLocationAccuracy }

    /// Whether this watch can measure depth (Ultra / Series 10+). When false
    /// (Series 9 and earlier, SE) the UI hides depth and runs GPS + markers only.
    var hasDepthSensor: Bool { DepthSensor.isAvailable }

    // MARK: - Crown action menu

    /// User-defined custom marker kinds, synced from the iPhone.
    private(set) var customKinds: [MarkerKind] = []

    /// Menu the Crown scrolls through, top → bottom: Voice Note, the diver's
    /// default marker, the remaining kinds (built-in + custom), then End.
    var menuItems: [SessionAction] {
        let kinds = EventKind.builtInMarkerKinds + customKinds
        let defaultID = defaultMarkerKindID
        let ordered = (kinds.first { $0.id == defaultID }.map { [$0] } ?? [])
            + kinds.filter { $0.id != defaultID }
        return [.voiceNote] + ordered.map(SessionAction.mark) + [.end]
    }

    /// Index of the currently highlighted menu item (Crown-driven).
    private(set) var focusedIndex: Int = 0

    /// Id of the diver's preferred default marker (Settings → Default marker).
    /// Pre-selected in the carousel and dropped by the Action button underwater.
    private var defaultMarkerKindID: String {
        UserDefaults.standard.string(forKey: "defaultMarkerKindID") ?? EventKind.note.rawValue
    }

    /// The default marker kind resolved against the built-in + custom kinds,
    /// falling back to `.note` if the stored id no longer exists.
    var defaultMarkerKind: MarkerKind {
        (EventKind.builtInMarkerKinds + customKinds).first { $0.id == defaultMarkerKindID }
            ?? MarkerKind(.note)
    }

    /// Carousel index of the default marker, so a fresh session starts focused on
    /// it (falls back to the first item).
    private var defaultFocusIndex: Int {
        menuItems.firstIndex {
            if case .mark(let kind) = $0 { return kind.id == defaultMarkerKindID }
            return false
        } ?? 0
    }

    /// True while the end-session confirmation dialog should be shown. Confirming
    /// End (Crown + Action button, or a tap) arms this rather than ending
    /// immediately, so an accidental confirm can't cut a session short.
    var pendingEndConfirmation = false

    /// Number of sessions handed to sync but not yet confirmed delivered to the
    /// iPhone. Drives the post-session pending/synced badge.
    private(set) var pendingSyncCount = 0

    /// Set when a session fails to start (HealthKit/sensor unavailable or
    /// permission denied) so the idle screen can explain it instead of silently
    /// doing nothing. Cleared on the next start attempt.
    private(set) var startError: String?

    func addMarker(kind: MarkerKind) {
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
        case .voiceNote:
            Task { await toggleVoiceNote() }
        case .mark(let kind):
            addMarker(kind: kind)
            DiveHapticPlayer.play(.markerPlaced)
        case .end:
            pendingEndConfirmation = true
        }
    }

    /// Confirms the armed end-session request and tears the session down.
    func confirmEnd() {
        pendingEndConfirmation = false
        Task { await stop() }
    }

    /// Invoked by the Apple Watch Ultra Action + side button dual-click (routed
    /// through the Pause/Resume workout intents). We don't pause; instead this is
    /// a touch-free way to end while water-locked: the first dual-click arms the
    /// end confirmation, a second confirms and ends. Haptics stand in for the
    /// dialog the diver may not be able to see underwater.
    func handleEndGesture() {
        switch state {
        case .active:
            if pendingEndConfirmation {
                DiveHapticPlayer.play(.surface)
                confirmEnd()
            } else {
                pendingEndConfirmation = true
                DiveHapticPlayer.play(.markerPlaced)
            }
        case .summary:
            // After a dive the dual-click is the touch-free "Done" — dismiss the
            // summary (the Action button alone already starts a new session).
            dismissSummary()
        case .idle:
            break
        }
    }

    /// Dismisses the post-session summary and returns to the start screen.
    func dismissSummary() {
        guard case .summary = state else { return }
        state = .idle
    }

    /// Context-sensitive Action-button handler. Submerged → drop a `.note`
    /// (screen is water-locked, so the menu can't be confirmed); on the surface
    /// → confirm the focused menu item.
    func handleActionButton() {
        guard case .active = state else { return }
        if isSubmerged {
            // Underwater the screen is water-locked but the Crown still moves the
            // highlight, so place the focused marker — or the default when the
            // diver is parked on End (we never end a dive via the Action button
            // underwater; that's the Action + side dual-click).
            if menuItems.indices.contains(focusedIndex),
               case .mark(let kind) = menuItems[focusedIndex] {
                addMarker(kind: kind)
            } else {
                addMarker(kind: defaultMarkerKind)
            }
            DiveHapticPlayer.play(.markerPlaced)
        } else {
            confirmFocused()
        }
    }

    private let sessionManager: SessionManager
    let workout = WorkoutController()
    private let sync = SyncManager()
    let audioRecorder = AudioNoteRecorder()

    /// True while a surface voice note is recording. Drives the carousel pill.
    var isRecordingVoiceNote: Bool { audioRecorder.isRecording }

    init(modelContext: ModelContext) {
        sessionManager = SessionManager(modelContext: modelContext)
        sessionManager.onHapticEvent = { DiveHapticPlayer.play($0) }
        // Auto-stop a surface voice note the instant the diver submerges.
        sessionManager.onSubmerge = { [weak self] in self?.stopVoiceNote() }
        // The hard cap also stops via the coordinator so the file is still attached.
        audioRecorder.onCap = { [weak self] in self?.stopVoiceNote() }
        sync.onPendingCountChange = { [weak self] count in
            Task { @MainActor in self?.pendingSyncCount = count }
        }
        sync.onReceiveCustomMarkers = { [weak self] kinds in
            Task { @MainActor in self?.customKinds = kinds }
        }
        sync.activate()
        // Let the Action-button intent route into this live coordinator.
        LiveSessionRegistry.shared.coordinator = self
    }

    /// Starts a surface voice note, or stops the current one. Surface-only;
    /// underwater the screen is water-locked and recording auto-stops anyway.
    func toggleVoiceNote() async {
        guard case .active = state else { return }
        if audioRecorder.isRecording {
            stopVoiceNote()
        } else {
            guard !isSubmerged else { return }
            if await audioRecorder.start() {
                // The mic-permission prompt can take a while; if the diver
                // submerged during it, the onSubmerge auto-stop already missed
                // (isRecording was still false), so stop now instead of recording
                // underwater with no way to stop until the cap.
                if isSubmerged {
                    stopVoiceNote()
                } else {
                    WKInterfaceDevice.current().play(.start)
                }
            }
        }
    }

    /// Stops recording (if any), attaches the clip to the last marker, and
    /// returns focus to that marker type so the next confirm places another.
    private func stopVoiceNote() {
        guard let fileName = audioRecorder.stop() else { return }
        sessionManager.attachAudioToLastMarker(fileName)
        WKInterfaceDevice.current().play(.stop)
        focusedIndex = lastMarkerFocusIndex
    }

    /// Carousel index of the most-recently-placed marker's kind, or the default.
    private var lastMarkerFocusIndex: Int {
        if let kind = sessionManager.markers.last?.kind,
           let index = menuItems.firstIndex(where: {
               if case .mark(let item) = $0 { return item.id == kind.id }
               return false
           }) {
            return index
        }
        return defaultFocusIndex
    }

    func start() async {
        // Allow starting from idle OR straight from the post-session summary, so
        // the diver can begin a new session right after ending one (e.g. via the
        // Action button) without first tapping Done. Only block a double-start.
        if case .active = state { return }
        // Re-entrancy guard: start() awaits (HealthKit auth/start) before state
        // flips to .active, so two triggers (Dive Again + Action button) could
        // otherwise both pass the check and start two workouts.
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        startError = nil
        do {
            try await workout.requestAuthorization()
            try await workout.start()
            try await sessionManager.startSession()
            focusedIndex = defaultFocusIndex
            pendingEndConfirmation = false
            state = .active(start: sessionManager.startTime ?? Date())
        } catch {
            // HealthKit unavailable (e.g. simulator), sensor unavailable, or
            // permission denied. Surface the underlying reason so the diver (and
            // we) can tell a permission denial from an entitlement/setup issue,
            // then retry.
            let nsError = error as NSError
            startError = "Couldn't start: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]\n\nCheck Motion & Health access for Dive Free in Settings."
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
            // Ship any voice-note files the session's markers reference.
            for fileName in session.markers.compactMap(\.audioFileName) {
                sync.sendAudioFile(AudioNoteRecorder.url(for: fileName), fileName: fileName)
            }
            state = .summary(session)
        } else {
            state = .idle
        }
        return session
    }
}
