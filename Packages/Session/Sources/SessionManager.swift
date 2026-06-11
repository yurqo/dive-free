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

    /// Running maximum depth observed during the current session (0 when idle).
    public private(set) var maxDepthMeters: Double = 0

    /// Start of the dive currently in progress, set on the surface-crossing
    /// going down and cleared on return to the surface. `nil` when at the
    /// surface or idle.
    public private(set) var currentDiveStart: Date?

    /// Elapsed time of the dive in progress, or `nil` when at the surface/idle.
    public var currentDiveElapsed: TimeInterval? {
        currentDiveStart.map { Date().timeIntervalSince($0) }
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

    public init(
        sensors: SensorManager = SensorManager(),
        detector: DiveDetector = DiveDetector(),
        modelContext: ModelContext
    ) {
        self.sensors = sensors
        self.detector = detector
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
        currentDiveStart = nil
        hapticTracker = DiveHapticTracker(
            config: DiveHapticConfig(surfaceThresholdMeters: detector.config.surfaceThresholdMeters)
        )
        sensors.onSamplesChanged = { [weak self] in self?.refreshDetection() }
        try await sensors.start()
        startTime = Date()
        isActive = true
    }

    /// Re-runs dive detection over all accumulated samples, updates the
    /// running depth maximum, and fires haptic events for depth transitions.
    /// Called on every ingested sample via `onSamplesChanged`.
    private func refreshDetection() {
        dives = detector.detectDives(from: sensors.samples)
        let depth = sensors.currentDepthMeters
        maxDepthMeters = max(maxDepthMeters, depth)
        // Edge-track the in-progress dive: start the clock on the way down,
        // clear it on return to the surface.
        if depth > detector.config.surfaceThresholdMeters {
            if currentDiveStart == nil { currentDiveStart = Date() }
        } else {
            currentDiveStart = nil
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
        let finalDives = detector.detectDives(from: sensors.samples)
        let session = DiveSession(startTime: start, endTime: Date(), dives: finalDives, markers: markers)
        let record = SessionRecord(from: session)
        modelContext.insert(record)
        try modelContext.save()
        isActive = false
        startTime = nil
        dives = []
        markers = []
        maxDepthMeters = 0
        currentDiveStart = nil
        return session
    }
}
