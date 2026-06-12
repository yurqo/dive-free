import Foundation
import Testing
@testable import Domain

@Suite("DiveSession summary")
struct DiveSessionSummaryTests {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func dive(start: TimeInterval, end: TimeInterval, depth: Double) -> Dive {
        Dive(
            startTime: epoch.addingTimeInterval(start),
            endTime: epoch.addingTimeInterval(end),
            maxDepthMeters: depth
        )
    }

    @Test("totalDuration is end - start, or 0 while in progress")
    func totalDuration() {
        let inProgress = DiveSession(startTime: epoch)
        #expect(inProgress.totalDuration == 0)

        let finished = DiveSession(startTime: epoch, endTime: epoch.addingTimeInterval(600))
        #expect(finished.totalDuration == 600)
    }

    @Test("averageSurfaceInterval is nil with fewer than two dives")
    func averageSurfaceIntervalNeedsTwoDives() {
        #expect(DiveSession(startTime: epoch).averageSurfaceInterval == nil)

        let single = DiveSession(startTime: epoch, dives: [dive(start: 0, end: 30, depth: 10)])
        #expect(single.averageSurfaceInterval == nil)
    }

    @Test("averageSurfaceInterval averages the gaps between consecutive dives")
    func averageSurfaceIntervalAveragesGaps() {
        // Dives: [0–30], [90–120], [240–270] → gaps of 60 and 120 → mean 90.
        let session = DiveSession(
            startTime: epoch,
            dives: [
                dive(start: 0, end: 30, depth: 10),
                dive(start: 90, end: 120, depth: 12),
                dive(start: 240, end: 270, depth: 8),
            ]
        )
        #expect(session.averageSurfaceInterval == 90)
    }

    @Test("averageSurfaceInterval orders dives by start before pairing")
    func averageSurfaceIntervalOrdersDives() {
        let ordered = DiveSession(
            startTime: epoch,
            dives: [dive(start: 0, end: 30, depth: 10), dive(start: 90, end: 120, depth: 12)]
        )
        let shuffled = DiveSession(
            startTime: epoch,
            dives: [dive(start: 90, end: 120, depth: 12), dive(start: 0, end: 30, depth: 10)]
        )
        #expect(shuffled.averageSurfaceInterval == ordered.averageSurfaceInterval)
        #expect(ordered.averageSurfaceInterval == 60)
    }

    @Test("markerCountsByKind groups markers by kind")
    func markerCounts() {
        let session = DiveSession(
            startTime: epoch,
            markers: [
                EventMarker(timestamp: epoch, kind: .wildlife),
                EventMarker(timestamp: epoch, kind: .wildlife),
                EventMarker(timestamp: epoch, kind: .note),
            ]
        )
        #expect(session.markerCountsByKind == [MarkerKind(.wildlife): 2, MarkerKind(.note): 1])
    }

    @Test("markerCountsByKind is empty when no markers were placed")
    func markerCountsEmpty() {
        #expect(DiveSession(startTime: epoch).markerCountsByKind.isEmpty)
    }
}
