import Foundation

/// Tunable thresholds for turning a stream of depth samples into discrete dives.
public struct DiveDetectionConfig: Sendable, Equatable {
    /// One acceptance rule: a candidate counts as a dive if it reaches
    /// `minimumDepthMeters` AND lasts at least `minimumDuration`. Rules are OR-ed,
    /// so the deeper you go the sooner it counts (a quick duck dive), while a
    /// shallow dive must be sustained (which is what rejects brief surface bobbing).
    public struct DiveThreshold: Sendable, Equatable {
        public var minimumDepthMeters: Double
        public var minimumDuration: TimeInterval
        public init(minimumDepthMeters: Double, minimumDuration: TimeInterval) {
            self.minimumDepthMeters = minimumDepthMeters
            self.minimumDuration = minimumDuration
        }
    }

    /// Depth (m) below which the diver is considered underwater rather than at the surface.
    public var surfaceThresholdMeters: Double
    /// Acceptance rules; a candidate is kept as a dive if it satisfies **any** of them.
    public var thresholds: [DiveThreshold]

    /// Designated initializer.
    public init(surfaceThresholdMeters: Double = 1.0, thresholds: [DiveThreshold]) {
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.thresholds = thresholds
    }

    /// Convenience for a single (depth, duration) gate — the historical shape,
    /// used across the tests.
    public init(
        surfaceThresholdMeters: Double = 1.0,
        minimumDiveDepthMeters: Double = 1.5,
        minimumDiveDuration: TimeInterval = 3
    ) {
        self.init(
            surfaceThresholdMeters: surfaceThresholdMeters,
            thresholds: [DiveThreshold(minimumDepthMeters: minimumDiveDepthMeters, minimumDuration: minimumDiveDuration)]
        )
    }

    /// Default tiers: a quick duck dive to **2 m** (≥2 s), a normal **1.5 m** dive
    /// (≥3 s), or a sustained shallow dive past **1 m** (≥10 s). The shallow tier
    /// lets pool / snorkel dives register while a brief bob at the surface still
    /// doesn't; deeper dives qualify sooner. (`DiveDetectionConfig()` with no
    /// arguments is the single 1.5 m/3 s gate — use `.default` for the tiers.)
    public static let `default` = DiveDetectionConfig(
        thresholds: [
            DiveThreshold(minimumDepthMeters: 2.0, minimumDuration: 2),
            DiveThreshold(minimumDepthMeters: 1.5, minimumDuration: 3),
            DiveThreshold(minimumDepthMeters: 1.0, minimumDuration: 10),
        ]
    )
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
            // A candidate is a dive if it satisfies ANY acceptance tier: deep and
            // brief (a duck dive), or shallow and sustained (a pool/snorkel dive).
            // Each tier pairs a depth floor with a duration floor, so a long shallow
            // bob (wrist under at the surface) and a brief deep noise spike are both
            // rejected — one fails the depth floor of every fast tier, the other the
            // duration floor of every shallow tier.
            guard config.thresholds.contains(where: {
                maxDepth >= $0.minimumDepthMeters && duration >= $0.minimumDuration
            }) else { return }
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

    /// Detects dives, honoring explicit **manual** dive segments (Action + side on
    /// the watch). A manual segment defines a dive directly from the samples in its
    /// window — even if depth never crossed the threshold — and **pre-empts**
    /// auto-detection: any auto dive overlapping a manual segment is dropped so a
    /// dive isn't counted twice. Manual + surviving auto dives come back time-ordered.
    public func detectDives(from samples: [DepthSample], manualSegments: [DateInterval]) -> [Dive] {
        guard !manualSegments.isEmpty else { return detectDives(from: samples) }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let auto = detectDives(from: ordered).filter { dive in
            let window = DateInterval(start: dive.startTime, end: dive.endTime)
            return !manualSegments.contains { $0.intersects(window) }
        }
        let manual = manualSegments.map { segment -> Dive in
            let inSegment = ordered.filter { segment.contains($0.timestamp) }
            return Dive(
                startTime: segment.start,
                endTime: segment.end,
                maxDepthMeters: inSegment.map(\.depthMeters).max() ?? 0,
                samples: inSegment
            )
        }
        return (auto + manual).sorted { $0.startTime < $1.startTime }
    }
}
