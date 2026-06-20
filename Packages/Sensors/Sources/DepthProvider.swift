import Foundation
import Domain

/// Source of live depth readings. Implementations may wrap real hardware
/// (Apple Watch Ultra water-submersion sensor) or synthesize data for previews/tests.
public protocol DepthProvider: Sendable {
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
        profile: [Double] = [0, 1, 3, 6, 9, 11, 9, 6, 3, 1, 0, 0]
    ) {
        self.interval = interval
        self.profile = profile
    }

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
