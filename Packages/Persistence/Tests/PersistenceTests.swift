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
        #expect(fetched.first?.dives?.count == 1)
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
                EventMarker(timestamp: t0.addingTimeInterval(45), kind: .wildlife, text: "turtle", audioFileName: "voice-turtle.m4a")
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
        // Regression: the marker→voice-note link must survive persistence + sync.
        #expect(result.markers[0].audioFileName == "voice-turtle.m4a")
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

    // MARK: - Voice-note audio backfill (1c)

    @Test("importSession backfills audioData for a marker whose clip file already arrived")
    func importBackfillsAudioData() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext

        let clip = Data("m4a-bytes".utf8)
        // Mirror closure: back the marker whose clip file is "present" (voice-1.m4a)
        // and leave the other alone — the app injects VoiceNoteStore.mirrorAudioData.
        let importer = SessionImporter(
            context: context,
            mirrorAudio: { marker in
                guard marker.audioData == nil, marker.audioFileName == "voice-1.m4a" else { return false }
                marker.audioData = clip
                return true
            }
        )

        let t0 = Date(timeIntervalSince1970: 0)
        let session = DiveSession(
            startTime: t0,
            markers: [
                EventMarker(timestamp: t0.addingTimeInterval(5), kind: .note, audioFileName: "voice-1.m4a"),
                EventMarker(timestamp: t0.addingTimeInterval(6), kind: .note, audioFileName: "missing.m4a"),
            ]
        )
        #expect(try importer.importSession(session))

        let markers = try context.fetch(FetchDescriptor<MarkerRecord>())
        // The marker whose file was present gets its bytes mirrored (for CloudKit).
        #expect(markers.first { $0.audioFileName == "voice-1.m4a" }?.audioData == clip)
        // The one whose file isn't on disk yet stays nil — a later path backfills it.
        #expect(markers.first { $0.audioFileName == "missing.m4a" }?.audioData == nil)
    }

    @Test("importSession leaves audioData nil when no provider is supplied")
    func importSkipsAudioBackfillByDefault() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let importer = SessionImporter(context: context)

        let session = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            markers: [EventMarker(timestamp: Date(timeIntervalSince1970: 1), kind: .note, audioFileName: "voice-1.m4a")]
        )
        #expect(try importer.importSession(session))

        let markers = try context.fetch(FetchDescriptor<MarkerRecord>())
        #expect(markers.first?.audioData == nil)
    }

    // MARK: - Orphan voice-note sweep (1a)

    @Test("the sweep deletes old unreferenced voice-note files and keeps referenced ones")
    func sweepsOrphanVoiceNotes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNoteSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("keep.m4a"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("orphan.m4a"))
        // Age the orphan past the guard so the sweep is allowed to delete it.
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("orphan.m4a").path)

        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let t0 = Date(timeIntervalSince1970: 0)
        context.insert(SessionRecord(from: DiveSession(
            startTime: t0,
            markers: [EventMarker(timestamp: t0.addingTimeInterval(1), kind: .note, audioFileName: "keep.m4a")]
        )))
        try context.save()

        let removed = try await VoiceNoteSweeper(context: context).sweep(directory: dir)
        #expect(removed == ["orphan.m4a"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.m4a").path))
    }

    @Test("deleteOrphans keeps referenced names and reports the removed ones")
    func deleteOrphansPure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNoteSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.m4a", "b.m4a", "c.m4a"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        // Age all files so the minimum-age guard doesn't protect them.
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        for name in ["a.m4a", "b.m4a", "c.m4a"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(name).path)
        }

        let removed = VoiceNoteSweeper.deleteOrphans(in: dir, referenced: ["b.m4a"])
        #expect(Set(removed) == ["a.m4a", "c.m4a"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.m4a").path))
    }

    @Test("a fresh unreferenced file is NOT swept (in-flight session payload race)")
    func keepsFreshOrphan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNoteSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Just written now (default modification date) — younger than the guard.
        try Data("x".utf8).write(to: dir.appendingPathComponent("fresh.m4a"))

        let removed = VoiceNoteSweeper.deleteOrphans(in: dir, referenced: [])
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fresh.m4a").path))
    }

    @Test("an old unreferenced file IS swept")
    func deletesOldOrphan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNoteSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("old.m4a"))
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("old.m4a").path)

        let removed = VoiceNoteSweeper.deleteOrphans(in: dir, referenced: [])
        #expect(removed == ["old.m4a"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.m4a").path))
    }

    @Test("an old referenced file is kept")
    func keepsOldReferenced() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNoteSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("ref.m4a"))
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("ref.m4a").path)

        let removed = VoiceNoteSweeper.deleteOrphans(in: dir, referenced: ["ref.m4a"])
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ref.m4a").path))
    }
}
