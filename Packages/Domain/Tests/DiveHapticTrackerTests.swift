import Foundation
import Testing
@testable import Domain

@Suite("DiveHapticTracker")
struct DiveHapticTrackerTests {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Drives the tracker through a depth profile and collects all events.
    /// Samples are spaced `spacing` seconds apart from a fixed epoch (default 1 s),
    /// so time-based dwell logic is exercised deterministically.
    private func run(
        _ depths: [Double],
        config: DiveHapticConfig = .default,
        spacing: TimeInterval = 1
    ) -> [DiveHapticEvent] {
        var tracker = DiveHapticTracker(config: config)
        return depths.enumerated().flatMap { index, depth in
            tracker.update(depthMeters: depth, at: Self.epoch.addingTimeInterval(Double(index) * spacing))
        }
    }

    @Test("emits diveStart when depth crosses surface threshold going down")
    func emitsDiveStart() {
        let events = run([0, 0.5, 1.5])
        #expect(events == [.diveStart])
    }

    @Test("emits surface when diver returns above threshold")
    func emitsSurface() {
        let events = run([0, 2, 0])
        #expect(events == [.diveStart, .surface])
    }

    @Test("emits descend milestone on 5 m crossing")
    func emitsDescendMilestone() {
        let events = run([0, 2, 6])
        #expect(events == [.diveStart, .descendMilestone(depthMeters: 5)])
    }

    @Test("emits second descend milestone on 10 m crossing")
    func emitsDescendMilestoneAt10m() {
        let events = run([0, 2, 6, 11])
        #expect(events == [
            .diveStart,
            .descendMilestone(depthMeters: 5),
            .descendMilestone(depthMeters: 10)
        ])
    }

    @Test("emits ascend milestone when coming back up through a boundary")
    func emitsAscendMilestone() {
        // Depth jumps 0→11 in one sample, so the tracker lands at level 2 (10 m)
        // without a separate level-1 crossing. Ascending to 6 then crosses back
        // through level 1, emitting the ascend cue.
        let events = run([0, 11, 6])
        #expect(events == [
            .diveStart,
            .descendMilestone(depthMeters: 10),
            .ascendMilestone(depthMeters: 5)
        ])
    }

    @Test("no milestone events when milestoneIntervalMeters is 0")
    func noMilestonesWhenDisabled() {
        let config = DiveHapticConfig(milestoneIntervalMeters: 0)
        let events = run([0, 2, 6, 11, 6, 0], config: config)
        #expect(events == [.diveStart, .surface])
    }

    @Test("samples that stay within the same band emit no events")
    func noisyDepthNoExtraEvents() {
        // Bouncing between 5.1 and 5.9 should not fire extra milestones.
        let events = run([0, 2, 5.1, 5.3, 5.9, 5.1, 5.3, 0])
        #expect(events == [
            .diveStart,
            .descendMilestone(depthMeters: 5),
            .surface
        ])
    }

    @Test("full profile produces expected ordered event stream")
    func fullProfile() {
        let events = run([0, 2, 6, 11, 6, 0])
        #expect(events == [
            .diveStart,
            .descendMilestone(depthMeters: 5),
            .descendMilestone(depthMeters: 10),
            .ascendMilestone(depthMeters: 5),
            .surface
        ])
    }

    @Test("two consecutive dives each emit their own diveStart and surface")
    func twoDives() {
        let events = run([0, 2, 0, 0, 3, 0])
        #expect(events == [.diveStart, .surface, .diveStart, .surface])
    }

    @Test("a shallow bounce shorter than the dwell fires neither a surface nor a second diveStart")
    func shallowBounceDoesNotDoubleFire() {
        // Deep → 0.8 m (below the 1 m threshold but above 0) → deep → surface.
        // The shallow band lasts ~1 s (t=2..t=3), under the 3 s dwell, so the diver
        // stays "submerged" through the bounce: one diveStart / surface pair fires
        // for the whole dive.
        let events = run([0, 2, 0.8, 0.8, 2, 0])
        #expect(events == [.diveStart, .surface])
    }

    @Test("a shallow hang past the dwell fires surface without any 0 m reading, then a re-descent fires a fresh diveStart")
    func shallowHangEndsDiveAndReDescendRestarts() {
        // Regression (#16 follow-up): repeated dives whose wrist never fully clears
        // the water (depth stays ~0.1–0.9 m, never ≤ 0.05 m). Hanging in the shallow
        // band ≥ the 3 s dwell must fire `surface`; the next descent past 1 m must
        // fire a fresh `diveStart`. Samples are 1 s apart.
        //  t: 0    1    2    3    4    5    6    7
        //     0    2    0.5  0.5  0.5  0.5  2    0
        // Shallow from t=2; at t=5 the 3 s dwell expires → surface (no 0 m seen).
        let events = run([0, 2, 0.5, 0.5, 0.5, 0.5, 2, 0])
        #expect(events == [.diveStart, .surface, .diveStart, .surface])
    }

    @Test("reaching 0 m ends the dive immediately without waiting for the dwell")
    func zeroMetersEndsImmediately() {
        // Deep → 0 m on the very next sample (1 s later, far under the 3 s dwell).
        // The 0 m rule ends the dive at once. (3 m avoids a 5 m milestone.)
        let events = run([0, 3, 0])
        #expect(events == [.diveStart, .surface])
    }

    @Test("no spurious 0 m milestone on the way up through the shallow band")
    func noZeroMilestoneOnAscent() {
        // Per-metre milestones (as configured on the watch). Ascending through the
        // 1 m band shouldn't announce a "0 m" milestone before the surface event.
        let config = DiveHapticConfig(milestoneIntervalMeters: 1.0)
        let events = run([0, 2.5, 1.5, 0.8, 0], config: config)
        #expect(events == [
            .diveStart,
            .descendMilestone(depthMeters: 2),
            .ascendMilestone(depthMeters: 1),
            .surface
        ])
    }
}
