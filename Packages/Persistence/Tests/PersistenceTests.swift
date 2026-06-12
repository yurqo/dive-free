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
        #expect(result.markers[0].kind == MarkerKind(.wildlife))
        #expect(result.markers[0].text == "turtle")
    }

    @Test("importSession stores a new session and is queryable")
    func importStoresSession() throws {
        let store = try DiveStore(inMemory: true)
        let importer = SessionImporter(context: store.container.mainContext)

        let session = DiveSession(startTime: Date(timeIntervalSince1970: 0))
        let inserted = try importer.importSession(session)

        #expect(inserted)
        let fetched = try store.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == session.id)
    }

    @Test("importSession deduplicates by id across re-deliveries")
    func importDeduplicates() throws {
        let store = try DiveStore(inMemory: true)
        let importer = SessionImporter(context: store.container.mainContext)

        let session = DiveSession(startTime: Date(timeIntervalSince1970: 0))
        #expect(try importer.importSession(session) == true)
        #expect(try importer.importSession(session) == false)  // same id again

        let fetched = try store.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 1)
    }

    @Test("importSession stores distinct sessions separately")
    func importStoresDistinct() throws {
        let store = try DiveStore(inMemory: true)
        let importer = SessionImporter(context: store.container.mainContext)

        #expect(try importer.importSession(DiveSession(startTime: Date(timeIntervalSince1970: 0))) == true)
        #expect(try importer.importSession(DiveSession(startTime: Date(timeIntervalSince1970: 100))) == true)

        let fetched = try store.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 2)
    }

    @Test("round-trips an empty session with no dives or markers")
    func roundTripsEmptySession() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext

        let session = DiveSession(startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 60))
        context.insert(SessionRecord(from: session))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(fetched.count == 1)
        let result = fetched[0].toDomain()
        #expect(result.dives.isEmpty)
        #expect(result.markers.isEmpty)
        #expect(result.endTime == session.endTime)
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
