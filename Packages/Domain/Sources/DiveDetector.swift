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
    /// How long (s) the diver must stay continuously shallower than
    /// `surfaceThresholdMeters` — without reaching the surface (0 m) — before an
    /// in-progress dive is treated as ended. A shorter shallow excursion (a bounce)
    /// stays part of the same dive. Set to 0 for the legacy "end at the first
    /// below-threshold sample" behaviour.
    public var surfaceExitDwellSeconds: TimeInterval
    /// Acceptance rules; a candidate is kept as a dive if it satisfies **any** of them.
    public var thresholds: [DiveThreshold]

    /// Depth (m) at or below which the diver is treated as fully surfaced: the
    /// water-submersion sensor emits an explicit 0 m reading when the wrist clears
    /// the water, so a reading this shallow ends the dive immediately (no dwell).
    /// A small epsilon absorbs float noise around the exact-zero sample.
    public static let surfaceExitDepthMeters: Double = 0.05

    /// Designated initializer.
    public init(
        surfaceThresholdMeters: Double = 1.0,
        surfaceExitDwellSeconds: TimeInterval = 3,
        thresholds: [DiveThreshold]
    ) {
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.surfaceExitDwellSeconds = surfaceExitDwellSeconds
        self.thresholds = thresholds
    }

    /// Convenience for a single (depth, duration) gate — the historical shape,
    /// used across the tests.
    public init(
        surfaceThresholdMeters: Double = 1.0,
        surfaceExitDwellSeconds: TimeInterval = 3,
        minimumDiveDepthMeters: Double = 1.5,
        minimumDiveDuration: TimeInterval = 3
    ) {
        self.init(
            surfaceThresholdMeters: surfaceThresholdMeters,
            surfaceExitDwellSeconds: surfaceExitDwellSeconds,
            thresholds: [DiveThreshold(minimumDepthMeters: minimumDiveDepthMeters, minimumDuration: minimumDiveDuration)]
        )
    }

    /// Default tiers: a quick duck dive to **2 m** (≥2 s), a normal **1.5 m** dive
    /// (≥3 s), or a sustained shallow dive past **1 m** (≥5 s). The shallow tier
    /// lets pool / snorkel dives register while a brief bob at the surface still
    /// doesn't; deeper dives qualify sooner. (`DiveDetectionConfig()` with no
    /// arguments is the single 1.5 m/3 s gate — use `.default` for the tiers.)
    public static let `default` = DiveDetectionConfig(
        thresholds: [
            DiveThreshold(minimumDepthMeters: 2.0, minimumDuration: 2),
            DiveThreshold(minimumDepthMeters: 1.5, minimumDuration: 3),
            DiveThreshold(minimumDepthMeters: 1.0, minimumDuration: 5),
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
    ///
    /// A dive stays open while the diver is deeper than `surfaceThresholdMeters`,
    /// and ends the moment depth reaches the surface (≤ `surfaceExitDepthMeters`,
    /// i.e. an explicit 0 m reading) — including the whole ascent through the
    /// shallow band in the dive. If instead the diver lingers shallow (above the
    /// surface, below the threshold) for `surfaceExitDwellSeconds` — timed from the
    /// **first** shallow sample, to match the live layers (`SessionManager` /
    /// `DiveHapticTracker`) so they agree on when a shallow spell ends the dive —
    /// the dive ends at the threshold crossing, excluding that shallow hang. A brief
    /// shallow excursion shorter than the dwell (a bounce) folds back into the same dive.
    public func detectDives(from samples: [DepthSample]) -> [Dive] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var dives: [Dive] = []
        // Confirmed (deep + folded-in bounce) part of the open dive.
        var current: [DepthSample] = []
        // Shallow samples buffered since the last threshold crossing, pending a
        // surface-exit decision (bounce → fold back in; dwell → drop).
        var shallowTail: [DepthSample] = []

        // Emits a dive from a completed candidate if it clears an acceptance tier.
        // Two spans matter and they differ on purpose:
        //  - ACCEPTANCE is judged on the DEEP run only (`deep.first`…`deep.last`,
        //    with folded bounces inside `deep` still counting — intended). The tier
        //    check and the single-sample spike guard use this span, so a lone noisy
        //    deep sample followed by a shallow tail can't borrow the tail's duration
        //    to sneak past a tier (e.g. [0, 2.3, 0.8, 0.6, 0] would otherwise clear
        //    the 2 m / 2 s tier on a zero-duration deep spike).
        //  - the LOGGED dive keeps the FULL sample set (`deep` + `tail`): startTime =
        //    first deep sample, endTime = last overall sample, maxDepth over all. A
        //    0 m exit folds the ascent tail in here, so the ascent counts toward the
        //    logged duration even though it doesn't help pass acceptance.
        func finalize(deep: [DepthSample], tail: [DepthSample]) {
            guard let deepFirst = deep.first, let deepLast = deep.last else { return }
            let deepSpan = deepLast.timestamp.timeIntervalSince(deepFirst.timestamp)
            // Ignore an instantaneous spike (a single deep sample / zero time span):
            // a real dive always covers more than one deep reading, so a lone noisy
            // deep sample shouldn't register as a zero-duration dive (it would
            // otherwise pass the depth-and-duration gate below when a tier's
            // minimumDuration is 0).
            guard deepSpan > 0 else { return }
            let deepMaxDepth = deep.map(\.depthMeters).max() ?? 0
            // A candidate is a dive if its DEEP span satisfies ANY acceptance tier:
            // deep and brief (a duck dive), or shallow and sustained (a pool/snorkel
            // dive). Each tier pairs a depth floor with a duration floor, so a long
            // shallow bob (wrist under at the surface) and a brief deep noise spike
            // are both rejected — one fails the depth floor of every fast tier, the
            // other the duration floor of every shallow tier.
            guard config.thresholds.contains(where: {
                deepMaxDepth >= $0.minimumDepthMeters && deepSpan >= $0.minimumDuration
            }) else { return }
            let all = deep + tail
            let last = all.last ?? deepLast
            let maxDepth = all.map(\.depthMeters).max() ?? deepMaxDepth
            dives.append(
                Dive(
                    startTime: deepFirst.timestamp,
                    endTime: last.timestamp,
                    maxDepthMeters: maxDepth,
                    samples: all
                )
            )
        }

        for sample in ordered {
            let depth = sample.depthMeters
            if depth > config.surfaceThresholdMeters {
                // Deep: fold any pending shallow bounce back into the dive, then
                // extend it with this sample.
                if !current.isEmpty { current.append(contentsOf: shallowTail) }
                shallowTail.removeAll()
                current.append(sample)
            } else if current.isEmpty {
                // At/near the surface with no dive open — surface bobbing, ignore.
                continue
            } else if depth <= DiveDetectionConfig.surfaceExitDepthMeters {
                // Explicit 0 m: fully surfaced. End the dive; the deep run gates
                // acceptance while the shallow tail + this 0 m sample are logged so
                // the final ascent counts toward the recorded duration.
                finalize(deep: current, tail: shallowTail + [sample])
                current.removeAll()
                shallowTail.removeAll()
            } else {
                // Shallow band (above the surface, below the threshold): buffer this
                // sample first, then measure the dwell as the span from the FIRST
                // buffered shallow sample to it. Appending before reading
                // `shallowTail.first` makes the anchor equal this sample on the first
                // shallow reading (a zero span, never past the dwell), and the first
                // shallow sample thereafter — matching the live layers, which time
                // the dwell from the first shallow sample rather than the last deep one.
                shallowTail.append(sample)
                if let anchor = shallowTail.first,
                   sample.timestamp.timeIntervalSince(anchor.timestamp) >= config.surfaceExitDwellSeconds {
                    // Stayed shallow past the dwell → the diver was at the surface.
                    // End the dive at the crossing (last deep sample in `current`);
                    // drop the shallow hang.
                    finalize(deep: current, tail: [])
                    current.removeAll()
                    shallowTail.removeAll()
                }
            }
        }
        // Session ended mid-dive (never surfaced): fold in any pending shallow tail
        // and finalize with what we have.
        if !current.isEmpty { finalize(deep: current, tail: shallowTail) }
        return dives
    }

    /// Detects dives, honoring explicit **manual** dive segments (Action + side on
    /// the watch). A manual segment defines a dive directly from the samples in its
    /// window — even if depth never crossed the threshold — and **pre-empts**
    /// auto-detection: any auto dive overlapping a manual segment is dropped so a
    /// dive isn't counted twice. Manual + surviving auto dives come back time-ordered.
    ///
    /// - Note: pre-emption interacts with bounce folding. If a manual dive is stopped
    ///   while still deep and the diver then dips shallow only briefly (a sub-dwell
    ///   bounce) before descending again, the auto pass folds that bounce back in and
    ///   merges the post-manual descent into a single candidate that overlaps the
    ///   manual segment — so the overlap filter drops the whole thing, losing the
    ///   post-manual descent. Accepted for now; revisit with configurable detection
    ///   (plan 15).
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
