import Foundation
import Testing
@testable import Domain

/// Tests for the pure surface-recovery helpers (recommended interval, colour tiers,
/// haptic crossing) and the recovery fields added to `DiveDetectionConfig`.
@Suite("SurfaceRecovery")
struct SurfaceRecoveryTests {
    // MARK: - recommendedInterval

    @Test("recommendedInterval applies the floor when multiplier × duration is below it")
    func recommendedIntervalFloor() {
        // 10 s dive × 3 = 30 s < 60 s floor → the floor wins.
        #expect(SurfaceRecovery.recommendedInterval(lastDiveDuration: 10, multiplier: 3, minimum: 60) == 60)
    }

    @Test("recommendedInterval scales with the multiplier above the floor")
    func recommendedIntervalScales() {
        // 40 s dive above the floor at each common multiplier.
        #expect(SurfaceRecovery.recommendedInterval(lastDiveDuration: 40, multiplier: 2, minimum: 60) == 80)
        #expect(SurfaceRecovery.recommendedInterval(lastDiveDuration: 40, multiplier: 2.5, minimum: 60) == 100)
        #expect(SurfaceRecovery.recommendedInterval(lastDiveDuration: 40, multiplier: 3, minimum: 60) == 120)
    }

    // MARK: - tier

    @Test("tier maps the third/two-thirds/target boundaries to short/building/nearly/rested")
    func tierBoundaries() {
        let t: TimeInterval = 90    // thirds at 30 and 60
        // Just below each boundary stays in the lower band; at the boundary steps up.
        #expect(SurfaceRecovery.tier(surfaceInterval: 0, recommended: t) == .short)
        #expect(SurfaceRecovery.tier(surfaceInterval: 29.9, recommended: t) == .short)
        #expect(SurfaceRecovery.tier(surfaceInterval: 30, recommended: t) == .building)
        #expect(SurfaceRecovery.tier(surfaceInterval: 59.9, recommended: t) == .building)
        #expect(SurfaceRecovery.tier(surfaceInterval: 60, recommended: t) == .nearly)
        #expect(SurfaceRecovery.tier(surfaceInterval: 89.9, recommended: t) == .nearly)
        #expect(SurfaceRecovery.tier(surfaceInterval: 90, recommended: t) == .rested)
        #expect(SurfaceRecovery.tier(surfaceInterval: 200, recommended: t) == .rested)
    }

    @Test("tier treats a non-positive recommended target as rested")
    func tierNonPositiveRecommended() {
        #expect(SurfaceRecovery.tier(surfaceInterval: 0, recommended: 0) == .rested)
        #expect(SurfaceRecovery.tier(surfaceInterval: 0, recommended: -5) == .rested)
    }

    // MARK: - hasReachedRecovery

    @Test("hasReachedRecovery is false below the target and true at or above it")
    func hasReachedRecoveryCrossing() {
        #expect(SurfaceRecovery.hasReachedRecovery(surfaceInterval: 59.9, recommended: 60) == false)
        #expect(SurfaceRecovery.hasReachedRecovery(surfaceInterval: 60, recommended: 60) == true)
        #expect(SurfaceRecovery.hasReachedRecovery(surfaceInterval: 120, recommended: 60) == true)
    }

    @Test("hasReachedRecovery is false when there is no target")
    func hasReachedRecoveryNoTarget() {
        #expect(SurfaceRecovery.hasReachedRecovery(surfaceInterval: 100, recommended: 0) == false)
    }

    // MARK: - restedHighlightDwell / isRestedHighlightActive

    @Test("the rested highlight lasts the dive's own duration, at any multiplier")
    func highlightDwellMatchesDiveDuration() {
        // Above the floor, recommended = multiplier × duration, so recommended/multiplier
        // collapses back to the dive's duration — 40 s of green for a 40 s dive.
        for multiplier in [2.0, 2.5, 3.0, 5.0] {
            let recommended = SurfaceRecovery.recommendedInterval(lastDiveDuration: 40, multiplier: multiplier, minimum: 60)
            #expect(SurfaceRecovery.restedHighlightDwell(recommended: recommended, multiplier: multiplier) == 40)
        }
    }

