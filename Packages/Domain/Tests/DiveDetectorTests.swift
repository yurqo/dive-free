import Foundation
import Testing
@testable import Domain

@Suite("DiveDetector")
struct DiveDetectorTests {
    /// Builds samples spaced one second apart from a depth profile.
    private func samples(_ depths: [Double], start: Date = Date(timeIntervalSince1970: 0)) -> [DepthSample] {
        depths.enumerated().map { index, depth in
            DepthSample(timestamp: start.addingTimeInterval(Double(index)), depthMeters: depth)
        }
    }

    @Test("detects a single dive from one descent/ascent")
    func detectsSingleDive() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0)
        )
        let dives = detector.detectDives(from: samples([0, 0, 2, 5, 8, 5, 2, 0, 0]))

        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 8)
    }

    @Test("detects two separate dives across a surface interval")
    func detectsTwoDives() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0)
        )
        let dives = detector.detectDives(from: samples([0, 4, 6, 0, 0, 3, 9, 2, 0]))

        #expect(dives.count == 2)
        #expect(dives.map(\.maxDepthMeters) == [6, 9])
    }

    @Test("ignores a shallow, brief bob")
    func ignoresShallowNoise() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Above the surface threshold but under the depth bar, spanning ~1s.
        let dives = detector.detectDives(from: samples([0, 1.2, 1.3, 0]))

        #expect(dives.isEmpty)
    }

    @Test("ignores a long shallow bob that never reaches the depth bar")
    func ignoresLongShallowBob() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Wrist under the surface threshold for ~6s but never past 1.5 m — under
        // the old depth-OR-duration rule this counted; under depth-AND-duration it
        // must not.
        let dives = detector.detectDives(from: samples([0, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 0]))

        #expect(dives.isEmpty)
    }

    @Test("ignores a brief deep spike shorter than the minimum duration")
    func ignoresBriefDeepSpike() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Reaches 4 m but spans only ~1s (two samples) — too brief to be a dive.
        let dives = detector.detectDives(from: samples([0, 4, 4, 0]))

        #expect(dives.isEmpty)
    }

    @Test("counts a genuine dive that is both deep enough and long enough")
    func countsGenuineDive() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // ≥1.5 m and ≥3 s.
        let dives = detector.detectDives(from: samples([0, 2, 4, 5, 4, 2, 0]))

        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 5)
    }

    // MARK: - Default tiers (deep-fast OR shallow-sustained)

    @Test("default tiers: a sustained shallow dive (~1 m for ~8 s) counts")
    func defaultCountsSustainedShallow() {
        let detector = DiveDetector() // .default tiers
        // Just past 1 m for ~8 s — under the 1.5 m tier's depth, but over the
        // shallow tier's 5 s dwell. This is the pool / snorkel case.
        let dives = detector.detectDives(from: samples([0] + Array(repeating: 1.2, count: 8) + [0]))
        #expect(dives.count == 1)
    }

    @Test("default tiers: the shallow tier now trips at ~5 s (was 10 s)")
    func defaultShallowTierIsFiveSeconds() {
        let detector = DiveDetector() // .default tiers
        // 1.2 m held for 5 s (6 samples above the 1 m threshold → the deep run), then a
        // 0 m exit — under the old 10 s shallow tier, over the new 5 s one. Acceptance
        // is judged on the deep span alone (the 0 m exit counts only toward the logged
        // duration), so the deep run must itself reach the tier's 5 s.
        let dives = detector.detectDives(from: samples([0] + Array(repeating: 1.2, count: 6) + [0]))
        #expect(dives.count == 1)
    }

    @Test("default tiers: a brief shallow dip (~1 m for a few s) is ignored")
    func defaultIgnoresBriefShallow() {
        let detector = DiveDetector() // .default tiers
        // 1.2 m for ~3 s — clears no fast tier's depth and no shallow tier's dwell.
        let dives = detector.detectDives(from: samples([0] + Array(repeating: 1.2, count: 2) + [0]))
        #expect(dives.isEmpty)
    }

    @Test("default tiers: a quick duck dive to ~2 m counts within a couple of seconds")
    func defaultCountsQuickDuckDive() {
        let detector = DiveDetector() // .default tiers
        // Reaches ~2.4 m spanning ~3 s — too brief for the 1.5 m/3 s edge, but the
        // 2 m/2 s duck-dive tier catches it.
        let dives = detector.detectDives(from: samples([0, 2.2, 2.3, 2.4, 0]))
        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 2.4)
    }

    // MARK: - Dive end at the surface (#16)

    @Test("a shallow bounce during a dive keeps it a single dive")
    func bounceMergesIntoOneDive() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        // Deep → shallow (0.8 m) for 2 s < the 3 s dwell → deep again → surface.
        let dives = detector.detectDives(from: samples([0, 4, 4, 0.8, 0.8, 4, 4, 0]))
        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 4)
    }

    @Test("ending at 0 m includes the ascent through the shallow band")
    func zeroMeterEndIncludesTail() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0, 5, 5, 5, 0], start: start)
        let dives = detector.detectDives(from: s)
        #expect(dives.count == 1)
        // endTime is the 0 m sample (t4), not the last deep sample (t3), so the
        // final metre of ascent counts toward the dive's duration.
        #expect(dives.first?.endTime == start.addingTimeInterval(4))
        // Deep run t1–t3 plus the 0 m exit at t4 → 3 s (legacy would have been 2 s,
        // ending at the last deep sample t3).
        #expect(dives.first?.duration == 3)
    }

    @Test("a shallow hang past the dwell ends the dive at the threshold crossing")
    func dwellExpiryTrimsToCrossing() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        // Deep for 3 s (t1–t3), then a 0.5 m hang that never reaches 0 m. The dwell
        // expires at t6 → the dive ends at t3 (the crossing), excluding the hang.
        let s = samples([0, 3, 3, 3, 0.5, 0.5, 0.5, 0.5], start: start)
        let dives = detector.detectDives(from: s)
        #expect(dives.count == 1)
        #expect(dives.first?.endTime == start.addingTimeInterval(3))
        #expect(dives.first?.samples.count == 3)
        #expect(dives.first?.samples.allSatisfy { $0.depthMeters > 1 } == true)
    }

    @Test("dwell = 0 restores legacy immediate end at the crossing")
    func zeroDwellEndsAtCrossing() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 0, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        // A single shallow sample after the deep run ends the dive immediately at
        // the crossing (t2), just like the old first-below-threshold rule.
        let s = samples([0, 4, 4, 0.5, 0.5, 4, 4, 0], start: start)
        let dives = detector.detectDives(from: s)
        #expect(dives.count == 2)
        #expect(dives.first?.endTime == start.addingTimeInterval(2))
    }

    @Test("dwell timed from the first shallow sample doesn't split a borderline bounce")
    func dwellAnchoredAtFirstShallowSample() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        // Deep t1–t2, then a 3-sample shallow spell t3–t5 (0.8 m), then deep again.
        // Measured from the LAST DEEP sample (t2) the spell reaches 3 s at t5 (the old
        // anchor would split here); measured from the FIRST SHALLOW sample (t3) it only
        // spans 2 s (t3→t5), under the dwell — so the bounce folds back in and the whole
        // thing stays a single dive.
        let dives = detector.detectDives(from: samples([0, 4, 4, 0.8, 0.8, 0.8, 4, 4, 0]))
        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 4)
    }

    // MARK: - Acceptance judged on the deep span only (#16 follow-up)

    @Test("a lone deep spike + shallow tail + 0 m exit is not inflated into a dive")
    func deepSpikeWithTailIsNotADive() {
        let detector = DiveDetector() // .default tiers (2 m/2 s, 1.5 m/3 s, 1 m/5 s)
        // One deep sample (2.3 m) then a shallow tail to 0 m. The full span is 3 s and
        // would clear the 2 m/2 s tier if the tail counted toward acceptance — but the
        // DEEP span is a single sample (zero duration), so the spike guard rejects it.
        let dives = detector.detectDives(from: samples([0, 2.3, 0.8, 0.6, 0]))
        #expect(dives.isEmpty)
    }

    @Test("a sustained deep run logs its ascent tail in the duration")
    func sustainedDiveLogsTailInDuration() {
        let detector = DiveDetector() // .default tiers
        let start = Date(timeIntervalSince1970: 0)
        // 1.6 m held for 3 s (deep span t1–t4) clears the 1.5 m/3 s tier, then a 0 m
        // exit at t5. Acceptance uses the 3 s deep span; the logged dive includes the
        // ascent tail, so the recorded duration is 4 s.
        let dives = detector.detectDives(from: samples([0, 1.6, 1.6, 1.6, 1.6, 0], start: start))
        #expect(dives.count == 1)
        #expect(dives.first?.duration == 4)
        #expect(dives.first?.endTime == start.addingTimeInterval(5))
    }

    // MARK: - Manual dive segments (#115)

    @Test("a manual segment defines a dive even when depth never crossed the bar")
    func manualShallowDive() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0.5, 0.8, 0.6, 0.4], start: start) // all shallow → auto finds nothing
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(3))])
        #expect(dives.count == 1)
        #expect(dives.first?.startTime == start)
    }

    @Test("a manual segment pre-empts an overlapping auto dive (no double count)")
    func manualPreemptsAuto() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0, 4, 8, 5, 0], start: start) // auto would find one dive
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(4))])
        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 8)
    }

    @Test("manual + non-overlapping auto dives are both kept, in time order")
    func manualPlusAuto() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0.5, 0.5, 0.5, 0, 0, 0, 4, 6, 0], start: start) // auto dive late, manual early
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(2))])
        #expect(dives.count == 2)
        #expect(dives.map(\.startTime) == dives.map(\.startTime).sorted())
    }

    @Test("no manual segments behaves like plain detection")
    func noManualSegments() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let s = samples([0, 5, 8, 0])
        #expect(detector.detectDives(from: s, manualSegments: []).count == detector.detectDives(from: s).count)
    }

    @Test("a deep manual stop then a sub-dwell bounce and re-descent logs only the manual dive")
    func manualStopBounceSuppressesRedescent() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        // Deep through the manual segment [t0,t2], a sub-dwell (1 s) shallow bounce at
        // t4, a re-descent, then a real surface (0 m) at t8. The post-manual descent
        // must stay suppressed — only the manual dive is logged.
        let s = samples([4, 4, 4, 4, 0.8, 4, 4, 4, 0], start: start)
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(2))])
        #expect(dives.count == 1)
        #expect(dives.first?.startTime == start)   // the manual dive
    }

    @Test("a shallow spell that began before the manual stop doesn't swallow a later dive")
    func manualStopShallowSpellAnchoredAtStart() {
        // Profile [4,4,4,0.8,0.8,0.8,0.8,4,4,4,4,0], manual [t0,t5], dwell 3.
        // The shallow spell starts at t3 (before the t5 stop). Anchoring the dwell at
        // t3 ends the pre-emption at t6, so the genuine [t7,t11] descent survives.
        // (Anchoring at t5 instead would push the exit to t11 and drop that dive.)
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([4, 4, 4, 0.8, 0.8, 0.8, 0.8, 4, 4, 4, 4, 0], start: start)
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(5))])
        // The manual dive [t0,t5] plus the surviving auto dive [t7,t11].
        #expect(dives.count == 2)
        #expect(dives.contains { $0.startTime == start.addingTimeInterval(7) && $0.endTime == start.addingTimeInterval(11) })
    }

    @Test("a manual stop then a true surface and a new descent logs both dives")
    func manualStopTrueSurfaceLogsBoth() {
        let detector = DiveDetector(config: DiveDetectionConfig(surfaceExitDwellSeconds: 3, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        // Manual [t0,t1] (stopped deep), a genuine 0 m surface at t2, then a fresh
        // descent t3–t4 and surface t5. Both dives should survive.
        let s = samples([4, 4, 0, 4, 6, 0], start: start)
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(1))])
        #expect(dives.count == 2)
        #expect(dives.map(\.maxDepthMeters).contains(6))   // the new descent survived
    }

    // MARK: - Configurable detection (Codable + sanitized, plan 15)

    @Test("a detection config survives a JSON encode/decode round trip")
    func configRoundTrips() throws {
        let config = DiveDetectionConfig(surfaceThresholdMeters: 1.0, surfaceExitDwellSeconds: 4, thresholds: [
            .init(minimumDepthMeters: 2.0, minimumDuration: 2),
            .init(minimumDepthMeters: 1.0, minimumDuration: 6),
        ])
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DiveDetectionConfig.self, from: data) == config)
    }

    @Test("a partial config payload decodes with defaults for absent keys")
    func partialConfigDecodes() throws {
        // Only thresholds present — surface threshold and dwell fall back to defaults,
        // keeping the wire format additive (older/newer payloads still decode).
        let json = #"{"thresholds":[{"minimumDepthMeters":1.5,"minimumDuration":3}]}"#
        let decoded = try JSONDecoder().decode(DiveDetectionConfig.self, from: Data(json.utf8))
        #expect(decoded.surfaceThresholdMeters == 1.0)
        #expect(decoded.surfaceExitDwellSeconds == 3)
        #expect(decoded.thresholds.count == 1)
    }

    @Test("an empty config payload decodes to the default tiers")
    func emptyConfigDecodes() throws {
        let decoded = try JSONDecoder().decode(DiveDetectionConfig.self, from: Data("{}".utf8))
        #expect(decoded.thresholds == DiveDetectionConfig.default.thresholds)
        #expect(decoded.surfaceExitDwellSeconds == 3)
    }

    @Test("sanitized clamps depths, durations, and the dwell into range")
    func sanitizedClamps() {
        let config = DiveDetectionConfig(surfaceExitDwellSeconds: 99, thresholds: [
            .init(minimumDepthMeters: 0.2, minimumDuration: 0),     // both below the floor
            .init(minimumDepthMeters: 40, minimumDuration: 500),    // both above the ceiling
        ]).sanitized()
        #expect(config.surfaceExitDwellSeconds == 10)               // dwell clamped to [1, 10]
        #expect(config.thresholds[0].minimumDepthMeters == 1.0)     // floor = surface threshold
        #expect(config.thresholds[0].minimumDuration == 1)          // duration floor
        #expect(config.thresholds[1].minimumDepthMeters == 6.0)     // depth ceiling
        #expect(config.thresholds[1].minimumDuration == 30)         // duration ceiling
    }

    @Test("sanitized raises a too-small dwell to the floor")
    func sanitizedDwellFloor() {
        let config = DiveDetectionConfig(surfaceExitDwellSeconds: 0, thresholds: [
            .init(minimumDepthMeters: 1.5, minimumDuration: 3),
        ]).sanitized()
        #expect(config.surfaceExitDwellSeconds == 1)
    }

    @Test("sanitized drops non-finite tiers and falls back to the default when none survive")
    func sanitizedFallsBack() {
        let config = DiveDetectionConfig(thresholds: [
            .init(minimumDepthMeters: .nan, minimumDuration: 3),
        ]).sanitized()
        #expect(config.thresholds == DiveDetectionConfig.default.thresholds)
    }

    @Test("sanitized clamps a crafted out-of-range surface threshold into [0.5, 2.0]")
    func sanitizedClampsSurfaceThreshold() {
        // 50 would make every sample "shallow" (no dive ever registers); -1 would make
        // every sample "deep" (surface bobbing logs as dives). Both are clamped.
        let tier: [DiveDetectionConfig.DiveThreshold] = [.init(minimumDepthMeters: 3, minimumDuration: 3)]
        #expect(DiveDetectionConfig(surfaceThresholdMeters: 50, thresholds: tier).sanitized().surfaceThresholdMeters == 2.0)
        #expect(DiveDetectionConfig(surfaceThresholdMeters: -1, thresholds: tier).sanitized().surfaceThresholdMeters == 0.5)
        #expect(DiveDetectionConfig(surfaceThresholdMeters: .nan, thresholds: tier).sanitized().surfaceThresholdMeters == 1.0)
    }

    @Test("sanitized falls back to a sane dwell when it is non-finite (NaN survives min/max)")
    func sanitizedNaNDwell() {
        let config = DiveDetectionConfig(surfaceExitDwellSeconds: .nan, thresholds: [
            .init(minimumDepthMeters: 1.5, minimumDuration: 3),
        ]).sanitized()
        #expect(config.surfaceExitDwellSeconds == 3)
    }
}
