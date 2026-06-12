import Foundation
import Testing
@testable import Domain

@Suite("DiveSession.track")
struct TrackTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func session(_ points: [(TimeInterval, Double, Double)]) -> DiveSession {
        DiveSession(
            startTime: start,
            track: points.map { offset, lat, lon in
                TrackPoint(timestamp: start.addingTimeInterval(offset), location: GeoPoint(latitude: lat, longitude: lon))
            }
        )
    }

    @Test("interpolates surface position linearly between track points")
    func interpolates() {
        let s = session([(0, 0, 0), (10, 10, 20)])
        let mid = s.surfaceLocation(at: start.addingTimeInterval(5))
        #expect(mid == GeoPoint(latitude: 5, longitude: 10))
    }

    @Test("clamps to the endpoints outside the track range")
    func clamps() {
        let s = session([(0, 1, 1), (10, 2, 2)])
        #expect(s.surfaceLocation(at: start.addingTimeInterval(-5)) == GeoPoint(latitude: 1, longitude: 1))
        #expect(s.surfaceLocation(at: start.addingTimeInterval(99)) == GeoPoint(latitude: 2, longitude: 2))
    }

    @Test("surfaceLocation is nil with no track")
    func emptyTrack() {
        #expect(session([]).surfaceLocation(at: start) == nil)
    }

    @Test("decodes a payload that predates the track field (defaults to empty)")
    func lenientDecode() throws {
        // A JSON object with no "track" key, like an older app version produced.
        let json = """
        {"id":"\(UUID().uuidString)","startTime":0,"dives":[],"markers":[]}
        """
        let decoder = JSONDecoder()
        let session = try decoder.decode(DiveSession.self, from: Data(json.utf8))
        #expect(session.track.isEmpty)
        #expect(session.dives.isEmpty)
    }

    @Test("a session with a track survives a JSON round trip")
    func roundTrips() throws {
        let original = session([(0, 10, 20), (4, 11, 21)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiveSession.self, from: data)
        #expect(decoded == original)
        #expect(decoded.track.count == 2)
    }
}
