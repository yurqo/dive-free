import Foundation
import SwiftData
import Testing
@testable import Persistence
import Domain

@Suite("BackupRestore")
@MainActor
struct BackupRestoreTests {
    // MARK: - Fixtures

    /// A session with a spot + trip and a marker carrying a voice note.
    private func makeAnchoredSession(t0: Date) -> DiveSession {
        DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(3600),
            dives: [
                Dive(
                    startTime: t0.addingTimeInterval(10),
                    endTime: t0.addingTimeInterval(80),
                    maxDepthMeters: 12.5,
                    samples: [DepthSample(timestamp: t0.addingTimeInterval(40), depthMeters: 12.5)]
                )
            ],
            markers: [
                EventMarker(timestamp: t0.addingTimeInterval(45), kind: .wildlife, text: "turtle", audioFileName: "voice-1.m4a")
            ],
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
    }

    /// A located session with no spot/trip — restore must leave it spot-less (it does
    /// NOT run the proximity assigner; it faithfully reproduces the archived state).
    private func makeSpotlessSession(t0: Date) -> DiveSession {
        DiveSession(
            startTime: t0.addingTimeInterval(10_000),
            endTime: t0.addingTimeInterval(10_600),
            location: GeoPoint(latitude: 10.0, longitude: 10.0),
            locationName: "Far reef"
        )
    }

    /// Seeds a fresh in-memory store with the two sessions, a spot + trip linked to the
    /// anchored one, and returns the store plus the anchored/spotless session IDs.
    private func seedSourceStore() throws -> (store: DiveStore, anchoredID: UUID, spotlessID: UUID, spotID: UUID, tripID: UUID) {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let t0 = Date(timeIntervalSince1970: 0)

        let anchored = makeAnchoredSession(t0: t0)
        let spotless = makeSpotlessSession(t0: t0)
        let anchoredRecord = SessionRecord(from: anchored)
        let spotlessRecord = SessionRecord(from: spotless)
        context.insert(anchoredRecord)
        context.insert(spotlessRecord)

        let spot = Spot(name: "Blue Hole", centerLatitude: 20.5, centerLongitude: -87.0, notes: "deep")
        context.insert(spot)
        anchoredRecord.spot = spot

        let trip = Trip(name: "Yucatán 2026", startDate: t0, endDate: t0.addingTimeInterval(3600), notes: "week trip")
        context.insert(trip)
        anchoredRecord.trip = trip

        try context.save()
        return (store, anchored.id, spotless.id, spot.id, trip.id)
    }

    // MARK: - Round-trip

    @Test("export then restore recreates sessions, spot/trip links, and mirrors audio")
    func roundTrip() throws {
        let source = try seedSourceStore()

        // Export from the source store; supply fake bytes for the one referenced clip.
        let clip = Data("m4a-bytes".utf8)
        let exporter = BackupRestore(context: source.store.container.mainContext)
        let archive = try exporter.makeArchive(appVersion: "1.3.0", audioBytes: { name in
            name == "voice-1.m4a" ? clip : nil
        })

        #expect(archive.sessions.count == 2)
        #expect(archive.spots.count == 1)
        #expect(archive.trips.count == 1)
        #expect(archive.audio == ["voice-1.m4a": clip])
        #expect(archive.spots.first?.sessionIDs == [source.anchoredID])
        #expect(archive.trips.first?.sessionIDs == [source.anchoredID])

        // Restore into a FRESH store; record materializeAudio calls (returns true — it
        // wrote the clip — so audioRestored counts it).
        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        var materialized: [String: Data] = [:]
        let summary = try BackupRestore(context: context).restore(
            from: archive,
            materializeAudio: { name, data in materialized[name] = data; return true }
        )

        // Summary counts.
        #expect(summary.sessionsImported == 2)
        #expect(summary.sessionsSkipped == 0)
        #expect(summary.spotsCreated == 1)
        #expect(summary.spotsLinked == 1)
        #expect(summary.tripsCreated == 1)
        #expect(summary.tripsLinked == 1)
        #expect(summary.audioRestored == 1)

        // Audio was materialized to "disk".
        #expect(materialized == ["voice-1.m4a": clip])

        // Both sessions exist by id.
        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(sessions.count == 2)
        let ids = Set(sessions.map { $0.id })
        #expect(ids.contains(source.anchoredID))
        #expect(ids.contains(source.spotlessID))

        // The spot is recreated (same id) and linked to the anchored session.
        let anchored = sessions.first { $0.id == source.anchoredID }
        #expect(anchored?.spot?.id == source.spotID)
        #expect(anchored?.spot?.name == "Blue Hole")
        #expect(anchored?.spot?.notes == "deep")

        // The trip is recreated (same id) and linked to the anchored session.
        #expect(anchored?.trip?.id == source.tripID)
        #expect(anchored?.trip?.name == "Yucatán 2026")

        // The marker's audioData was mirrored from the archive.
        let mirroredMarker = (anchored?.markers ?? []).first { $0.audioFileName == "voice-1.m4a" }
        #expect(mirroredMarker?.audioData == clip)

        // The spotless located session stays spot-less: restore reproduces the archive
        // as-is and does not run the proximity assigner.
        let spotless = sessions.first { $0.id == source.spotlessID }
        #expect(spotless?.spot == nil)
    }

