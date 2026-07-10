import Foundation
import Observation
import SwiftData
import Domain
import Sensors
import Persistence

/// Drives the sensor capture loop for one in-water session, accumulates
/// `DepthSample`s, detects dives, and persists the finished `DiveSession`
/// to SwiftData.
///
/// Intended as the single source of session truth on the Watch. Kept free of
/// HealthKit / WatchConnectivity so it is fully testable on an iOS target.
@MainActor
@Observable
public final class SessionManager {
    public private(set) var isActive = false
    public private(set) var startTime: Date?

    /// Live depth forwarded from the sensor layer.
    public var currentDepthMeters: Double { sensors.currentDepthMeters }

    /// Live water temperature (°C) from the submersion sensor, or `nil`.
    public var currentTemperatureCelsius: Double? { sensors.currentTemperatureCelsius }

    /// Heart-rate readings recorded this session. Fed from the live workout via
    /// the app layer (HealthKit lives outside this package), not the sensor stream.
    public private(set) var heartRateSamples: [HeartRateSample] = []
    private var lastHeartRateSampleAt: Date?
    /// Minimum spacing between stored HR samples, to bound the series on long
    /// sessions (the live readout updates every callback regardless).
    private static let minHeartRateSampleInterval: TimeInterval = 2

    /// Records a heart-rate reading (bpm), throttled. No-op when idle.
    public func recordHeartRate(_ bpm: Double) {
        guard isActive else { return }
        let now = Date()
        if let last = lastHeartRateSampleAt,
           now.timeIntervalSince(last) < Self.minHeartRateSampleInterval { return }
        lastHeartRateSampleAt = now
        heartRateSamples.append(HeartRateSample(timestamp: now, bpm: bpm))
    }

