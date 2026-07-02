import Foundation
import Testing
@testable import Domain

@Suite("RetentionPolicy")
struct RetentionPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000_000)

    /// Builds candidates newest→oldest, each `dayGap` days apart, all delivered.
    private func candidates(count: Int, dayGap: Double = 1, sizeBytes: Int = 1_000, delivered: Bool = true) -> [RetentionCandidate] {
        (0..<count).map { i in
            RetentionCandidate(
                id: UUID(),
                startTime: t0.addingTimeInterval(-Double(i) * dayGap * 86_400),
                sizeBytes: sizeBytes,
                isDelivered: delivered
            )
        }
    }

    @Test("an inactive policy prunes nothing")
    func inactivePolicy() {
        let c = candidates(count: 10)
        #expect(sessionsToPrune(c, policy: RetentionPolicy(), now: t0).isEmpty)
    }

    @Test("undelivered sessions are never pruned, even when over every cap")
    func neverPrunesUndelivered() {
        let c = candidates(count: 10, dayGap: 100, delivered: false)
        let policy = RetentionPolicy(maxDays: 1, maxSessions: 1, maxSizeBytes: 1)
        #expect(sessionsToPrune(c, policy: policy, now: t0).isEmpty)
    }

    @Test("maxDays prunes delivered sessions older than the cutoff, keeps recent")
    func prunesByDays() {
        // Sessions aged 0,1,2,3,4 days. Keep last 2 days → the ones strictly older
        // than the cutoff (aged 3 and 4 days) are pruned; the 2-day-old one sits
        // exactly at the cutoff (age ≤ 2) and is kept.
        let c = candidates(count: 5, dayGap: 1)
        let pruned = sessionsToPrune(c, policy: RetentionPolicy(maxDays: 2), now: t0)
        let sorted = c.sorted { $0.startTime > $1.startTime }
        #expect(Set(pruned) == Set(sorted[3...].map(\.id)))
        #expect(pruned.count == 2)
    }

    @Test("maxSessions keeps the newest N, prunes the rest (when delivered)")
    func prunesByCount() {
        let c = candidates(count: 10, dayGap: 1)
        let pruned = sessionsToPrune(c, policy: RetentionPolicy(maxSessions: 3), now: t0)
        let sorted = c.sorted { $0.startTime > $1.startTime }
        #expect(Set(pruned) == Set(sorted[3...].map(\.id)))
        #expect(pruned.count == 7)
    }

    @Test("maxSizeBytes keeps the newest within budget, prunes older over it")
    func prunesBySize() {
        // 10 sessions × 1000 bytes; budget 3500 → keep 3 (3000 ≤ 3500), 4th tips to
        // 4000 > 3500 so it and the rest are pruned.
        let c = candidates(count: 10, dayGap: 1, sizeBytes: 1_000)
        let pruned = sessionsToPrune(c, policy: RetentionPolicy(maxSizeBytes: 3_500), now: t0)
        #expect(pruned.count == 7)
    }

    @Test("a session over any single cap is pruned (caps are OR-ed)")
    func capsAreOred() {
        let c = candidates(count: 5, dayGap: 1)
        // Only the size cap bites (older-than-days and count are off); budget 2000
        // keeps 2, prunes 3.
        let pruned = sessionsToPrune(c, policy: RetentionPolicy(maxDays: 0, maxSessions: 0, maxSizeBytes: 2_000), now: t0)
        #expect(pruned.count == 3)
    }

    @Test("an undelivered session still counts toward the size budget it can't be pruned for")
    func undeliveredConsumesBudget() {
        // Newest is undelivered (1000 B); budget 1500. The undelivered newest fills
        // most of the budget and can't be pruned; the older delivered one tips over
        // and is pruned.
        var c = candidates(count: 2, dayGap: 1, sizeBytes: 1_000)
        c[0].isDelivered = false // newest, undelivered
        let pruned = sessionsToPrune(c, policy: RetentionPolicy(maxSizeBytes: 1_500), now: t0)
        #expect(pruned == [c[1].id]) // only the older, delivered one
    }
}
