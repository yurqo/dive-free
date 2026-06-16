import Foundation
import Testing
@testable import Domain

@Suite("DiveSession.segments")
struct SegmentTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func dive(_ from: TimeInterval, _ to: TimeInterval, depth: Double = 5) -> Dive {
        Dive(
            startTime: start.addingTimeInterval(from),
            endTime: start.addingTimeInterval(to),
            maxDepthMeters: depth
        )
    }

    private func session(dives: [Dive], end: TimeInterval) -> DiveSession {
        DiveSession(startTime: start, endTime: start.addingTimeInterval(end), dives: dives)
    }

    @Test("interleaves surface intervals before, between, and after dives")
    func interleaves() {
        let segs = session(dives: [dive(30, 90), dive(150, 200)], end: 240).segments
        // surface 0–30, dive 30–90, surface 90–150, dive 150–200, surface 200–240
        let kinds = segs.map(\.isDive)
        #expect(segs.count == 5)
        #expect(kinds == [false, true, false, true, false])
        #expect(segs[0].duration == 30)
        #expect(segs[1].duration == 60)
        #expect(segs[1].dive?.maxDepthMeters == 5)
    }

    @Test("a session with no dives is one surface segment spanning the session")
    func noDives() {
        let segs = session(dives: [], end: 120).segments
        #expect(segs.count == 1)
        #expect(segs[0].isDive == false)
        #expect(segs[0].duration == 120)
    }

    @Test("drops sub-second surface gaps between back-to-back dives")
    func dropsTinyGaps() {
        let segs = session(dives: [dive(0, 60), dive(60, 120)], end: 120).segments
        let allDives = segs.allSatisfy(\.isDive)
        #expect(segs.count == 2)
        #expect(allDives)
    }

    @Test("segment ids are sequential")
    func sequentialIDs() {
        let segs = session(dives: [dive(30, 90)], end: 120).segments
        let ids = segs.map(\.id)
        #expect(ids == Array(0..<segs.count))
    }
}
