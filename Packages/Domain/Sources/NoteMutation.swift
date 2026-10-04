import Foundation

/// Immutable, field-level operation. Empty strings explicitly clear optional text.
/// Audio removal and deletion are permanent for a marker's original recording.
public struct NoteMutation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var markerID: UUID
    public var date: Date
    public var changes: [String: String]
    public init(id: UUID = UUID(), sessionID: UUID, markerID: UUID, date: Date = Date(), changes: [String: String]) {
        self.id = id; self.sessionID = sessionID; self.markerID = markerID
        self.date = date; self.changes = changes
    }
    public static func ordered(_ a: Self, _ b: Self) -> Bool {
        a.date == b.date ? a.id.uuidString < b.id.uuidString : a.date < b.date
    }
    public static func merged(_ operations: [Self]) -> [String: String] {
        var result: [String: String] = [:]
        for operation in operations.sorted(by: ordered) {
            result.merge(operation.changes) { _, latest in latest }
        }
        return result
    }
}
