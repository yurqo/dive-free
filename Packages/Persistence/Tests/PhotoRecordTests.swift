import Foundation
import SwiftData
import Testing
@testable import Persistence

@MainActor
@Suite("PhotoRecord")
struct PhotoRecordTests {
    @Test("a session's photos cascade-delete with the session")
    func cascade() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let session = SessionRecord(startTime: Date(timeIntervalSince1970: 0))
        ctx.insert(session)
        ctx.insert(PhotoRecord(fileName: "a.jpg", session: session))
        ctx.insert(PhotoRecord(fileName: "b.jpg", session: session))
        try ctx.save()
        #expect(session.photos.count == 2)
        #expect(try ctx.fetch(FetchDescriptor<PhotoRecord>()).count == 2)

        ctx.delete(session)
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<PhotoRecord>()).isEmpty)
    }

    @Test("a photo can link directly to a spot (forward-compatible with #107)")
    func spotLink() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let spot = Spot(name: "Reef", centerLatitude: 0, centerLongitude: 0)
        ctx.insert(spot)
        let photo = PhotoRecord(fileName: "c.jpg", spot: spot)
        ctx.insert(photo)
        try ctx.save()
        #expect(spot.photos.count == 1)
        #expect(photo.spot === spot)
    }
}
