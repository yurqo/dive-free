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

    /// Number of finalized dives in the current session.
    public var diveCount: Int { dives.count }

    /// Running maximum depth observed during the current session (0 when idle).
    public private(set) var maxDepthMeters: Double = 0

    private let sensors: SensorManager
    private let detector: DiveDetector
    private let modelContext: ModelContext

    public init(
        sensors: SensorManager = SensorManager(),
        detector: DiveDetector = DiveDetector(),
        modelContext: ModelContext
    ) {
        self.sensors = sensors
        self.detector = detector
        self.modelContext = modelContext
    }

    /// Starts the depth sensor and marks the session as active.
    public func startSession() async throws {
        guard !isActive else { return }
        dives = []
        maxDepthMeters = 0
        sensors.onSamplesChanged = { [weak self] in self?.refreshDetection() }
        try await sensors.start()
        startTime = Date()
        isActive = true
    }

    /// Re-runs dive detection over all accumulated samples and updates the
    /// running depth maximum. Called on every ingested sample via `onSamplesChanged`.
    private func refreshDetection() {
        dives = detector.detectDives(from: sensors.samples)
        maxDepthMeters = max(maxDepthMeters, sensors.currentDepthMeters)
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
        let session = DiveSession(startTime: start, endTime: Date(), dives: finalDives)
        let record = SessionRecord(from: session)
        modelContext.insert(record)
        try modelContext.save()
        isActive = false
        startTime = nil
        dives = []
        maxDepthMeters = 0
        return session
    }
}