    // MARK: - Idempotent re-import

    @Test("restoring the same archive twice imports nothing the second time and creates no duplicates")
    func idempotentReimport() throws {
        let source = try seedSourceStore()
        let archive = try BackupRestore(context: source.store.container.mainContext)
            .makeArchive(audioBytes: { _ in Data("x".utf8) })

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let restorer = BackupRestore(context: context)

        let first = try restorer.restore(from: archive)
        #expect(first.sessionsImported == 2)

        let sessionsAfterFirst = try context.fetch(FetchDescriptor<SessionRecord>()).count
        let spotsAfterFirst = try context.fetch(FetchDescriptor<Spot>()).count
        let tripsAfterFirst = try context.fetch(FetchDescriptor<Trip>()).count

        let second = try restorer.restore(from: archive)
        // Nothing new imported; every session skipped as a duplicate.
        #expect(second.sessionsImported == 0)
        #expect(second.sessionsSkipped == archive.sessions.count)
        #expect(second.spotsCreated == 0)
        #expect(second.tripsCreated == 0)
        // Nothing new linked: spots/trips already existed and sessions were already
        // assigned, so the nil→set guard skips them. Audio wasn't materialized (default
        // no-op closure returns false).
        #expect(second.spotsLinked == 0)
        #expect(second.tripsLinked == 0)
        #expect(second.audioRestored == 0)

        // No duplicate models: counts unchanged.
        #expect(try context.fetch(FetchDescriptor<SessionRecord>()).count == sessionsAfterFirst)
        #expect(try context.fetch(FetchDescriptor<Spot>()).count == spotsAfterFirst)
        #expect(try context.fetch(FetchDescriptor<Trip>()).count == tripsAfterFirst)
    }

    // MARK: - Additive

    @Test("restore is additive — a pre-existing unrelated session survives")
    func additiveKeepsExisting() throws {
        let source = try seedSourceStore()
        let archive = try BackupRestore(context: source.store.container.mainContext)
            .makeArchive(audioBytes: { _ in nil })

        // Destination already has an unrelated session.
        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = DiveSession(startTime: Date(timeIntervalSince1970: 500_000))
        context.insert(SessionRecord(from: existing))
        try context.save()

        _ = try BackupRestore(context: context).restore(from: archive)

        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        // The two archived sessions plus the pre-existing one.
        #expect(sessions.count == 3)
        #expect(sessions.contains { $0.id == existing.id })
    }

    // MARK: - Preserves existing assignments

    @Test("restore does not clobber a session's existing spot assignment (only nil→set)")
    func preservesExistingSpotAssignment() throws {
        let source = try seedSourceStore()
        // Archive links the anchored session to spot A ("Blue Hole").
        let archive = try BackupRestore(context: source.store.container.mainContext)
            .makeArchive(audioBytes: { _ in nil })

        // On the target, the same session (same id) already exists linked to a DIFFERENT
        // spot B (a user re-assignment made after the backup).
        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = DiveSession(
            id: source.anchoredID,
            startTime: Date(timeIntervalSince1970: 0),
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
        let existingRecord = SessionRecord(from: existing)
        context.insert(existingRecord)
        let spotB = Spot(name: "Cenote Dos Ojos", centerLatitude: 20.3, centerLongitude: -87.4)
        context.insert(spotB)
        existingRecord.spot = spotB
        try context.save()

        let summary = try BackupRestore(context: context).restore(from: archive)

        // The session was a duplicate → not re-imported; its spot B is preserved, NOT
        // overwritten by the archive's spot A.
        #expect(summary.sessionsSkipped == 1)  // anchored already present
        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        let anchored = sessions.first { $0.id == source.anchoredID }
        #expect(anchored?.spot?.id == spotB.id)
        #expect(anchored?.spot?.name == "Cenote Dos Ojos")
        #expect(anchored?.spot?.id != source.spotID)

        // The archive's spot A is still created (upsert by id) but links nothing new.
        let spotA = sessions.compactMap { $0.spot }.first { $0.id == source.spotID }
        #expect(spotA == nil)  // no session points at the archived spot
        #expect(summary.spotsLinked == 0)
    }

    // MARK: - Tombstone

    @Test("a tombstoned session id is skipped on restore")
    func tombstonedSessionSkipped() throws {
        let source = try seedSourceStore()
        let archive = try BackupRestore(context: source.store.container.mainContext)
            .makeArchive(audioBytes: { _ in nil })

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let tombstoned: Set<UUID> = [source.anchoredID]

        let summary = try BackupRestore(context: context).restore(
            from: archive,
            isTombstoned: { tombstoned.contains($0) }
        )

        #expect(summary.sessionsImported == 1)
        #expect(summary.sessionsSkipped == 1)

        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(sessions.count == 1)
        // The kept one is the spotless session; the anchored (tombstoned) one is gone.
        #expect(sessions.first?.id == source.spotlessID)
        #expect(!sessions.contains { $0.id == source.anchoredID })

        // The spot's sessionIDs referenced the tombstoned session — it just isn't
        // linked (no crash), though the spot itself is still recreated from the archive.
        let anchoredAbsent = sessions.first { $0.id == source.anchoredID }
        #expect(anchoredAbsent == nil)
    }
}
