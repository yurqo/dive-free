import Foundation
import Testing
import SwiftData
import Domain
@testable import Persistence

@MainActor struct NoteMutationTests {
    @Test func testOutOfOrderEditsPreserveIndependentFieldsAndDeletionWins() throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let marker = EventMarker(timestamp: Date(), kind: .note, text: "Original", audioFileName: "clip.m4a")
        let session = DiveSession(startTime: Date(), markers: [marker])
        let journal = NoteMutationStore(context: context)
        // Operations arrive before the session and in reverse timestamp order.
        let title = NoteMutation(sessionID: session.id, markerID: marker.id, date: Date(timeIntervalSince1970: 2), changes: ["title": "Ray"])
        let description = NoteMutation(sessionID: session.id, markerID: marker.id, date: Date(timeIntervalSince1970: 1), changes: ["text": "Near the reef"])
        try journal.receive(title); try journal.receive(description); try journal.receive(title)
        #expect(try journal.all().count == 2)
        try SessionImporter(context: context).importSession(session)
        let saved = try #require(context.fetch(FetchDescriptor<MarkerRecord>()).first)
        #expect(saved.title == "Ray"); #expect(saved.text == "Near the reef")
        try journal.receive(NoteMutation(sessionID: session.id, markerID: marker.id, changes: ["removeAudio": "clip.m4a"]))
        #expect(saved.audioFileName == nil); #expect(saved.audioData == nil)
        #expect(try journal.removedAudioNames().contains("clip.m4a"))
        try journal.receive(NoteMutation(sessionID: session.id, markerID: marker.id, changes: ["delete": "true"]))
        try journal.receive(NoteMutation(sessionID: session.id, markerID: marker.id, changes: ["title": "Late edit"]))
        #expect(try context.fetch(FetchDescriptor<MarkerRecord>()).isEmpty)
        #expect(try journal.all().allSatisfy { $0.changes["title"] == nil && $0.changes["text"] == nil })
    }

    @Test func testNoteMetadataRoundTripsAndOldPayloadDecodes() throws {
        let marker = EventMarker(timestamp: Date(), kind: .note, text: "Description", audioFileName: "voice.m4a", title: "Turtle", transcript: "Saw a turtle", summary: "Turtle sighting")
        let record = MarkerRecord(from: marker)
        #expect(record.toDomain() == marker)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any])
        object.removeValue(forKey: "title"); object.removeValue(forKey: "transcript"); object.removeValue(forKey: "summary")
        let legacy = try JSONDecoder().decode(EventMarker.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.title == nil); #expect(legacy.text == "Description"); #expect(legacy.audioFileName == "voice.m4a")
    }
}

@MainActor struct NoteMutationBackupTests {
    @Test func testBackupRetainsJournalAndDoesNotRestoreDeletedNotes() async throws {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let marker = EventMarker(timestamp: Date(), kind: .note, text: "Original", audioFileName: "clip.m4a")
        let session = DiveSession(startTime: Date(), markers: [marker])
        try SessionImporter(context: context).importSession(session)
        let saved = try #require(context.fetch(FetchDescriptor<MarkerRecord>()).first)
        let photo = PhotoRecord(assetIdentifier: "photo", session: saved.session, marker: saved)
        context.insert(photo); try context.save()
        try NoteMutationStore(context: context).save(marker: saved, changes: ["delete": "true", "removeAudio": "clip.m4a"])
        #expect(photo.marker == nil)
        #expect(try context.fetch(FetchDescriptor<PhotoRecord>()).count == 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try await BackupRestore(context: context).stageArchive(into: dir, options: BackupExportOptions())
        #expect(archive.noteMutations?.count == 1)
        let restored = try DiveStore(inMemory: true)
        _ = try BackupRestore(context: restored.container.mainContext).restore(fromStagingDirectory: dir)
        let records = try restored.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(records.count == 1)
        #expect(try restored.container.mainContext.fetch(FetchDescriptor<MarkerRecord>()).isEmpty)
        // Old session delivery must remain unable to resurrect the deleted note.
        let another = try DiveStore(inMemory: true)
        let journal = NoteMutationStore(context: another.container.mainContext)
        for edit in archive.noteMutations ?? [] { try journal.receive(edit) }
        try SessionImporter(context: another.container.mainContext).importSession(session)
        #expect(try another.container.mainContext.fetch(FetchDescriptor<MarkerRecord>()).isEmpty)
    }
}
