import Foundation
import Testing
@testable import Domain

@Suite("GeoClustering")
struct GeoClusteringTests {
    private func p(_ lat: Double, _ lon: Double) -> GeoPoint { GeoPoint(latitude: lat, longitude: lon) }

    @Test("groups nearby points and separates distant ones")
    func groupsByProximity() {
        let points = [p(0, 0), p(0.001, 0), p(5, 5)]
        let groups = GeoClustering.cluster(points, thresholdDegrees: 0.01)
        #expect(groups.count == 2)
        #expect(groups.contains { $0.sorted() == [0, 1] })
        #expect(groups.contains { $0 == [2] })
    }

    @Test("every point is its own cluster when threshold is zero")
    func zeroThreshold() {
        let groups = GeoClustering.cluster([p(0, 0), p(0, 0), p(1, 1)], thresholdDegrees: 0)
        #expect(groups.count == 3)
    }

    @Test("empty input yields no clusters")
    func empty() {
        #expect(GeoClustering.cluster([], thresholdDegrees: 1).isEmpty)
    }

    @Test("indices cover every input point exactly once")
    func partitions() {
        let points = (0..<10).map { p(Double($0) * 0.0001, 0) }
        let groups = GeoClustering.cluster(points, thresholdDegrees: 0.01)
        #expect(groups.flatMap { $0 }.sorted() == Array(0..<10))
    }
}
