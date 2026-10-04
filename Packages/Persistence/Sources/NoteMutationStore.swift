import Foundation
import SwiftData
import Domain

/// CloudKit edit journal. Independent records prevent CloudKit record-level
/// conflicts from losing simultaneous edits to different note fields.
@Model public final class NoteMutationRecord {
    public var id: UUID = UUID()
    public var payload: Data = Data()
    public init(_ mutation: NoteMutation) throws {
        id = mutation.id; payload = try JSONEncoder().encode(mutation)
    }
}

@MainActor public struct NoteMutationStore {
    public let context: ModelContext
    public init(context: ModelContext) { self.context = context }
    public func all() throws -> [NoteMutation] {
        try context.fetch(FetchDescriptor<NoteMutationRecord>()).compactMap {
            try? JSONDecoder().decode(NoteMutation.self, from: $0.payload)
        }
    }
    public func receive(_ mutation: NoteMutation) throws {
        if try !all().contains(where: { $0.id == mutation.id }) {
            context.insert(try NoteMutationRecord(mutation))
        }
        try reconcile()
    }
    public func save(marker: MarkerRecord, changes: [String: String]) throws {
        guard let sessionID = marker.session?.id, !changes.isEmpty else { return }
        try receive(NoteMutation(sessionID: sessionID, markerID: marker.id, changes: changes))
    }
    public func removedAudioNames() throws -> Set<String> {
        Set(try all().compactMap { $0.changes["removeAudio"] }.filter { !$0.isEmpty })
    }
    public func reconcile() throws {
        let operations = try all()
        let groups = Dictionary(grouping: operations, by: \.markerID)
        for marker in try context.fetch(FetchDescriptor<MarkerRecord>()) {
            guard let edits = groups[marker.id]?.filter({ $0.sessionID == marker.session?.id }), !edits.isEmpty else { continue }
            let fields = NoteMutation.merged(edits)
            if fields["delete"] != nil {
                // Explicit unlink also makes the behaviour clear before save.
                for photo in marker.photos ?? [] { photo.marker = nil }
                context.delete(marker)
                continue
            }
            func optional(_ value: String) -> String? { value.isEmpty ? nil : value }
            if let v = fields["title"], marker.title != optional(v) { marker.title = optional(v) }
            if let v = fields["text"], marker.text != optional(v) { marker.text = optional(v) }
            if let v = fields["transcript"], marker.transcript != optional(v) { marker.transcript = optional(v) }
            if let v = fields["summary"], marker.summary != optional(v) { marker.summary = optional(v) }
            if let v = fields["kind"], marker.kind != v { marker.kind = v }
            if let v = fields["emoji"], marker.emoji != v { marker.emoji = v }
            if let v = fields["label"], marker.label != v { marker.label = v }
            if fields["removeAudio"] != nil {
                if marker.audioFileName != nil { marker.audioFileName = nil }
                if marker.audioData != nil { marker.audioData = nil }
            }
        }
        // Deletion keeps only the tombstone and removed-audio names. Do not retain
        // inaccessible historical transcripts/descriptions after the user deletes a note.
        let deleted = Set(operations.filter { $0.changes["delete"] != nil }.map(\.markerID))
        if !deleted.isEmpty {
            for record in try context.fetch(FetchDescriptor<NoteMutationRecord>()) {
                guard var operation = try? JSONDecoder().decode(NoteMutation.self, from: record.payload),
                      deleted.contains(operation.markerID) else { continue }
                let remaining = operation.changes.filter { $0.key == "delete" || $0.key == "removeAudio" }
                if remaining.isEmpty { context.delete(record) }
                else if remaining != operation.changes {
                    operation.changes = remaining
                    record.payload = try JSONEncoder().encode(operation)
                }
            }
        }
        if context.hasChanges { try context.save() }
    }
}
