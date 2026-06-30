import Foundation
import SwiftData

/// A multi-day dive trip grouping sessions by date + location (#111). Auto-suggested
/// from the session log and user-editable (rename, notes). Optional/defaulted
/// attributes and an optional relationship keep it CloudKit-compatible and make
/// adding it a lightweight, additive migration (existing rows are unaffected).
@Model
public final class Trip {
    public var id: UUID = UUID()
    public var name: String = ""
    public var startDate: Date = Date()
    public var endDate: Date = Date()
    public var notes: String?
    public var createdAt: Date = Date()

    /// Deleting a trip just unlinks its sessions (they stay in the log).
    @Relationship(deleteRule: .nullify, inverse: \SessionRecord.trip)
    public var sessions: [SessionRecord]?

    public init(
        id: UUID = UUID(),
        name: String = "",
        startDate: Date = Date(),
        endDate: Date = Date(),
        notes: String? = nil,
        createdAt: Date = Date(),
        sessions: [SessionRecord] = []
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.createdAt = createdAt
        self.sessions = sessions
    }
}
