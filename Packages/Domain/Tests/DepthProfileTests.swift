import Foundation
import Testing
@testable import Domain

@Suite("Dive.depthProfile")
struct DepthProfileTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func dive(_ offsets: [(TimeInterval, Double)]) -> Dive {
        Dive(
            startTime: start,
            endTime: start.addingTimeInterval(offsets.map(\.0).max() ?? 0),
            maxDepthMeters: offsets.map(\.1).max() ?? 0,
            samples: offsets.map { DepthSample(timestamp: start.addingTimeInterval($0.0), depthMeters: $0.1) }
        )
    }

    @Test("expresses sample times as seconds from the dive start")
    func relativeTimes() {
        let profile = dive([(0, 0), (5, 4), (10, 8)]).depthProfile
        #expect(profile.map(\.secondsFromStart) == [0, 5, 10])
        #expect(profile.map(\.depthMeters) == [0, 4, 8])
    }

    @Test("orders points in time even if samples are unsorted")
    func ordersByTime() {
        let profile = dive([(10, 8), (0, 0), (5, 4)]).depthProfile
        #expect(profile.map(\.secondsFromStart) == [0, 5, 10])
    }

    @Test("assigns stable sequential ids in time order")
    func stableIds() {
        let profile = dive([(0, 0), (5, 4), (10, 8)]).depthProfile
        #expect(profile.map(\.id) == [0, 1, 2])
    }

    @Test("an empty dive yields no points")
    func emptyProfile() {
        #expect(dive([]).depthProfile.isEmpty)
    }

    @Test("interpolates depth linearly between bracketing samples")
    func interpolatesDepth() {
        let d = dive([(0, 0), (10, 8), (20, 4)])
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(5)) == 4)   // halfway 0→8
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(15)) == 6)  // halfway 8→4
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(10)) == 8)  // exact sample
    }

    @Test("interpolatedDepth returns nil outside the sample range")
    func interpolatesOutOfRange() {
        let d = dive([(0, 0), (10, 8)])
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(-1)) == nil)
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(11)) == nil)
    }

    @Test("interpolatedDepth on an empty dive is nil")
    func interpolatesEmpty() {
        #expect(dive([]).interpolatedDepth(at: start) == nil)
    }
}
