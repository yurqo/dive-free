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
    /// Mirrors a just-imported marker's on-disk clip bytes into its CloudKit-synced
    /// `audioData` when the clip file arrived (over a separate WatchConnectivity
    /// `transferFile`) *before* this session payload created the marker. Returns
    /// whether it changed the marker. Defaults to a no-op so callers that don't
    /// store voice notes (or tests) needn't supply it.
    private let mirrorAudio: @MainActor (MarkerRecord) -> Bool
    /// Returns whether a session id has been deleted on this device and must not be
    /// re-imported. Injected by the app (backed by a UserDefaults tombstone list) so
    /// Persistence stays UserDefaults-free and testable; defaults to a no-op so
    /// callers that don't tombstone (or tests) needn't supply it.
    private let isTombstoned: @MainActor (UUID) -> Bool

    public init(
        context: ModelContext,
        mirrorAudio: @MainActor @escaping (MarkerRecord) -> Bool = { _ in false },
        isTombstoned: @MainActor @escaping (UUID) -> Bool = { _ in false }
    ) {
        self.context = context
        self.mirrorAudio = mirrorAudio
        self.isTombstoned = isTombstoned
    }

    /// Inserts the session unless one with the same id already exists.
    /// Returns `true` if a new record was stored, `false` if it was a duplicate.
    @discardableResult
    public func importSession(_ session: DiveSession) throws -> Bool {
        let id = session.id
        // Skip a session the user already deleted on this device: a late WCSession
        // re-delivery (a retry/relaunch requeued after the deletion) would otherwise
        // resurrect it. CloudKit deletes are out of scope — CloudKit handles its own.
        guard !isTombstoned(id) else { return false }
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return false }

        let record = SessionRecord(from: session)
        context.insert(record)
        // Backfill audio bytes for any marker whose clip file already landed, so
        // the recording mirrors to other devices via CloudKit without waiting for
        // the detail view's reconcile (handles the file-before-session race). A
        // fresh SessionRecord(from:) never carries audioData, so every marker is a
        // candidate; `mirrorAudio` no-ops when the clip file isn't on disk yet.
        for marker in (record.markers ?? []) {
            _ = mirrorAudio(marker)
        }
        try context.save()
        return true
    }
}
