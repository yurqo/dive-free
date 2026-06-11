import Foundation
import SwiftData
import Domain

/// Persists `DiveSession`s arriving from the watch into the iPhone's SwiftData
/// container, deduplicating by `DiveSession.id` so re-deliveries (the sync layer
/// retries until confirmed) never create duplicate records.
///
/// `@MainActor` because it writes through the container's main `ModelContext`,
/// which is main-actor isolated — callers hop here from the sync callback.
@MainActor
public struct SessionImporter {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Inserts the session unless one with the same id already exists.
    /// Returns `true` if a new record was stored, `false` if it was a duplicate.
    @discardableResult
    public func importSession(_ session: DiveSession) throws -> Bool {
        let id = session.id
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return false }

        context.insert(SessionRecord(from: session))
        try context.save()
        return true
    }
}
