import Foundation
import SwiftData
import Testing
import Domain
@testable import Persistence

@MainActor
@Suite("SpotAssigner")
struct SpotAssignerTests {
    // Keep the DiveStore alive for the test's duration — the ModelContext doesn't
    // strongly retain its container, so a discarded store would dangle.
    @discardableResult
    private func session(_ ctx: ModelContext, lat: Double?, lon: Double?, name: String? = nil, t: TimeInterval = 0) -> SessionRecord {
        let record = SessionRecord(startTime: Date(timeIntervalSince1970: t), latitude: lat, longitude: lon, locationName: name)
        ctx.insert(record)
        return record
    }

    @Test("creates a new spot named from the area for a located session")
    func newSpot() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let record = session(ctx, lat: 20.0, lon: -87.0, name: "Cancún")
        try ctx.save()
        #expect(try SpotAssigner(context: ctx).assignUnassignedSessions() == 1)
        #expect(record.spot?.name == "Cancún")
        #expect(try ctx.fetch(FetchDescriptor<Spot>()).count == 1)
    }

    @Test("nearby sessions share one spot; the center is recomputed")
    func nearbyShareSpot() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let a = session(ctx, lat: 0, lon: 0, name: "Reef", t: 0)
        let b = session(ctx, lat: 0, lon: 0.001, name: "Reef", t: 100) // ~111 m east
        try ctx.save()
        try SpotAssigner(context: ctx, radiusMeters: 250).assignUnassignedSessions()
        #expect(a.spot != nil)
        #expect(a.spot === b.spot)
        #expect(try ctx.fetch(FetchDescriptor<Spot>()).count == 1)
        #expect(abs((a.spot?.centerLongitude ?? 0) - 0.0005) < 1e-9) // mean of 0 and 0.001
    }

    @Test("far-apart sessions get separate spots")
    func farApart() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        session(ctx, lat: 0, lon: 0, t: 0)
        session(ctx, lat: 10, lon: 10, t: 100)
        try ctx.save()
        try SpotAssigner(context: ctx, radiusMeters: 250).assignUnassignedSessions()
        #expect(try ctx.fetch(FetchDescriptor<Spot>()).count == 2)
    }

    @Test("idempotent: a second run assigns nothing")
    func idempotent() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        session(ctx, lat: 0, lon: 0)
        try ctx.save()
        let assigner = SpotAssigner(context: ctx)
        #expect(try assigner.assignUnassignedSessions() == 1)
        #expect(try assigner.assignUnassignedSessions() == 0)
    }

    @Test("merge moves sessions + photos into the target and deletes the source")
    func mergeSpots() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let target = Spot(name: "Target", centerLatitude: 0, centerLongitude: 0)
        let source = Spot(name: "Source", centerLatitude: 1, centerLongitude: 1)
        ctx.insert(target)
        ctx.insert(source)
        let moved = session(ctx, lat: 1, lon: 1)
        moved.spot = source
        let photo = PhotoRecord(assetIdentifier: "x", spot: source)
        ctx.insert(photo)
        try ctx.save()

        try SpotAssigner(context: ctx).merge(source, into: target)
        #expect(try ctx.fetch(FetchDescriptor<Spot>()).count == 1)
        #expect(moved.spot === target)
        #expect(photo.spot === target)
        #expect(target.sessions.count == 1)
        #expect(target.photos.count == 1)
    }

    @Test("reassign moves a session to another spot, recentering both")
    func reassignSession() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let a = Spot(name: "A", centerLatitude: 0, centerLongitude: 0)
        let b = Spot(name: "B", centerLatitude: 5, centerLongitude: 5)
        ctx.insert(a)
        ctx.insert(b)
        let moved = session(ctx, lat: 0, lon: 0)
        moved.spot = a
        try ctx.save()

        try SpotAssigner(context: ctx).reassign(moved, to: b)
        #expect(moved.spot === b)
        #expect(a.sessions.isEmpty)
        #expect(b.sessions.count == 1)
    }

    @Test("a session without a location is skipped")
    func noLocation() throws {
        let store = try DiveStore(inMemory: true)
        let ctx = store.container.mainContext
        let record = session(ctx, lat: nil, lon: nil)
        try ctx.save()
        #expect(try SpotAssigner(context: ctx).assignUnassignedSessions() == 0)
        #expect(record.spot == nil)
        #expect(try ctx.fetch(FetchDescriptor<Spot>()).isEmpty)
    }
}