    /// Seconds elapsed since the session started (0 when idle).
    public var elapsedTime: TimeInterval {
        guard let startTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    /// Finalized dives detected so far in the current session (live, updated per sample).
    public private(set) var dives: [Dive] = []

    /// Event markers placed by the user during the current session.
    public private(set) var markers: [EventMarker] = []

    /// Number of finalized dives in the current session.
    public var diveCount: Int { dives.count }

    /// Appends a timestamped marker to the current session. No-op when idle.
    public func addMarker(kind: EventKind, text: String? = nil) {
        guard isActive else { return }
        markers.append(EventMarker(timestamp: Date(), kind: kind, text: text))
    }

    /// Appends a marker of any kind (built-in or custom). No-op when idle.
    public func addMarker(kind: MarkerKind, text: String? = nil) {
        guard isActive else { return }
        markers.append(EventMarker(timestamp: Date(), kind: kind, text: text))
    }

    /// Running maximum depth observed during the current session (0 when idle).
    public private(set) var maxDepthMeters: Double = 0

    /// Maximum depth reached during the dive currently in progress (0 when at the
    /// surface/idle). Reset each time a new descent begins.
    public private(set) var currentDiveMaxDepth: Double = 0

    /// Total surface distance traveled so far this session (meters), from the track.
    public var surfaceDistanceMeters: Double { track.surfaceDistanceMeters }

    /// Start of the dive currently in progress, set on the surface-crossing
    /// going down and cleared on return to the surface. `nil` when at the
    /// surface or idle.
    public private(set) var currentDiveStart: Date?

    /// Elapsed time of the dive in progress, or `nil` when at the surface/idle.
    public var currentDiveElapsed: TimeInterval? {
        currentDiveStart.map { Date().timeIntervalSince($0) }
    }

    /// Whether the dive in progress has met one of the detector's acceptance tiers
    /// (so it will be logged). A manual dive counts immediately. `false` at the
    /// surface, and during the provisional descent before any tier is satisfied —
    /// which is when the live UI shows the "dive in N s" countdown instead of a
    /// confirmed dive.
    public var currentDiveConfirmed: Bool {
        if isManualDiveActive { return true }
        guard let start = currentDiveStart else { return false }
        // Mirror the detector's finalize-at-crossing rule: once the diver is in the
        // shallow band, the dive can only end backdated to that crossing, so the
        // elapsed time must freeze there instead of accruing wall-clock time during
        // a shallow hang the detector will trim — otherwise the UI could lock in a
        // dive that is never logged. `shallowSince` is that crossing while shallow,
        // else `Date()`. (A ≤1-sample residual vs the detector's exact deep-span
        // cutoff is acceptable.)
        let effectiveNow = shallowSince ?? Date()
        let elapsed = effectiveNow.timeIntervalSince(start)
        return detector.config.thresholds.contains {
            currentDiveMaxDepth >= $0.minimumDepthMeters && elapsed >= $0.minimumDuration
        }
    }

    /// Seconds until the dive in progress locks in at the current depth, or `nil`
    /// at the surface / once confirmed / when no tier is within reach yet. Uses the
    /// depth reached so far, so it shortens as the diver descends (deeper tiers
    /// need less time). Drives the live countdown.
    public var secondsToDiveConfirmation: TimeInterval? {
        guard let start = currentDiveStart, !isManualDiveActive else { return nil }
        // Freeze the elapsed at the shallow-band crossing (see currentDiveConfirmed):
        // during a shallow hang the detector ends the dive backdated to the crossing,
        // so the countdown must stop there rather than run to zero on a hang that
        // won't be logged. `shallowSince` is that crossing while shallow, else now.
        let effectiveNow = shallowSince ?? Date()
        let elapsed = effectiveNow.timeIntervalSince(start)
        let soonest = detector.config.thresholds
            .filter { currentDiveMaxDepth >= $0.minimumDepthMeters }
            .map { $0.minimumDuration - elapsed }
            .min()
        guard let soonest, soonest > 0 else { return nil }
        return soonest
    }

    /// Markers placed during the dive currently in progress (0 when surfaced/idle).
    public var currentDiveMarkerCount: Int {
        guard let start = currentDiveStart else { return 0 }
        return markers.filter { $0.timestamp >= start }.count
    }

    /// Completed manual dive segments (Action + side). They define dives directly
    /// and pre-empt overlapping auto-detection.
    @ObservationIgnored private var manualSegments: [DateInterval] = []
    /// Start of an in-progress manual dive, or `nil`.
    @ObservationIgnored private var manualDiveStart: Date?
    /// After a manual stop while still deep, don't let auto-detection immediately
    /// re-open a dive — wait until the diver is back at the surface.
    @ObservationIgnored private var suppressAutoUntilSurface = false
    /// While a dive is in progress and depth has risen into the shallow band
    /// (above the surface, below the threshold), the wall-clock time it first
    /// crossed the threshold — the start of the surface-exit dwell. `nil` while
    /// deep or surfaced. Mirrors the detector: a shallow spell shorter than
    /// `surfaceExitDwellSeconds` folds back into the dive; longer ends it, backdated
    /// to this crossing.
    @ObservationIgnored private var shallowSince: Date?

    /// Whether a manual dive (Action + side) is currently in progress.
    public var isManualDiveActive: Bool { manualDiveStart != nil }

    /// Begins a manual dive immediately — even at the surface, before depth crosses
    /// the threshold. Suspends auto-detection for this segment; the live UI shows
    /// "submerged" right away.
    public func startManualDive() {
        guard isActive, manualDiveStart == nil else { return }
        let now = Date()
        manualDiveStart = now
        suppressAutoUntilSurface = false
        shallowSince = nil
        currentDiveStart = now
        currentDiveMaxDepth = sensors.currentDepthMeters
        lastSurfacedAt = nil
        onSubmerge?()
    }

    /// Ends the in-progress manual dive immediately — even before surfacing.
    /// Records the segment, recounts dives, and starts the surface-interval clock;
    /// auto re-detection stays suspended until the diver is actually back up.
    public func stopManualDive() {
        guard isActive, let start = manualDiveStart else { return }
        let now = Date()
        if now > start { manualSegments.append(DateInterval(start: start, end: now)) }
        manualDiveStart = nil
        currentDiveStart = nil
        currentDiveMaxDepth = 0
        dives = detector.detectDives(from: sensors.samples, manualSegments: manualSegments)
        lastSurfacedAt = dives.isEmpty ? nil : now
        // Arm suppression whenever the diver hasn't truly surfaced (0 m) — including a
        // stop in the shallow band (0.05–1 m). The detector's pre-emption extends to
        // the first genuine surface exit, so if the live layer left auto unsuppressed
        // here it would open+confirm a re-descent dive the final pass then drops
        // (live/final mismatch). The shallow-branch dwell in `refreshDetection` clears
        // this once the diver actually surfaces.
        suppressAutoUntilSurface = sensors.currentDepthMeters > DiveDetectionConfig.surfaceExitDepthMeters
        onSurface?()
    }

    /// When the diver last returned to the surface after a completed dive. Set
    /// on the surface-crossing going up and cleared on the next descent (and
    /// while idle / before the first dive). `nil` whenever there is no surface
    /// interval to show.
    public private(set) var lastSurfacedAt: Date?

    /// Seconds spent at the surface since the last dive ended, or `nil` when
    /// submerged or before the first completed dive. Counts up between dives to
    /// help the diver pace recovery, and resets when the next descent begins.
    public var surfaceInterval: TimeInterval? {
        guard currentDiveStart == nil, let lastSurfacedAt else { return nil }
        return Date().timeIntervalSince(lastSurfacedAt)
    }

    /// Called on `@MainActor` each time a haptic event fires. Install this from
    /// the app layer (`SessionCoordinator`) to play haptics without importing
    /// WatchKit into a testable package.
    @ObservationIgnored
    public var onHapticEvent: (@MainActor (DiveHapticEvent) -> Void)?

    /// Called when the diver crosses from the surface into a dive (the moment a
    /// new descent begins). Used to auto-stop a surface voice-note recording.
    @ObservationIgnored
    public var onSubmerge: (@MainActor () -> Void)?

    /// Called when the diver returns to the surface (the dive in progress ends).
    /// Mirrors `onSubmerge`; used to restore the surface action menu.
    @ObservationIgnored
    public var onSurface: (@MainActor () -> Void)?

    /// Attaches a recorded voice-note filename to the most recently placed
    /// marker, or — if none has been placed yet this session — drops a `.note`
    /// marker to carry it. No-op when idle.
    public func attachAudioToLastMarker(_ fileName: String) {
        guard isActive else { return }
        if markers.isEmpty {
            markers.append(EventMarker(timestamp: Date(), kind: MarkerKind(.note), audioFileName: fileName))
        } else {
            markers[markers.count - 1].audioFileName = fileName
        }
    }

    /// Attaches a voice-note filename to the marker with the given id, replacing
    /// any existing clip. No-op if the marker no longer exists or the session is
    /// idle. Lets a stitched clip land on the marker it was recorded for even if
    /// other markers were placed while the (async) merge ran.
    public func attachAudio(_ fileName: String, toMarkerWithID id: UUID) {
        guard isActive, let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].audioFileName = fileName
    }

