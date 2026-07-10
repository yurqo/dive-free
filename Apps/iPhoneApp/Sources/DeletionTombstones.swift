import Foundation

/// Phone-side record of recently-deleted session ids, so a late WatchConnectivity
/// re-delivery can't resurrect a session the user removed. `transferUserInfo` is
/// FIFO, but a retry after a failed transfer — or a payload requeued across a
/// relaunch — can land *after* its deletion message; `SessionImporter` consults
/// this list and skips a tombstoned id.
///
/// Bounded to the most recent `limit` ids (oldest trimmed): only recent
/// re-deliveries are a real risk, so the list needn't grow without end. Written by
/// both phone delete paths (the list swipe-delete and the watch-deletion mirror).
/// CloudKit re-sync of a deleted record is NOT covered here — CloudKit handles its
/// own tombstoning; this is only the WCSession path.
enum DeletionTombstones {
    static let key = "deletedSessionTombstones"
    private static let limit = 200

    /// Records `id` as deleted, moving it to newest and trimming the oldest beyond
    /// the cap. Idempotent (a repeat delete just refreshes its position).
    static func record(_ id: UUID, defaults: UserDefaults = .standard) {
        let value = id.uuidString
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == value }
        ids.append(value)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        defaults.set(ids, forKey: key)
    }

    /// Whether `id` has been tombstoned (deleted) on this device.
    static func contains(_ id: UUID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    /// Clears `id`'s tombstone so a subsequent import is no longer rejected. Called
    /// when the watch *explicitly* re-sends a session (see `SyncManager.resyncKey`):
    /// a deliberate "Re-send to iPhone" must override an earlier accidental
    /// swipe-delete, otherwise the tombstone would silently drop the recovery — and
    /// watch retention could then prune the only surviving copy. No-op when the id
    /// isn't tombstoned.
    static func remove(_ id: UUID, defaults: UserDefaults = .standard) {
        let value = id.uuidString
        var ids = defaults.stringArray(forKey: key) ?? []
        guard ids.contains(value) else { return }
        ids.removeAll { $0 == value }
        defaults.set(ids, forKey: key)
    }
}