    @Test("on the 60 s floor the highlight is a proportionate share of the floor")
    func highlightDwellOnTheFloor() {
        // A 10 s dive is pinned to the 60 s minimum: 60/3 = 20 s of green, 60/2 = 30 s.
        let atThree = SurfaceRecovery.recommendedInterval(lastDiveDuration: 10, multiplier: 3, minimum: 60)
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: atThree, multiplier: 3) == 20)
        let atTwo = SurfaceRecovery.recommendedInterval(lastDiveDuration: 10, multiplier: 2, minimum: 60)
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: atTwo, multiplier: 2) == 30)
    }

    @Test("the highlight is active from the target until the dwell expires")
    func highlightExpiryBoundary() {
        // 40 s dive at 3× → 120 s target, 40 s of green → active over [120, 160).
        let recommended: TimeInterval = 120
        func active(_ interval: TimeInterval) -> Bool {
            SurfaceRecovery.isRestedHighlightActive(surfaceInterval: interval, recommended: recommended, multiplier: 3)
        }
        #expect(active(119.9) == false)  // not rested yet
        #expect(active(120) == true)     // the crossing lights it up
        #expect(active(159.9) == true)   // still inside the dwell
        #expect(active(160) == false)    // boundary is exclusive — green clears
        #expect(active(600) == false)    // and stays cleared
    }

    @Test("the tier stays .rested after the highlight expires")
    func tierUnchangedByHighlightExpiry() {
        // The four bands are untouched: reaching the target is still permanent, only
        // the highlight is transient (so the haptic's one-shot crossing is unaffected).
        #expect(SurfaceRecovery.tier(surfaceInterval: 600, recommended: 120) == .rested)
        #expect(SurfaceRecovery.hasReachedRecovery(surfaceInterval: 600, recommended: 120) == true)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 600, recommended: 120, multiplier: 3) == false)
    }

    @Test("a multiplier of 1 makes the highlight last the whole recovery period, and still ends")
    func highlightAtUnitMultiplier() {
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: 90, multiplier: 1) == 90)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 179.9, recommended: 90, multiplier: 1) == true)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 180, recommended: 90, multiplier: 1) == false)
    }

    @Test("a degenerate multiplier clamps the dwell to the recovery period — never zero, NaN, or unbounded")
    func highlightDwellClampsDegenerateMultipliers() {
        for multiplier in [0.0, -3.0, 0.5, Double.nan, .infinity, -.infinity] {
            let dwell = SurfaceRecovery.restedHighlightDwell(recommended: 90, multiplier: multiplier)
            #expect(dwell == 90, "multiplier \(multiplier) should clamp to a 1× dwell")
            #expect(dwell.isFinite)
            #expect(dwell > 0)
        }
        // …and the window it produces still terminates.
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 179.9, recommended: 90, multiplier: 0) == true)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 180, recommended: 90, multiplier: 0) == false)
    }

    @Test("no target means no highlight and a zero dwell")
    func highlightWithoutTarget() {
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: 0, multiplier: 3) == 0)
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: -5, multiplier: 3) == 0)
        #expect(SurfaceRecovery.restedHighlightDwell(recommended: .nan, multiplier: 3) == 0)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 100, recommended: 0, multiplier: 3) == false)
        #expect(SurfaceRecovery.isRestedHighlightActive(surfaceInterval: 100, recommended: -5, multiplier: 3) == false)
    }

    // MARK: - DiveDetectionConfig recovery fields (Codable back-compat + clamp)

    @Test("a payload missing the recovery keys decodes to the on/3× defaults")
    func recoveryDefaultsWhenAbsent() throws {
        // An older payload predating the recovery fields — must decode to the defaults
        // so cross-version sync doesn't break.
        let json = #"{"thresholds":[{"minimumDepthMeters":1.5,"minimumDuration":3}]}"#
        let decoded = try JSONDecoder().decode(DiveDetectionConfig.self, from: Data(json.utf8))
        #expect(decoded.recoveryEnabled == true)
        #expect(decoded.recoveryMultiplier == 3.0)
    }

    @Test("the recovery fields survive a JSON round trip when present")
    func recoveryRoundTrips() throws {
        let config = DiveDetectionConfig(
            thresholds: [.init(minimumDepthMeters: 1.5, minimumDuration: 3)],
            recoveryEnabled: false,
            recoveryMultiplier: 2.0
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DiveDetectionConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.recoveryEnabled == false)
        #expect(decoded.recoveryMultiplier == 2.0)
    }

    @Test("sanitized clamps the recovery multiplier into [1.5, 5.0]")
    func sanitizedClampsMultiplier() {
        let tier: [DiveDetectionConfig.DiveThreshold] = [.init(minimumDepthMeters: 1.5, minimumDuration: 3)]
        #expect(DiveDetectionConfig(thresholds: tier, recoveryMultiplier: 0.5).sanitized().recoveryMultiplier == 1.5)
        #expect(DiveDetectionConfig(thresholds: tier, recoveryMultiplier: 99).sanitized().recoveryMultiplier == 5.0)
        #expect(DiveDetectionConfig(thresholds: tier, recoveryMultiplier: 2.5).sanitized().recoveryMultiplier == 2.5)
        // Non-finite falls back to the 3× default.
        #expect(DiveDetectionConfig(thresholds: tier, recoveryMultiplier: .nan).sanitized().recoveryMultiplier == 3.0)
    }
}
