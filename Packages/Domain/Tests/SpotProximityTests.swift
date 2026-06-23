import Foundation
import Testing
@testable import Domain

@Suite("SpotProximity")
struct SpotProximityTests {
    // ~0.001° latitude ≈ 111 m.
    private func point(_ lat: Double, _ lon: Double) -> GeoPoint { GeoPoint(latitude: lat, longitude: lon) }

    @Test("joins the nearest candidate within the radius")
    func nearestWithinRadius() {
        let candidates = [point(0, 0.01), point(0, 0.0005), point(0, 0.02)] // 2nd is ~55 m away
        #expect(SpotProximity.nearestIndex(to: point(0, 0), among: candidates, withinMeters: 250) == 1)
    }

    @Test("returns nil when nothing is within the radius")
    func nothingClose() {
        let candidates = [point(0, 0.01), point(0, 0.02)] // ~1.1 km, ~2.2 km
        #expect(SpotProximity.nearestIndex(to: point(0, 0), among: candidates, withinMeters: 250) == nil)
        #expect(SpotProximity.nearestIndex(to: point(0, 0), among: [], withinMeters: 250) == nil)
    }

    @Test("center is the centroid of the points, nil when empty")
    func centroid() {
        let center = SpotProximity.center(of: [point(0, 0), point(2, 4)])
        #expect(center == GeoPoint(latitude: 1, longitude: 2))
        #expect(SpotProximity.center(of: []) == nil)
    }
}
