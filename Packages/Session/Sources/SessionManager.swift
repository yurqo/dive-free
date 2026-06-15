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

    /// Markers placed during the dive currently in progress (0 when surfaced/idle).
    public var currentDiveMarkerCount: Int {
        guard let start = currentDiveStart else { return 0 }
        return markers.filter { $0.timestamp >= start }.count
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

    private let sensors: SensorManager
    private let detector: DiveDetector
    private let modelContext: ModelContext
    private var hapticTracker: DiveHapticTracker

    private let location: LocationProviding
    /// Surface GPS fix captured for the current session, if any (the first fix).
    private var capturedLocation: GeoPoint?
    /// When the most recent GPS fix arrived (regardless of track throttling), or
    /// `nil` if none yet this session. Drives the live "GPS acquired?" indicator —
    /// a fix going stale means the watch lost signal (e.g. wrist underwater).
    public private(set) var lastLocationFixAt: Date?
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
            config: DiveHapticConfig(surfaceThresholdMeters: detector.config.surfaceThresholdMeters)
        )
    }

    /// Starts the depth sensor and marks the session as active.
    public func startSession() async throws {
        guard !isActive else { return }
        dives = []
        markers = []
        maxDepthMeters = 0
        currentDiveMaxDepth = 0
        currentDiveStart = nil
        lastSurfacedAt = nil
        capturedLocation = nil
        lastLocationFixAt = nil
        track = []
        hapticTracker = DiveHapticTracker(
            config: DiveHapticConfig(surfaceThresholdMeters: detector.config.surfaceThresholdMeters)
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
        if capturedLocation == nil { capturedLocation = point }
        if let last = track.last, now.timeIntervalSince(last.timestamp) < Self.minTrackInterval { return }
        track.append(TrackPoint(timestamp: now, location: point))
    }

    /// Re-runs dive detection over all accumulated samples, updates the
    /// running depth maximum, and fires haptic events for depth transitions.
    /// Called on every ingested sample via `onSamplesChanged`.
    private func refreshDetection() {
        dives = detector.detectDives(from: sensors.samples)
        let depth = sensors.currentDepthMeters
        maxDepthMeters = max(maxDepthMeters, depth)
        // Edge-track the in-progress dive: start the clock on the way down,
        // clear it on return to the surface. The surface interval is the mirror
        // image — it starts when a counted dive ends and resets on the next
        // descent.
        if depth > detector.config.surfaceThresholdMeters {
            if currentDiveStart == nil { currentDiveStart = Date(); currentDiveMaxDepth = 0 }
            currentDiveMaxDepth = max(currentDiveMaxDepth, depth)
            lastSurfacedAt = nil
        } else {
            // Surfacing from a dive that actually counted starts the recovery
            // clock; a brief dip that never qualified leaves it untouched.
            if currentDiveStart != nil, !dives.isEmpty { lastSurfacedAt = Date() }
            currentDiveStart = nil
            currentDiveMaxDepth = 0
        }
        let events = hapticTracker.update(depthMeters: depth)
        for event in events { onHapticEvent?(event) }
    }

    /// Stops sensing, runs a final dive detection pass, persists the session,
    /// and returns the completed `DiveSession` domain value (nil if no session
    /// was active).
    @discardableResult
    public func stopSession() throws -> DiveSession? {
        guard isActive, let start = startTime else { return nil }
        sensors.onSamplesChanged = nil
        sensors.stop()
        locationTask?.cancel()
        locationTask = nil
        let finalDives = detector.detectDives(from: sensors.samples)
        let session = DiveSession(
            startTime: start,
            endTime: Date(),
            dives: finalDives,
            markers: markers,
            location: capturedLocation,
            track: track
        )
        let record = SessionRecord(from: session)
        modelContext.insert(record)
        try modelContext.save()
        isActive = false
        startTime = nil
        dives = []
        markers = []
        maxDepthMeters = 0
        currentDiveMaxDepth = 0
        currentDiveStart = nil
        lastSurfacedAt = nil
        track = []
        lastLocationFixAt = nil
        return session
    }
}
