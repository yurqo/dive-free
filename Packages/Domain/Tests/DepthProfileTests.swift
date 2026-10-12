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

    @Test("chart boundaries reach zero without modifying stored measurements")
    func chartSurfaceBoundaries() {
        let original = dive([(0, 0.7), (5, 4), (10, 0.5)])
        let plotted = original.chartDepthSamples
        #expect(plotted.first?.depthMeters == 0)
        #expect(plotted.last?.depthMeters == 0)
        #expect(plotted.first?.timestamp == original.startTime)
        #expect(plotted.last?.timestamp == original.endTime)
        #expect(Array(plotted.dropFirst().dropLast()) == original.samples)
        #expect(original.samples.map(\.depthMeters) == [0.7, 4, 0.5])
    }

    @Test("session surface intervals before, between and after dives plot at zero")
    func wholeSessionSurfaceBaseline() {
        let first = dive([(0, 0), (5, 4), (10, 0)])
        let secondStart = start.addingTimeInterval(40)
        let second = Dive(startTime: secondStart, endTime: secondStart.addingTimeInterval(10), maxDepthMeters: 3,
            samples: [.init(timestamp: secondStart, depthMeters: 0),
                      .init(timestamp: secondStart.addingTimeInterval(5), depthMeters: 3),
                      .init(timestamp: secondStart.addingTimeInterval(10), depthMeters: 0)])
        let session = DiveSession(startTime: start.addingTimeInterval(-10), endTime: start.addingTimeInterval(70), dives: [second, first])
        let plotted = session.chartDepthSamples
        #expect(plotted.first?.timestamp == session.startTime)
        #expect(plotted.last?.timestamp == session.endTime)
        #expect(plotted.first?.depthMeters == 0 && plotted.last?.depthMeters == 0)
        let gap = plotted.filter { $0.timestamp >= first.endTime && $0.timestamp <= second.startTime }
        #expect(gap.map(\.depthMeters) == [0, 0])
        #expect(gap.map(\.timestamp) == [first.endTime, second.startTime])
    }

    @Test("chart profiles do not invent depth for recordings without a depth sensor")
    func noSyntheticDepthWithoutReadings() {
        #expect(dive([]).chartDepthSamples.isEmpty)
        #expect(DiveSession(startTime: start, dives: [dive([])]).chartDepthSamples.isEmpty)
    }

    @Test("interpolates depth linearly between bracketing samples")
    func interpolatesDepth() {
        let d = dive([(0, 0), (10, 8), (20, 4)])
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(5)) == 4)   // halfway 0→8
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(15)) == 6)  // halfway 8→4
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(10)) == 8)  // exact sample
    }

    @Test("interpolatedDepth clamps to the first/last sample outside the range")
    func interpolatesOutOfRange() {
        // Unified policy (#102): clamp to the ends so a marker inside the dive
        // window always lands, rather than returning nil just outside the samples.
        let d = dive([(0, 0), (10, 8)])
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(-1)) == 0)
        #expect(d.interpolatedDepth(at: start.addingTimeInterval(11)) == 8)
    }

    @Test("interpolatedDepth on an empty dive is nil")
    func interpolatesEmpty() {
        #expect(dive([]).interpolatedDepth(at: start) == nil)
    }
}
