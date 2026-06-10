import Foundation
import SwiftData
import Testing
@testable import Persistence

@Suite("Persistence")
@MainActor
struct PersistenceTests {
    @Test("stores and reads back a session with its dives")
    func roundTripsSession() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext

        let session = SessionRecord(startTime: Date(timeIntervalSince1970: 0))
        session.dives = [
            DiveRecord(
                startTime: Date(timeIntervalSince1970: 10),
                endTime: Date(timeIntervalSince1970: 40),
                maxDepthMeters: 12.5
            )
        ]
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.dives.count == 1)
        #expect(fetched.first?.toDomain().maxDepthMeters == 12.5)
    }
}