    private let sensors: SensorManager
    /// `var` so the app layer can swap in a diver-tuned config (synced from the
    /// phone) via `setDetectionConfig(_:)` before the next `startSession()`.
    private var detector: DiveDetector
    private let modelContext: ModelContext
    private var hapticTracker: DiveHapticTracker
    /// Detection config to adopt at the next `startSession()`. Held pending (rather
    /// than applied to `detector` immediately) so a config synced from the phone
    /// mid-session only takes effect from the following session — the same
    /// next-session convention as the GPS-precision / target settings.
    @ObservationIgnored private var pendingDetectionConfig: DiveDetectionConfig?

    private let location: LocationProviding
    /// Surface GPS fix captured for the current session, if any (the first fix).
    private var capturedLocation: GeoPoint?
    /// When the most recent GPS fix arrived (regardless of track throttling), or
    /// `nil` if none yet this session. Drives the live "GPS acquired?" indicator —
    /// a fix going stale means the watch lost signal (e.g. wrist underwater).
    public private(set) var lastLocationFixAt: Date?
    /// Horizontal accuracy (meters) of the most recent GPS fix, or `nil` if none
    /// yet / unknown. Drives the live "±N m" GPS-quality readout.
    public private(set) var lastLocationAccuracy: Double?
    /// Ordered surface fixes captured during the session — the surface path.
    private var track: [TrackPoint] = []
    private var locationTask: Task<Void, Never>?
    /// Minimum spacing between recorded track points, to bound the track size.
    private static let minTrackInterval: TimeInterval = 2

