import Foundation
import SwiftData
import Testing
@testable import Persistence
import Domain

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

    @Test("round-trips a full DiveSession through domain→record→domain including samples and markers")
    func roundTripsDomainSession() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext

        let t0 = Date(timeIntervalSince1970: 0)
        let domainSession = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(3600),
            dives: [
                Dive(
                    startTime: t0.addingTimeInterval(10),
                    endTime: t0.addingTimeInterval(80),
                    maxDepthMeters: 8.3,
                    samples: [
                        DepthSample(timestamp: t0.addingTimeInterval(10), depthMeters: 0),
                        DepthSample(timestamp: t0.addingTimeInterval(40), depthMeters: 8.3),
                        DepthSample(timestamp: t0.addingTimeInterval(80), depthMeters: 0),
                    ]
                )
            ],
            markers: [
                EventMarker(timestamp: t0.addingTimeInterval(45), kind: .wildlife, text: "turtle")
            ],
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )

        let record = SessionRecord(from: domainSession)
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 1)
        let result = fetched[0].toDomain()

        #expect(result.id == domainSession.id)
        #expect(result.endTime == domainSession.endTime)
        #expect(result.location == GeoPoint(latitude: 20.5, longitude: -87.0))

        #expect(result.dives.count == 1)
        #expect(result.dives[0].maxDepthMeters == 8.3)
        #expect(result.dives[0].samples.count == 3)
        #expect(result.dives[0].samples[1].depthMeters == 8.3)

        #expect(result.markers.count == 1)
        #expect(result.markers[0].kind == .wildlife)
        #expect(result.markers[0].text == "turtle")
    }

    @Test("cascade-deletes dives and markers when the session is deleted")
    func cascadeDeletesChildren() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext

        let t0 = Date(timeIntervalSince1970: 0)
        let domainSession = DiveSession(
            startTime: t0,
            dives: [
                Dive(startTime: t0.addingTimeInterval(5), endTime: t0.addingTimeInterval(30), maxDepthMeters: 5)
            ],
            markers: [
                EventMarker(timestamp: t0.addingTimeInterval(10), kind: .note)
            ]
        )
        let record = SessionRecord(from: domainSession)
        context.insert(record)
        try context.save()

        context.delete(record)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<SessionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DiveRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MarkerRecord>()).isEmpty)
    }
}
