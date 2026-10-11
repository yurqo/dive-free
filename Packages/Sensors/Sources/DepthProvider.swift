import Foundation
import Domain

/// A water-state transition delivered independently of a recording session.
/// The Watch app uses this to begin recording when the system launches it
/// underwater; ordinary depth samples remain session-scoped.
public struct SubmersionStateChange: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case unknown
        case notSubmerged
        case submerged
    }

    public let state: State
    public let timestamp: Date

    public init(state: State, timestamp: Date) {
        self.state = state
        self.timestamp = timestamp
    }
}

/// Source of live depth readings. Implementations may wrap real hardware
/// (Apple Watch Ultra water-submersion sensor) or synthesize data for previews/tests.
public protocol DepthProvider: Sendable {
    /// Register for water-state changes. Providers without a water sensor may
    /// ignore this; the real Watch provider reports its current state immediately.
    func setSubmersionStateChangeHandler(_ handler: (@Sendable (SubmersionStateChange) -> Void)?)
    /// Begin producing samples. Throws if the sensor is unavailable or permission is denied.
    func start() async throws
    /// Stop producing samples and release the sensor.
    func stop()
    /// An async stream of depth samples produced while started.
    func depthStream() -> AsyncStream<DepthSample>
    /// An async stream of water-temperature samples. Empty by default; only the
    /// real Ultra provider and the mock emit them.
    func temperatureStream() -> AsyncStream<TemperatureSample>
}

public extension DepthProvider {
    func setSubmersionStateChangeHandler(_ handler: (@Sendable (SubmersionStateChange) -> Void)?) {}

    func temperatureStream() -> AsyncStream<TemperatureSample> {
        AsyncStream { $0.finish() }
    }
}

/// Produces no depth at all — for a real watch without the water-submersion
/// sensor (Apple Watch Series 9 and earlier, SE). The session still runs for
/// GPS + markers; it just records no depth or dives. Distinct from
/// `MockDepthProvider`, which fabricates a dive profile for previews/simulator.
public struct UnavailableDepthProvider: DepthProvider {
    public init() {}
    public func start() async throws {}
    public func stop() {}
    public func depthStream() -> AsyncStream<DepthSample> {
        AsyncStream { $0.finish() }
    }
}

/// Emits a deterministic synthetic dive profile. Used in SwiftUI previews and unit tests,
/// and on the iOS simulator where the water-submersion sensor is not available.
public struct MockDepthProvider: DepthProvider {
    /// Seconds between emitted samples.
    public var interval: Double
    /// One full descent/ascent profile (meters), looped.
    public var profile: [Double]

    public init(
        interval: Double = 0.5,
        profile: [Double] = MockDepthProvider.defaultProfile
    ) {
        self.interval = interval
        self.profile = profile
    }

    /// A smooth 0 → 9 m → 0 descent/ascent at 0.25 m per sample — 0.5 m/s at the
    /// default 0.5 s interval — crossing every metre milestone, then clamped to the
    /// 6 m ceiling (like the real sensor's pastMaxDepth) so the dive dwells at 6 m
    /// and the simulator exercises the per-metre and ceiling cues.
    public static let defaultProfile: [Double] = {
        let step = 0.25, peak = 9.0
        let down = Array(stride(from: 0.0, through: peak, by: step))
        let up = Array(stride(from: peak - step, through: 0.0, by: -step))
        let dive = (down + up).map { min($0, DepthFormat.maxMeasurableMeters) }
        // ~100 s surface break (200 × 0.5 s) so the recovery timer runs through
        // all of its colours before the next dive.
        return dive + Array(repeating: 0.0, count: 200)
    }()

    public func start() async throws {}
    public func stop() {}

    public func depthStream() -> AsyncStream<DepthSample> {
        let interval = interval
        let profile = profile
        return AsyncStream { continuation in
            let task = Task {
                var index = 0
                while !Task.isCancelled {
                    let depth = profile[index % profile.count]
                    continuation.yield(DepthSample(timestamp: Date(), depthMeters: depth))
                    index += 1
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func temperatureStream() -> AsyncStream<TemperatureSample> {
        let interval = interval
        return AsyncStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    // Gentle synthetic ~18–22 °C profile for previews/simulator.
                    continuation.yield(TemperatureSample(timestamp: Date(), celsius: 20 + 2 * sin(Double(tick) / 8)))
                    tick += 1
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