    public init(
        sensors: SensorManager = SensorManager(),
        detector: DiveDetector = DiveDetector(),
        location: LocationProviding = CoreLocationProvider(),
        modelContext: ModelContext
    ) {
        self.sensors = sensors
        self.detector = detector
        self.location = location
        self.modelContext = modelContext
        self.hapticTracker = DiveHapticTracker(
            config: DiveHapticConfig(surfaceThresholdMeters: detector.config.surfaceThresholdMeters, surfaceExitDwellSeconds: detector.config.surfaceExitDwellSeconds, milestoneIntervalMeters: 1.0)
        )
    }

    /// Sets the dive-detection config to use from the next `startSession()`. Does
    /// not affect a session already in progress (see `pendingDetectionConfig`).
    public func setDetectionConfig(_ config: DiveDetectionConfig) {
        pendingDetectionConfig = config
    }

    /// Starts the depth sensor and marks the session as active.
    public func startSession() async throws {
        guard !isActive else { return }
        // Adopt any config synced since the last session (haptics + acceptance both
        // read `detector.config`, rebuilt just below).
        if let pendingDetectionConfig { detector.config = pendingDetectionConfig }
        dives = []
        markers = []
        heartRateSamples = []
        lastHeartRateSampleAt = nil
        maxDepthMeters = 0
        currentDiveMaxDepth = 0
        currentDiveStart = nil
        lastSurfacedAt = nil
        manualSegments = []
        manualDiveStart = nil
        suppressAutoUntilSurface = false
        shallowSince = nil
        capturedLocation = nil
        lastLocationFixAt = nil
        lastLocationAccuracy = nil
        track = []
        hapticTracker = DiveHapticTracker(
            config: DiveHapticConfig(surfaceThresholdMeters: detector.config.surfaceThresholdMeters, surfaceExitDwellSeconds: detector.config.surfaceExitDwellSeconds, milestoneIntervalMeters: 1.0)
        )
        // Stream surface GPS fixes in the background to build the track — don't
        // block the session start on it (it just stays empty if denied/
        // unavailable). The first fix also tags the session location.
        locationTask = Task { [weak self] in
            guard let stream = self?.location.locationUpdates() else { return }
            for await point in stream {
                if Task.isCancelled { break }
                self?.handleLocationFix(point)
            }
        }
        sensors.onSamplesChanged = { [weak self] in self?.refreshDetection() }
        try await sensors.start()
        startTime = Date()
        isActive = true
    }

    /// Handles a surface GPS fix: timestamps it for the live indicator, tags the
    /// session location with the first fix, and appends to the track (throttled
    /// to one per `minTrackInterval` to bound the array).
    private func handleLocationFix(_ point: GeoPoint) {
        let now = Date()
        lastLocationFixAt = now
        lastLocationAccuracy = point.horizontalAccuracy
        if capturedLocation == nil { capturedLocation = point }
        if let last = track.last, now.timeIntervalSince(last.timestamp) < Self.minTrackInterval { return }
        track.append(TrackPoint(timestamp: now, location: point))
    }

