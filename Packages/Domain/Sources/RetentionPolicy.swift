import Foundation

/// Caps for auto-cleaning old sessions off the **watch** (they stay on the phone
/// / in iCloud). Any cap of 0 is disabled; a session is pruned if it exceeds ANY
/// enabled cap.
public struct RetentionPolicy: Sendable, Equatable {
    public var maxDays: Int
    public var maxSessions: Int
    public var maxSizeBytes: Int

    public init(maxDays: Int = 0, maxSessions: Int = 0, maxSizeBytes: Int = 0) {
        self.maxDays = maxDays
        self.maxSessions = maxSessions
        self.maxSizeBytes = maxSizeBytes
    }

    /// Whether any cap is active (otherwise nothing is ever pruned).
    public var isActive: Bool { maxDays > 0 || maxSessions > 0 || maxSizeBytes > 0 }
}

/// A stored session considered for retention pruning.
public struct RetentionCandidate: Sendable, Equatable {
    public var id: UUID
    public var startTime: Date
    public var sizeBytes: Int
    /// Only sessions confirmed delivered to the phone may be pruned — the phone
    /// keeps the copy, so removing it from the watch loses nothing.
    public var isDelivered: Bool

    public init(id: UUID, startTime: Date, sizeBytes: Int, isDelivered: Bool) {
        self.id = id
        self.startTime = startTime
        self.sizeBytes = sizeBytes
        self.isDelivered = isDelivered
    }
}

/// Decides which sessions to remove from the watch under a retention policy.
///
/// Considering sessions newest-first, one is a prune target when it exceeds ANY
/// enabled cap — older than `maxDays`, beyond the newest `maxSessions`, or past
/// the cumulative `maxSizeBytes` budget — **and** it's confirmed delivered to the
/// phone. Undelivered sessions are **never** pruned (so nothing unsynced is lost),
/// though they still count toward the size/count budgets since they occupy the
/// watch too.
public func sessionsToPrune(
    _ sessions: [RetentionCandidate],
    policy: RetentionPolicy,
    now: Date = Date()
) -> [UUID] {
    guard policy.isActive else { return [] }
    let sorted = sessions.sorted { $0.startTime > $1.startTime } // newest first
    let dayCutoff = policy.maxDays > 0 ? now.addingTimeInterval(-Double(policy.maxDays) * 86_400) : nil
    var cumulativeBytes = 0
    var prune: [UUID] = []
    for (index, session) in sorted.enumerated() {
        cumulativeBytes += max(0, session.sizeBytes)
        let overDays = dayCutoff.map { session.startTime < $0 } ?? false
        let overCount = policy.maxSessions > 0 && index >= policy.maxSessions
        let overSize = policy.maxSizeBytes > 0 && cumulativeBytes > policy.maxSizeBytes
        if (overDays || overCount || overSize) && session.isDelivered {
            prune.append(session.id)
        }
    }
    return prune
}
