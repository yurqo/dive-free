import Foundation
import Testing
@testable import Domain

@Suite("DiveHapticTracker")
struct DiveHapticTrackerTests {
    /// Drives the tracker through a depth profile and collects all events.
    private func run(_ depths: [Double], config: DiveHapticConfig = .default) -> [DiveHapticEvent] {
        var tracker = DiveHapticTracker(config: config)
        return depths.flatMap { tracker.update(depthMeters: $0) }
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
}