    /// Re-runs dive detection over all accumulated samples, updates the
    /// running depth maximum, and fires haptic events for depth transitions.
    /// Called on every ingested sample via `onSamplesChanged`.
    private func refreshDetection() {
        dives = detector.detectDives(from: sensors.samples, manualSegments: manualSegments)
        let depth = sensors.currentDepthMeters
        maxDepthMeters = max(maxDepthMeters, depth)
        let threshold = detector.config.surfaceThresholdMeters

        // Manual (Action + side) owns the in-progress dive when active; otherwise
        // edge-track it from depth — but don't auto-reopen a dive that was just
        // ended manually until the diver is back at the surface.
        if isManualDiveActive {
            currentDiveMaxDepth = max(currentDiveMaxDepth, depth)
            lastSurfacedAt = nil
        } else if depth > threshold {
            // Deep: (re)open or continue the dive; a shallow bounce folds back in.
            // Going deep also cancels any surface-exit dwell — whether it was timing
            // out a dive OR the post-manual-stop suppression through a bounce.
            shallowSince = nil
            if !suppressAutoUntilSurface, currentDiveStart == nil {
                currentDiveStart = Date()
                currentDiveMaxDepth = 0
                onSubmerge?()
            }
            if currentDiveStart != nil {
                currentDiveMaxDepth = max(currentDiveMaxDepth, depth)
                lastSurfacedAt = nil
            }
        } else if depth <= DiveDetectionConfig.surfaceExitDepthMeters {
            // Explicit 0 m — genuinely surfaced. Clear the post-manual suppression and
            // end any dive in progress (the ascent through the shallow band counted).
            suppressAutoUntilSurface = false
            shallowSince = nil
            if currentDiveStart != nil { endCurrentDive(surfacedAt: Date()) }
        } else if currentDiveStart != nil || suppressAutoUntilSurface {
            // Shallow band (above the surface, below the threshold) with a dive open,
            // or auto-detection suppressed after a manual stop: time the dwell from the
            // crossing. A sub-dwell bounce holds BOTH the dive and the suppression; the
            // dwell elapsing is a genuine surface exit that clears them, ending any dive
            // backdated to the crossing. Suppression must NOT clear on a mere shallow
            // bounce — only on a true surface exit (0 m above, or the dwell here).
            let crossing = shallowSince ?? Date()
            shallowSince = crossing
            if Date().timeIntervalSince(crossing) >= detector.config.surfaceExitDwellSeconds {
                suppressAutoUntilSurface = false
                if currentDiveStart != nil { endCurrentDive(surfacedAt: crossing) }
                else { shallowSince = nil }
            }
        } else {
            shallowSince = nil
        }
        let events = hapticTracker.update(depthMeters: depth)
        for event in events { onHapticEvent?(event) }
    }

    /// Ends the auto-detected dive in progress: clears the live dive state and,
    /// if at least one dive has been logged this session (`!dives.isEmpty` — not
    /// necessarily the one just ended), starts the surface-recovery clock at
    /// `surfacedAt` (backdated to the threshold crossing on a dwell exit).
    private func endCurrentDive(surfacedAt: Date) {
        if !dives.isEmpty { lastSurfacedAt = surfacedAt }
        currentDiveStart = nil
        currentDiveMaxDepth = 0
        shallowSince = nil
        onSurface?()
    }

    /// Stops sensing, runs a final dive detection pass, persists the session,
    /// and returns the completed `DiveSession` domain value (nil if no session
    /// was active).
    @discardableResult
    public func stopSession(activeEnergyKilocalories: Double? = nil) throws -> DiveSession? {
        guard isActive, let start = startTime else { return nil }
        sensors.onSamplesChanged = nil
        sensors.stop()
        locationTask?.cancel()
        locationTask = nil
        // Close an in-progress manual dive at session end, then run final detection.
        var segments = manualSegments
        if let manualStart = manualDiveStart, Date() > manualStart {
            segments.append(DateInterval(start: manualStart, end: Date()))
        }
        let finalDives = detector.detectDives(from: sensors.samples, manualSegments: segments)
        let session = DiveSession(
            startTime: start,
            endTime: Date(),
            dives: finalDives,
            markers: markers,
            location: capturedLocation,
            track: track,
            heartRateSamples: heartRateSamples,
            temperatureSamples: sensors.temperatureSamples,
            activeEnergyKilocalories: activeEnergyKilocalories
        )
        let record = SessionRecord(from: session)
        modelContext.insert(record)
        try modelContext.save()
        isActive = false
        startTime = nil
        dives = []
        markers = []
        heartRateSamples = []
        lastHeartRateSampleAt = nil
        maxDepthMeters = 0
        currentDiveMaxDepth = 0
        currentDiveStart = nil
        lastSurfacedAt = nil
        manualSegments = []
        manualDiveStart = nil
        suppressAutoUntilSurface = false
        shallowSince = nil
        track = []
        lastLocationFixAt = nil
        lastLocationAccuracy = nil
        return session
    }
}
