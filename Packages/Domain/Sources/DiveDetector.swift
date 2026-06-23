import Foundation

/// Tunable thresholds for turning a stream of depth samples into discrete dives.
public struct DiveDetectionConfig: Sendable, Equatable {
    /// Depth (m) below which the diver is considered underwater rather than at the surface.
    public var surfaceThresholdMeters: Double
    /// A candidate dive is only kept if it reaches at least this depth (m).
    public var minimumDiveDepthMeters: Double
    /// A candidate dive is only kept if it lasts at least this long.
    public var minimumDiveDuration: TimeInterval

    public init(
        surfaceThresholdMeters: Double = 1.0,
        minimumDiveDepthMeters: Double = 1.5,
        minimumDiveDuration: TimeInterval = 3
    ) {
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.minimumDiveDepthMeters = minimumDiveDepthMeters
        self.minimumDiveDuration = minimumDiveDuration
    }

    public static let `default` = DiveDetectionConfig()
}

/// Splits a continuous depth track into individual dives using a simple
/// surface-crossing state machine. Pure and deterministic, so it is fully unit-testable.
public struct DiveDetector: Sendable {
    public var config: DiveDetectionConfig

    public init(config: DiveDetectionConfig = .default) {
        self.config = config
    }

    /// Detects dives from an unordered set of depth samples.
    public func detectDives(from samples: [DepthSample]) -> [Dive] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var dives: [Dive] = []
        var current: [DepthSample] = []

        func finalizeCurrent() {
            defer { current = [] }
            guard let first = current.first, let last = current.last else { return }
            let maxDepth = current.map(\.depthMeters).max() ?? 0
            let duration = last.timestamp.timeIntervalSince(first.timestamp)
            // Ignore an instantaneous spike (a single sample / zero time span): a
            // real dive always covers more than one reading, so a lone noisy deep
            // sample shouldn't register as a zero-duration dive (it would otherwise
            // pass the depth-and-duration gate below when minimumDiveDuration is 0).
            guard duration > 0 else { return }
            // A dive must reach the minimum depth (going under is what defines a
            // dive) AND last the minimum duration. The depth gate rejects long
            // shallow bobs (wrist under at the surface); the duration gate rejects
            // brief noise spikes.
            guard maxDepth >= config.minimumDiveDepthMeters
                && duration >= config.minimumDiveDuration else { return }
            dives.append(
                Dive(
                    startTime: first.timestamp,
                    endTime: last.timestamp,
                    maxDepthMeters: maxDepth,
                    samples: current
                )
            )
        }

        for sample in ordered {
            if sample.depthMeters > config.surfaceThresholdMeters {
                current.append(sample)
            } else if !current.isEmpty {
                finalizeCurrent()
            }
        }
        finalizeCurrent()
        return dives
    }
}
