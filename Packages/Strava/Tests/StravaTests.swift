import Foundation
import Testing
import Domain
@testable import Strava

@Suite("Strava")
struct StravaTests {
    @Test("maps a session into an activity with elapsed time and summary")
    func mapsSessionToActivity() {
        let session = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1800),
            dives: [
                Dive(startTime: Date(timeIntervalSince1970: 10), endTime: Date(timeIntervalSince1970: 40), maxDepthMeters: 14.2)
            ]
        )

        let activity = StravaActivity(session: session)
        #expect(activity.elapsedSeconds == 1800)
        #expect(activity.description?.contains("1 dives") == true)
        #expect(activity.description?.contains("14.2") == true)
    }

    @Test("uploading without a token throws notAuthenticated")
    func requiresToken() async {
        let client = StravaClient(accessToken: nil)
        await #expect(throws: StravaError.self) {
            try await client.upload(StravaActivity(name: "x", startDate: Date(), elapsedSeconds: 0))
        }
    }
}
