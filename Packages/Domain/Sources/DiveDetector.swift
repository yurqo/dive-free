import Foundation

/// Tunable thresholds for turning a stream of depth samples into discrete dives.
/// `Codable` so the phone can sync a diver-tuned config to the watch (the config
/// itself never persists to the model — stored `DiveRecord`s are immutable history).
public struct DiveDetectionConfig: Sendable, Equatable, Codable {
    /// One acceptance rule: a candidate counts as a dive if it reaches
    /// `minimumDepthMeters` AND lasts at least `minimumDuration`. Rules are OR-ed,
    /// so the deeper you go the sooner it counts (a quick duck dive), while a
    /// shallow dive must be sustained (which is what rejects brief surface bobbing).
    public struct DiveThreshold: Sendable, Equatable, Codable {
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

    private enum CodingKeys: String, CodingKey {
        case surfaceThresholdMeters, surfaceExitDwellSeconds, thresholds
    }

    /// Decodes defensively so an older or partial payload still yields a usable
    /// config: any absent key falls back to its default (the encode side is
    /// synthesized). Keeps the wire format additive — new fields can join later
    /// without breaking payloads already in flight.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            surfaceThresholdMeters: try container.decodeIfPresent(Double.self, forKey: .surfaceThresholdMeters) ?? 1.0,
            surfaceExitDwellSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .surfaceExitDwellSeconds) ?? 3,
            thresholds: try container.decodeIfPresent([DiveThreshold].self, forKey: .thresholds) ?? DiveDetectionConfig.default.thresholds
        )
    }

    /// Returns a copy with every value clamped to a sane, UI-representable range —
    /// the surface threshold to `[0.5, 2.0]` m, tier depths to
    /// `[surfaceThreshold, DepthFormat.maxMeasurableMeters]`, tier durations to
    /// `[1, 30]` s, the dwell to `[1, 10]` s — dropping any non-finite / degenerate
    /// tier, and falling back to `.default`'s tiers when none survive (at least one
    /// acceptance rule must remain). Applied before the config drives detection so a
    /// corrupt, hand-edited, or out-of-range payload can never produce pathological
    /// behaviour.
    ///
    /// The surface threshold isn't user-configurable, but a crafted payload could
    /// still carry a wild value — 50 makes every sample "shallow" (no dive ever
    /// registers), -1 makes every sample "deep" (surface bobbing logs as dives) — so
    /// it's clamped too. Non-finite values (which survive `min`/`max` unchanged —
    /// NaN compares false both ways) fall back to safe defaults.
    public func sanitized() -> DiveDetectionConfig {
        let threshold = surfaceThresholdMeters.isFinite ? min(max(surfaceThresholdMeters, 0.5), 2.0) : 1.0
        let dwell = surfaceExitDwellSeconds.isFinite ? min(max(surfaceExitDwellSeconds, 1), 10) : 3
        let cleaned = thresholds.compactMap { tier -> DiveThreshold? in
            guard tier.minimumDepthMeters.isFinite, tier.minimumDuration.isFinite else { return nil }
            return DiveThreshold(
                minimumDepthMeters: min(max(tier.minimumDepthMeters, threshold), DepthFormat.maxMeasurableMeters),
                minimumDuration: min(max(tier.minimumDuration, 1), 30)
            )
        }
        return DiveDetectionConfig(
            surfaceThresholdMeters: threshold,
            surfaceExitDwellSeconds: dwell,
            thresholds: cleaned.isEmpty ? DiveDetectionConfig.default.thresholds : cleaned
        )
    }
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
    /// auto-detection until the diver genuinely surfaces after it: the pre-emption
    /// window runs from the segment's start to the first true surface exit following
    /// its end (a 0 m sample, or the diver lingering in the shallow band for
    /// `surfaceExitDwellSeconds`). Any auto dive overlapping that window is dropped —
    /// so a dive isn't counted twice, and a sub-dwell bounce after a deep manual stop
    /// can't merge the post-manual descent into a dropped candidate NOR log it as its
    /// own dive (the diver must properly surface, or toggle manual again, to start a
    /// new dive). Manual + surviving auto dives come back time-ordered.
    public func detectDives(from samples: [DepthSample], manualSegments: [DateInterval]) -> [Dive] {
        guard !manualSegments.isEmpty else { return detectDives(from: samples) }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        // Extend each manual segment's pre-emption window forward to the first genuine
        // surface exit after it, so the post-manual descent stays suppressed through
        // any sub-dwell bounce until the diver actually returns to the surface.
        let preemption = manualSegments.map { segment in
            DateInterval(start: segment.start, end: firstSurfaceExit(after: segment.end, in: ordered))
        }
        let auto = detectDives(from: ordered).filter { dive in
            let window = DateInterval(start: dive.startTime, end: dive.endTime)
            return !preemption.contains { $0.intersects(window) }
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

    /// Timestamp of the first genuine surface exit at or after `time` in `ordered`
    /// (assumed sorted): an explicit 0 m reading (≤ `surfaceExitDepthMeters`), or the
    /// diver lingering in the shallow band (above the surface, below the threshold)
    /// for `surfaceExitDwellSeconds` — timed from the first shallow sample, and reset
    /// whenever depth drops back below the threshold. Mirrors the surface-exit rule of
    /// `detectDives(from:)` and the live layer so all three agree on when a dive ends.
    /// `.distantFuture` when the diver never surfaces again (the session ended deep).
    ///
    /// The dwell anchors at the START of the shallow spell already in progress at
    /// `time`, not at `time` itself: a diver who went shallow BEFORE a manual stop is
    /// already partway through the dwell, so anchoring at `time` would truncate the
    /// spell and reset it on the next descent — letting a genuine later dive get
    /// swallowed by the pre-emption window. So the scan begins at the last DEEP sample
    /// at or before `time` (or the first sample when the diver was never deep) and
    /// anchors at the first shallow sample after it, while only returning an exit at
    /// or after `time`.
    ///
    /// One case the forward scan alone gets wrong: the diver was **already surfaced**
    /// when the segment ended. The natural manual-dive flow is to surface FIRST (the
    /// sensor emits its explicit 0 m as the wrist clears), THEN press stop — and the
    /// submersion sensor stops emitting once surfaced, so no sample exists at or after
    /// `time`. A pure forward scan would then find the surface exit only in the NEXT
    /// dive's samples, stretching the pre-emption window over that genuine dive and
    /// dropping it. So we first check whether the diver was already up at `time`: the
    /// LAST sample at or before `time` (of ANY depth) is fully surfaced
    /// (≤ `surfaceExitDepthMeters`) → return `time` itself, so the window ends where the
    /// segment did and the next dive survives.
    private func firstSurfaceExit(after time: Date, in ordered: [DepthSample]) -> Date {
        let lastDeepBeforeTime = ordered.last {
            $0.timestamp <= time && $0.depthMeters > config.surfaceThresholdMeters
        }
        // Already surfaced at `time`? The rule is exactly the doc comment's: the LAST
        // sample at or before `time`, of ANY depth, is fully surfaced (≤ exit depth).
        // Using the *last* sample — not "a surfaced sample not older than the last deep
        // one" — avoids a STALE 0 m from an earlier dive falsely satisfying this: e.g.
        // dive1 ends 0 m at t9, then a shallow manual dive sits at 0.5 m t22–t29 and the
        // stop lands at t30. The old comparison saw the t9 0 m as "surfaced after the
        // last deep sample" and returned t30, but the live layer keeps suppressing
        // through the 0.5 m band, so live and final disagreed. The last sample before a
        // t30 stop is the 0.5 m one → not surfaced → we fall through to the forward scan.
        //
        // Consequence: an all-shallow-before-`time` shape (last sample above the exit
        // threshold) also falls through to the forward scan rather than returning `time`.
        // That is CONSISTENT with the live layer, whose `stopManualDive` arms suppression
        // whenever depth > exit threshold, so it too keeps suppressing until the true
        // exit rather than ending at the stop.
        if let last = ordered.last(where: { $0.timestamp <= time }) {
            if last.depthMeters <= DiveDetectionConfig.surfaceExitDepthMeters {
                return time
            }
        } else {
            // Dry-land accidental toggle: no sample at all at or before `time` (the
            // sensor never emitted near the segment — the diver was never in the water).
            // Treat the segment as ended at the surface so the day's next dive isn't
            // suppressed by a `.distantFuture` window.
            return time
        }
        var shallowAnchor: Date?
        for sample in ordered {
            // Start the scan just after the last deep sample at/before `time` (the
            // in-progress shallow spell began there); skip everything up to it.
            if let lastDeep = lastDeepBeforeTime, sample.timestamp <= lastDeep.timestamp { continue }
            let depth = sample.depthMeters
            if depth > config.surfaceThresholdMeters {
                shallowAnchor = nil                              // deep again → dwell resets
            } else if depth <= DiveDetectionConfig.surfaceExitDepthMeters {
                if sample.timestamp >= time { return sample.timestamp }  // explicit 0 m → surfaced
                shallowAnchor = nil                              // a 0 m before `time` resets the spell
            } else {
                let anchor = shallowAnchor ?? sample.timestamp
                shallowAnchor = anchor
                if sample.timestamp >= time,
                   sample.timestamp.timeIntervalSince(anchor) >= config.surfaceExitDwellSeconds {
                    return sample.timestamp                      // shallow past the dwell → surfaced
                }
            }
        }
        return .distantFuture
    }
}
