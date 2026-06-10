import Foundation
import Testing
import Domain
@testable import Sync

@Suite("SyncManager")
struct SyncManagerTests {
    @Test("a session survives a JSON encode/decode round trip")
    func sessionRoundTrips() throws {
        let original = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 600),
            dives: [
                Dive(
                    startTime: Date(timeIntervalSince1970: 10),
                    endTime: Date(timeIntervalSince1970: 40),
                    maxDepthMeters: 9.0
                )
            ],
            location: GeoPoint(latitude: 40.0, longitude: -70.0)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiveSession.self, from: data)

        #expect(decoded == original)
    }
}
