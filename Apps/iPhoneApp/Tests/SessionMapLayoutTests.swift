import Foundation
import CoreGraphics
import Testing
import Domain

struct SessionMapLayoutTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func point(_ id: String, _ kind: SessionMapPoint.Kind, time: Double = 0) -> SessionMapPoint {
        SessionMapPoint(id: id, geo: GeoPoint(latitude: 1, longitude: 2),
                        timestamp: Date(timeIntervalSince1970: time), kind: kind)
    }

    @Test func onlyMatchingDiveBoundariesReplaceTheCount() {
        let down = point("down-a", .submersion(diveID: a, number: 3))
        let up = point("up-a", .surfacing(diveID: a, number: 3))
        let otherUp = point("up-b", .surfacing(diveID: b, number: 4))
        let note = point("note", .marker(emoji: "🐠", label: "Wildlife"))
        #expect(SessionMapCluster(members: [down, up]).presentation == .divePair(number: 3))
        #expect(SessionMapCluster(members: [up, down]).presentation == .divePair(number: 3))
        #expect(SessionMapCluster(members: [down, otherUp]).presentation == .count(2))
        #expect(SessionMapCluster(members: [down, note]).presentation == .count(2))
        #expect(SessionMapCluster(members: [down, up, note]).presentation == .count(3))
    }

    @Test func distantBoundariesStaySeparateAndCollocatedDifferentDivesStayCounted() {
        let points = [point("a-start", .submersion(diveID: a, number: 1)),
                      point("a-end", .surfacing(diveID: a, number: 1)),
                      point("b-start", .submersion(diveID: b, number: 2)),
                      point("b-end", .surfacing(diveID: b, number: 2))]
        let projected = ["a-start": CGPoint(x: 20, y: 100), "a-end": CGPoint(x: 150, y: 100),
                         "b-start": CGPoint(x: 150, y: 100), "b-end": CGPoint(x: 280, y: 100)]
        let clusters = SessionMapLayout.clusters(points: points, projected: projected, fallbackLatitudeSpan: 1)
        #expect(clusters.count == 3)
        #expect(clusters.map(\.presentation) == [.point, .count(2), .point])
        #expect(clusters.flatMap(\.members).map(\.id).sorted() == points.map(\.id).sorted())
    }

    @Test func overlappingChainsAreFullyGroupedAndStableUnderInputReordering() {
        let points = (0..<4).map { point("note-\($0)", .marker(emoji: "📝", label: "Note"), time: Double($0)) }
        let projected = Dictionary(uniqueKeysWithValues: points.enumerated().map {
            ($0.element.id, CGPoint(x: CGFloat($0.offset) * 40, y: 100))
        })
        let first = SessionMapLayout.clusters(points: points, projected: projected, fallbackLatitudeSpan: 1)
        let reversed = SessionMapLayout.clusters(points: points.reversed(), projected: projected, fallbackLatitudeSpan: 1)
        #expect(first.count == 1)
        #expect(first[0].id == reversed[0].id)
        #expect(first[0].members.map(\.id) == points.map(\.id))
    }

    @Test func expansionFitsNearViewportEdgesWithDistinctTouchTargets() {
        for count in 2...16 {
            let ids = (0..<count).map(String.init)
            let bounds = CGRect(x: 16, y: 100, width: 288, height: 350)
            for centre in [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 800)] {
                let expanded = SessionMapLayout.expandedPositions(ids: ids, centre: centre, bounds: bounds, selectedID: nil)
                #expect(expanded.count == count)
                for position in expanded.values {
                    #expect(position.x - 22 >= bounds.minX && position.x + 22 <= bounds.maxX)
                    #expect(position.y - 22 >= bounds.minY && position.y + 22 <= bounds.maxY)
                    for other in expanded.values where other != position {
                        #expect(hypot(position.x - other.x, position.y - other.y) >= 44)
                    }
                }
            }
        }
    }

    @Test func selectingAnyMemberOfALargeClusterBringsItIntoTheFan() {
        let ids = (0..<100).map(String.init)
        let bounds = CGRect(x: 16, y: 100, width: 288, height: 200)
        let expanded = SessionMapLayout.expandedPositions(ids: ids, centre: CGPoint(x: 150, y: 150),
                                                         bounds: bounds, selectedID: "99")
        #expect(expanded.count < ids.count)
        #expect(expanded["99"] != nil)
        #expect(Set(expanded.keys).isSubset(of: Set(ids)))
    }

    @Test func fallbackDoesNotDropAnyPointsBeforeMapProjectionIsReady() {
        let points = [point("one", .submersion(diveID: a, number: 1)), point("two", .surfacing(diveID: a, number: 1))]
        let clusters = SessionMapLayout.clusters(points: points, projected: [:], fallbackLatitudeSpan: 1)
        #expect(clusters.flatMap(\.members).map(\.id) == ["one", "two"])
        #expect(clusters[0].presentation == .divePair(number: 1))
    }
}
