import Foundation
import Observation
import SwiftData
import WatchKit
import Domain
import Persistence
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

    /// The Crown-menu action type, defined by the pure, testable interaction model
    /// in the `Session` package.
    typealias SessionAction = SessionInteraction.Action

    private(set) var state: State = .idle

    /// Guards `start()` against re-entry during its async setup (see `start()`).
    @ObservationIgnored private var isStarting = false

    /// Guards `stop()`'s teardown against a voice note started or stopped mid-way.
    /// `stop()` suspends (awaiting the merge task, then `workout.end()`); a new
    /// recording begun or a final clip stitched during that window would spawn a
    /// `pendingMergeTask` the already-captured `await` never waits on, silently
    /// dropping the clip. Set true at the top of `stop()`, reset before returning.
    @ObservationIgnored private var isStopping = false

    /// In-flight voice-note stitch (merging a new clip onto the last marker's
    /// existing one). `stop()` awaits it so the saved session references the
    /// merged clip rather than a source file the merge is about to delete.
    @ObservationIgnored private var pendingMergeTask: Task<Void, Never>?

    var currentDepthMeters: Double { sessionManager.currentDepthMeters }

    /// Live heart rate (bpm) from the workout, or `nil` until the first reading.
    var currentHeartRate: Int? { workout.currentHeartRate }

    /// Live water temperature (°C) from the submersion sensor, or `nil`.
    var currentTemperatureCelsius: Double? { sessionManager.currentTemperatureCelsius }

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

    /// Whether the dive in progress has met the detector's criteria (so it's being
    /// logged). Drives the live screen's switch from the provisional descent
    /// (surface icon + greyed depth/countdown) to the confirmed dive readout.
    var currentDiveConfirmed: Bool { sessionManager.currentDiveConfirmed }

    /// Seconds until the descending dive locks in, or `nil` at the surface / once
    /// confirmed. Drives the greyed "dive in N s" countdown.
    var secondsToDiveConfirmation: TimeInterval? { sessionManager.secondsToDiveConfirmation }

    /// Seconds at the surface since the last dive ended, or `nil` when submerged
    /// or before the first completed dive. Drives the surface-interval timer.
    var surfaceInterval: TimeInterval? { sessionManager.surfaceInterval }

    /// Duration of the most recently completed dive, or `nil` before the first
    /// dive. Used to scale the recommended surface-interval (recovery) thresholds.
    var lastDiveDuration: TimeInterval? { sessionManager.dives.last?.duration }

    /// Max depth (m) of the most recently completed dive, or `nil` before the
    /// first dive. Shown during the surface interval as recovery context.
    var lastDiveMaxDepth: Double? { sessionManager.dives.last?.maxDepthMeters }

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

    /// Whether this watch has an Action button (Ultra only). No public API exists,
    /// so on device we default to `true` — worst case a non-Ultra shows the action
    /// selector, which is harmless (the surface tap-to-confirm fallback works). The
    /// simulator honours the Settings override so the no-Action-button flow is
    /// testable.
    var hasActionButton: Bool {
        #if targetEnvironment(simulator)
        return SimCapabilityOverride.value(SimCapabilityOverride.actionButtonKey)
        #else
        return true
        #endif
    }

    // MARK: - Crown action menu

    /// User-defined custom marker kinds, synced from the iPhone.
    private(set) var customKinds: [MarkerKind] = []

    /// Pure, testable interaction model (menu, focus, button routing, end arming).
    /// Initialized with the built-in kinds so the Settings scroll-speed preview has
    /// a menu while idle; rebuilt with the diver's default focus at session start
    /// and refreshed when custom markers sync in.
    private var interaction = SessionInteraction(
        kinds: EventKind.builtInMarkerKinds, defaultMarkerID: EventKind.note.rawValue
    )

    /// Menu the Crown scrolls through (Voice Note, the marker kinds, End).
    var menuItems: [SessionAction] { interaction.menuItems }

    /// Index of the currently highlighted menu item (Crown-driven).
    var focusedIndex: Int { interaction.focusedIndex }

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

    /// Rebuilds the interaction menu for the current kinds + default (preserving
    /// focus); call when custom markers change.
    private func refreshMenu() {
        interaction.setMenu(kinds: EventKind.builtInMarkerKinds + customKinds, defaultMarkerID: defaultMarkerKindID)
    }

    /// True while the end-session confirmation dialog should be shown (armed via
    /// Crown → End → Action button). Bound to the dialog's `isPresented`; setting
    /// it false (dismiss/cancel) clears the arm.
    var pendingEndConfirmation: Bool {
        get { interaction.pendingEndConfirmation }
        set { interaction.setPendingEnd(newValue) }
    }

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

    /// Moves the Crown highlight (clamped). Nothing fires until a button confirms.
    func focus(_ index: Int) {
        guard case .active = state else { return }
        interaction.focus(index)
    }

    /// Surface confirm — the Action button at the surface, or a screen tap.
    func confirmFocused() {
        guard case .active = state else { return }
        execute(interaction.confirmFocused())
    }

    /// Confirms the armed end-session request and tears the session down. Called
    /// by the dialog's on-screen button and by the Action + side confirm.
    func confirmEnd() {
        interaction.setPendingEnd(false)
        Task { await stop() }
    }

    /// Dismisses the post-session summary and returns to the start screen.
    func dismissSummary() {
        guard case .summary = state else { return }
        state = .idle
    }

    /// Discards the just-finished session from the post-dive summary — for an
    /// accidental session (started by mistake, no real dives). Deletes the local
    /// record and its voice notes, discards the Health workout `stop()` saved so
    /// the accident stops counting toward the Fitness rings, and tells the phone to
    /// drop its copy (see `deleteSession`), then returns to the start screen.
    ///
    /// `stop()` already queued the session's payload to the phone; the deletion is
    /// a separate message delivered after it (FIFO), so once both land the phone
    /// ends up without the session. Until `sendDeletion` also cancels the OS
    /// transfer (next work item), a relaunch that re-adopts the not-yet-delivered
    /// payload before the deletion arrives is a remaining edge.
    func discardSummary() {
        guard case .summary(let session) = state else { return }
        WKInterfaceDevice.current().play(.success)
        deleteSession(session.id)
        // Delete the Health workout too, but don't block the return to idle on it.
        Task { await workout.discardFinishedWorkout() }
        state = .idle
    }

    /// Action button (`AddMarkerIntent`). Context-sensitive: cancels the end
    /// dialog if armed; underwater drops the focused marker (or the default when
    /// parked on a non-marker); at the surface confirms the focused item.
    func handleActionButton() {
        guard case .active = state else { return }
        execute(interaction.actionButton(isSubmerged: isSubmerged, defaultMarker: defaultMarkerKind))
    }

    /// Action + side dual-click. In a live session it toggles a manual dive — or,
    /// while the end dialog is armed, confirms the end. On the post-session summary
    /// it's the touch-free "Done".
    func handleActionSide() {
        switch state {
        case .active:
            execute(interaction.actionSide())
        case .summary:
            dismissSummary()
        case .idle:
            break
        }
    }

    /// Performs the side effect for an interaction `Effect`.
    private func execute(_ effect: SessionInteraction.Effect) {
        switch effect {
        case .none:
            break
        case .placeMarker(let kind):
            addMarker(kind: kind)
            DiveHapticPlayer.play(.markerPlaced)
        case .toggleVoiceNote:
            Task { await toggleVoiceNote() }
        case .toggleManualDive:
            toggleManualDive()
        case .end:
            confirmEnd()
        }
    }

    /// Starts or stops a manual dive (Action + side), with a haptic cue since the
    /// screen may be water-locked.
    private func toggleManualDive() {
        if sessionManager.isManualDiveActive {
            sessionManager.stopManualDive()
            DiveHapticPlayer.play(.surface)
        } else {
            sessionManager.startManualDive()
            DiveHapticPlayer.play(.markerPlaced)
        }
    }

    // MARK: - Time cues (#178)

    /// Drives periodic time cues off the dive lifecycle: tick while submerged, stop
    /// at the surface.
    private func handleTimeCueEvent(_ event: DiveHapticEvent) {
        switch event {
        case .diveStart: startTimeCues()
        case .surface: stopTimeCues()
        default: break
        }
    }

    /// Begins a per-second ticker that plays a minor/major cue on each interval
    /// boundary (relative to the dive start). No-op when cues are disabled. The
    /// inner loop steps one whole second at a time so a sleep that drifts past a
    /// boundary still plays that cue rather than skipping it.
    private func startTimeCues() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "timeCuesEnabled") else { return }
        let minor = defaults.object(forKey: "timeCueMinorSeconds") as? Int ?? 10
        let major = defaults.object(forKey: "timeCueMajorSeconds") as? Int ?? 60
        guard minor > 0 || major > 0 else { return }
        let start = sessionManager.currentDiveStart ?? Date()
        timeCueTask?.cancel()
        timeCueTask = Task { @MainActor in
            var last = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                let elapsed = Int(Date().timeIntervalSince(start))
                while last < elapsed {
                    last += 1
                    if let cue = diveTimeCue(elapsedSeconds: last, minorInterval: minor, majorInterval: major) {
                        DiveTonePlayer.playTimeCue(major: cue == .major)
                        DiveHapticPlayer.playTimeCue(major: cue == .major)
                    }
                }
            }
        }
    }

    private func stopTimeCues() {
        timeCueTask?.cancel()
        timeCueTask = nil
    }

    // MARK: - Live session mirror (watch → phone, #118)

    /// Pushes an immediate snapshot, then one every couple of seconds, so the
    /// phone's in-app banner + Live Activity track the live session. Latest-wins
    /// over the application context, so a missed tick just gets overwritten.
    private func startLiveSync() {
        liveSyncTask?.cancel()
        sendLiveSnapshot(active: true)
        liveSyncTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard case .active = state else { return }
                sendLiveSnapshot(active: true)
            }
        }
    }

    private func stopLiveSync() {
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    /// Sends the current session state to the phone. `active: false` is the
    /// terminal snapshot on stop, telling the phone to end its live display.
    private func sendLiveSnapshot(active: Bool) {
        let start: Date
        if case .active(let s) = state { start = s } else { start = sessionManager.startTime ?? Date() }
        sync.sendLiveSession(LiveSessionSnapshot(
            isActive: active,
            startTime: start,
            depthMeters: currentDepthMeters,
            maxDepthMeters: maxDepthMeters,
            diveCount: diveCount,
            isSubmerged: isSubmerged,
            currentDiveElapsed: currentDiveElapsed
        ))
    }

    private let sessionManager: SessionManager
    private let modelContext: ModelContext
    /// Repeating per-second time-cue ticker, live only while submerged (#178).
    private var timeCueTask: Task<Void, Never>?
    /// Repeating ticker that pushes live snapshots to the phone while active (#118).
    private var liveSyncTask: Task<Void, Never>?
    let workout = WorkoutController()
    private let sync = SyncManager()
    let audioRecorder = AudioNoteRecorder()

    /// True while a surface voice note is recording. Drives the carousel selector.
    var isRecordingVoiceNote: Bool { audioRecorder.isRecording }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        sessionManager = SessionManager(modelContext: modelContext)
        sessionManager.onHapticEvent = { [weak self] event in
            DiveHapticPlayer.play(event)
            DiveTonePlayer.play(for: event)
            self?.handleTimeCueEvent(event)
        }
        // Auto-stop a surface voice note the instant the diver submerges, and
        // collapse the carousel to markers only (Voice Note / End don't work
        // underwater). Restore the full menu on surfacing.
        sessionManager.onSubmerge = { [weak self] in
            self?.stopVoiceNote()
            self?.interaction.setSubmerged(true)
        }
        sessionManager.onSurface = { [weak self] in
            self?.interaction.setSubmerged(false)
        }
        // Feed live workout heart rate into the session's time series.
        workout.onHeartRate = { [weak self] bpm in self?.sessionManager.recordHeartRate(bpm) }
        // The hard cap also stops via the coordinator so the file is still attached.
        audioRecorder.onCap = { [weak self] in self?.stopVoiceNote() }
        sync.onPendingCountChange = { [weak self] count in
            Task { @MainActor in self?.pendingSyncCount = count }
        }
        // Record confirmed deliveries so retention can safely prune synced sessions.
        sync.onSessionDelivered = { [weak self] id in
            Task { @MainActor in self?.markDelivered(id) }
        }
        // Record confirmed voice-note deliveries too, so retention won't prune a
        // session — and delete a clip's only copy — before the phone confirms it.
        sync.onAudioFileDelivered = { [weak self] fileName in
            Task { @MainActor in self?.markAudioDelivered(fileName) }
        }
        sync.onReceiveCustomMarkers = { [weak self] kinds in
            Task { @MainActor in
                self?.customKinds = kinds
                self?.refreshMenu()
            }
        }
        // Mirror the iPhone's units choice into local UserDefaults so the watch's
        // formatters (and Settings pickers) reflect it.
        sync.onReceiveUnitPreference = { preference in
            Task { @MainActor in preference.store() }
        }
        sync.activate()
        // Let the Action-button intent route into this live coordinator.
        LiveSessionRegistry.shared.coordinator = self
    }

    /// Deletes a stored session by id — the watch-side "discard" for an
    /// accidentally-recorded session. Child records cascade-delete locally, and
    /// the iPhone is told to drop its copy too (WatchConnectivity only *sends*
    /// sessions, so the deletion travels as its own message).
    func deleteSession(_ id: UUID) {
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try? modelContext.fetch(descriptor).first {
            // Remove the session's voice-note files too — the SwiftData cascade
            // drops the marker rows but not their files (matches retention below).
            deleteAudioFiles(of: record)
            modelContext.delete(record)
            try? modelContext.save()
        }
        sync.sendDeletion(id)
    }

    /// Removes every voice-note file referenced by a session's markers. Shared by
    /// manual delete and retention pruning so neither leaks audio on disk.
    private func deleteAudioFiles(of record: SessionRecord) {
        for fileName in (record.markers ?? []).compactMap(\.audioFileName) {
            try? FileManager.default.removeItem(at: AudioNoteRecorder.url(for: fileName))
        }
    }

    /// Starts a surface voice note, or stops the current one. Surface-only;
    /// underwater the screen is water-locked and recording auto-stops anyway.
    func toggleVoiceNote() async {
        guard case .active = state else { return }
        if audioRecorder.isRecording {
            stopVoiceNote()
        } else {
            // Don't start a new recording mid-teardown: `stop()` has already
            // captured the merge task it will await, so a clip begun now would
            // never be awaited and its attach would run after the session ended.
            guard !isSubmerged, !isStopping else { return }
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
    /// returns focus to that marker type so the next confirm places another. When
    /// the last marker already carries a clip, the new one is stitched onto it
    /// (off the main actor) so repeated recordings accumulate instead of the newer
    /// overwriting — and orphaning — the older.
    private func stopVoiceNote() {
        guard let fileName = audioRecorder.stop() else { return }
        WKInterfaceDevice.current().play(.stop)
        // Capture the target marker's id now and attach by id after any in-flight
        // merge finishes — so a marker placed while the merge runs can't steal the
        // clip, and the real target can't end up pointing at a deleted source.
        // Chaining onto the previous merge serializes them (no overlapping file I/O).
        let targetID = sessionManager.markers.last?.id
        let previous = pendingMergeTask
        pendingMergeTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            if let targetID,
               let existing = self.sessionManager.markers.first(where: { $0.id == targetID })?.audioFileName {
                // The target marker already has a clip — stitch the new one onto it.
                do {
                    let merged = try await AudioNoteRecorder.merge(existing, with: fileName)
                    self.sessionManager.attachAudio(merged, toMarkerWithID: targetID)
                } catch {
                    // Merge failed: keep the existing clip on the target marker and
                    // carry the new one on a fresh .note marker, so neither recording
                    // is lost (the old behaviour dropped the existing clip's file).
                    self.sessionManager.addMarker(kind: MarkerKind(.note))
                    self.sessionManager.attachAudioToLastMarker(fileName)
                }
            } else if let targetID {
                self.sessionManager.attachAudio(fileName, toMarkerWithID: targetID)
            } else {
                // No markers yet — drop a .note marker to carry the clip.
                self.sessionManager.attachAudioToLastMarker(fileName)
            }
            self.interaction.focus(self.lastMarkerFocusIndex)
        }
    }

    /// Carousel index of the most-recently-placed marker's kind, or the current
    /// focus when there's no marker to point at.
    private var lastMarkerFocusIndex: Int {
        if let kind = sessionManager.markers.last?.kind,
           let index = menuItems.firstIndex(where: {
               if case .mark(let item) = $0 { return item.id == kind.id }
               return false
           }) {
            return index
        }
        return focusedIndex
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
            // Fresh interaction: menu rebuilt, focused on the default marker, end disarmed.
            interaction = SessionInteraction(
                kinds: EventKind.builtInMarkerKinds + customKinds, defaultMarkerID: defaultMarkerKindID
            )
            state = .active(start: sessionManager.startTime ?? Date())
            // Start mirroring the live session to the phone (#118).
            startLiveSync()
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
        // Bar new/late recordings from spawning a merge task the awaits below can't
        // see (see `isStopping`). Reset on every return path.
        isStopping = true
        defer { isStopping = false }
        stopTimeCues()
        stopLiveSync()
        // Tell the phone the session ended so it dismisses the banner/Live Activity.
        sendLiveSnapshot(active: false)
        // Finish recording the final clip FIRST, so its merge task exists before the
        // await below captures `pendingMergeTask` — otherwise a clip stopped during
        // the suspension (via `stopVoiceNote`) would set a fresh, never-awaited task.
        if audioRecorder.isRecording { stopVoiceNote() }
        // Finish any in-flight voice-note stitch, so the saved session references
        // the merged clip and not a source file the merge will delete.
        await pendingMergeTask?.value
        pendingMergeTask = nil
        let activeEnergy = await workout.end()
        let session = try? sessionManager.stopSession(activeEnergyKilocalories: activeEnergy)
        if let session {
            sendSessionToPhone(session)
            state = .summary(session)
        } else {
            state = .idle
        }
        return session
    }

    /// Re-sends a stored session (and its voice-note files) to the iPhone — the
    /// manual recovery when a dive didn't make it across (e.g. the phone was out
    /// of range when it finished). Safe to repeat; the phone upserts by id.
    func resync(_ session: DiveSession) {
        sendSessionToPhone(session)
    }

    /// Re-sends every session stored on this watch to the iPhone.
    func resyncAll() {
        let records = (try? modelContext.fetch(FetchDescriptor<SessionRecord>())) ?? []
        for record in records where record.modelContext != nil {
            sendSessionToPhone(record.toDomain())
        }
    }

    /// Queues a session and its voice notes for delivery to the iPhone — shared by
    /// session-end and manual re-sync.
    private func sendSessionToPhone(_ session: DiveSession) {
        try? sync.send(session)
        for fileName in session.markers.compactMap(\.audioFileName) {
            sync.sendAudioFile(AudioNoteRecorder.url(for: fileName), fileName: fileName)
        }
    }

    // MARK: - Retention (auto-clean synced sessions off the watch)

    /// Persisted set of session ids confirmed delivered to the phone. Watch-only
    /// (UserDefaults, not the model), so no schema change; only grows, and only on
    /// genuine delivery — so it never falsely marks an unsynced session.
    @ObservationIgnored private static let deliveredKey = "deliveredSessionIDs"

    private var deliveredIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.deliveredKey) ?? [])
    }

    private func markDelivered(_ id: UUID) {
        var ids = deliveredIDs
        guard ids.insert(id.uuidString).inserted else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.deliveredKey)
    }

    /// Persisted set of voice-note file names whose transfer the phone has
    /// **confirmed**. Same watch-only UserDefaults pattern as `deliveredKey`; only
    /// grows, and only on genuine delivery (`onAudioFileDelivered`) — so retention
    /// never mistakes an unsent clip for a delivered one.
    @ObservationIgnored private static let deliveredAudioKey = "deliveredAudioFileNames"

    private var deliveredAudioFileNames: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.deliveredAudioKey) ?? [])
    }

    private func markAudioDelivered(_ fileName: String) {
        var names = deliveredAudioFileNames
        guard names.insert(fileName).inserted else { return }
        UserDefaults.standard.set(Array(names), forKey: Self.deliveredAudioKey)
    }

    /// Trims the persisted delivered-audio set to the file names still referenced
    /// by a surviving record's markers (mirror of `trimDeliveredIDs`): a name with
    /// no referencing marker was pruned or deleted and can't be needed again. Only
    /// removes names, never adds; no write unless the set actually shrinks.
    private func trimDeliveredAudio(keeping: Set<String>) {
        let names = deliveredAudioFileNames
        let trimmed = names.intersection(keeping)
        guard trimmed.count != names.count else { return }
        UserDefaults.standard.set(Array(trimmed), forKey: Self.deliveredAudioKey)
    }

    /// Trims the persisted delivered set to `keeping` (the ids of records still on
    /// this watch), so it stops growing unbounded. An id with no surviving record
    /// was pruned or manually deleted and can never be needed again — if the
    /// session is ever re-sent and re-confirmed, `markDelivered` re-adds it (and a
    /// re-send needs the record to exist). Preserves the "only grows on genuine
    /// delivery" invariant: this only removes ids, never adds. No write unless the
    /// set actually shrinks.
    private func trimDeliveredIDs(keeping: Set<String>) {
        let ids = deliveredIDs
        let trimmed = ids.intersection(keeping)
        guard trimmed.count != ids.count else { return }
        UserDefaults.standard.set(Array(trimmed), forKey: Self.deliveredKey)
    }

    /// Auto-clean entry point: prunes synced sessions per the diver's caps (a no-op
    /// unless retention is on), then trims the delivered-id set to what's still
    /// stored. The trim runs unconditionally — even with retention off — so the set
    /// can't grow unbounded, and it uses the *post-prune* record set so ids for the
    /// records just pruned (delivered by definition) are dropped in the same pass.
    func pruneForRetention() {
        // A failed prune-save must also skip the trim: the fetch below would see
        // the pending (unpersisted) deletions, and trimming against that view
        // drops delivered ids for records that survive on disk — leaving them
        // "undelivered" and unprunable forever.
        guard pruneSyncedSessions() else { return }
        // A failed fetch must skip the trim too — treating it as "no records"
        // would wipe the whole delivered set (safe, but needless bookkeeping loss).
        guard let records = try? modelContext.fetch(FetchDescriptor<SessionRecord>()) else { return }
        let surviving = records.filter { $0.modelContext != nil }
        let existing = Set(surviving.map { $0.id.uuidString })
        trimDeliveredIDs(keeping: existing)
        // Trim the delivered-audio set to clips still referenced by a surviving
        // record's markers — same failure-safe path as the id trim above.
        let audioNames = Set(surviving.flatMap { ($0.markers ?? []).compactMap(\.audioFileName) })
        trimDeliveredAudio(keeping: audioNames)
    }

    /// Removes old sessions from **this watch** — only ones confirmed delivered to
    /// the phone, honoring the diver's retention caps. The phone / iCloud keep the
    /// copy; this frees watch storage, it does NOT delete the session everywhere
    /// (so no `sendDeletion`). No-op unless retention is on.
    ///
    /// Returns `false` only when the deletions could not be persisted (the store
    /// then still holds them), so the caller knows a fresh fetch won't reflect
    /// disk. Skipped/no-op passes return `true`.
    private func pruneSyncedSessions() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "retentionEnabled") else { return true }
        let policy = RetentionPolicy(
            maxDays: defaults.integer(forKey: "retentionMaxDays"),
            maxSessions: defaults.integer(forKey: "retentionMaxSessions"),
            maxSizeBytes: defaults.integer(forKey: "retentionMaxMegabytes") * 1_048_576
        )
        guard policy.isActive else { return true }
        let records = (try? modelContext.fetch(FetchDescriptor<SessionRecord>())) ?? []
        let delivered = deliveredIDs
        let deliveredAudio = deliveredAudioFileNames
        // A session is prunable only once it's confirmed on the phone: its own
        // payload delivered AND every voice-note clip it references confirmed
        // delivered too. Waiting on confirmation (not "in flight") covers the two
        // unsound cases the old guard missed — a pre-activation read that sees no
        // outstanding transfers, and a failed transfer that leaves the queue with
        // no retry — either of which would let us delete a clip's only copy.
        // Sessions without audio only need their own delivery. Undelivered sessions
        // are never pruned, but still count toward the size/count budgets.
        let candidates = records.compactMap { record -> RetentionCandidate? in
            guard record.modelContext != nil else { return nil }
            let fileNames = (record.markers ?? []).compactMap(\.audioFileName)
            let audioDelivered = fileNames.allSatisfy { deliveredAudio.contains($0) }
            return RetentionCandidate(
                id: record.id,
                startTime: record.startTime,
                sizeBytes: estimatedSize(record),
                isDelivered: delivered.contains(record.id.uuidString) && audioDelivered
            )
        }
        let toPrune = Set(sessionsToPrune(candidates, policy: policy))
        guard !toPrune.isEmpty else { return true }
        for record in records where record.modelContext != nil && toPrune.contains(record.id) {
            // Free the voice-note files too, then drop only the local record —
            // no sync deletion, so the phone keeps its copy.
            deleteAudioFiles(of: record)
            modelContext.delete(record)
        }
        do {
            try modelContext.save()
            return true
        } catch {
            return false
        }
    }

    /// Stored session count + estimated watch footprint (bytes), for the Settings
    /// storage row. Approximate.
    func storageTotals() -> (count: Int, bytes: Int) {
        let records = ((try? modelContext.fetch(FetchDescriptor<SessionRecord>())) ?? [])
            .filter { $0.modelContext != nil }
        return (records.count, records.reduce(0) { $0 + estimatedSize($1) })
    }

    /// Rough on-watch footprint of a session: its voice-note files (exact) plus a
    /// duration-based estimate of the depth/HR/track series (~56 B/s). Approximate —
    /// only used for the retention size cap and the storage total.
    private func estimatedSize(_ record: SessionRecord) -> Int {
        let duration = (record.endTime ?? record.startTime).timeIntervalSince(record.startTime)
        var bytes = Int(max(0, duration) * 56)
        for fileName in (record.markers ?? []).compactMap(\.audioFileName) {
            let path = AudioNoteRecorder.url(for: fileName).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int {
                bytes += size
            }
        }
        return bytes
    }
}
