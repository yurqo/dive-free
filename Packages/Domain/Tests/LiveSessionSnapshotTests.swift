import Foundation
import Testing
@testable import Domain

@Suite("LiveSessionSnapshot send suppression")
struct LiveSessionSnapshotTests {
    /// Base session start — shared so snapshots compare on content, not identity.
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        isActive: Bool = true,
        depth: Double = 0,
        maxDepth: Double = 0,
        diveCount: Int = 0,
        isSubmerged: Bool = false,
        elapsed: TimeInterval? = nil,
        updatedAt: Date? = nil
    ) -> LiveSessionSnapshot {
        LiveSessionSnapshot(
            isActive: isActive,
            startTime: start,
            updatedAt: updatedAt ?? start,
            depthMeters: depth,
            maxDepthMeters: maxDepth,
            diveCount: diveCount,
            isSubmerged: isSubmerged,
            currentDiveElapsed: elapsed
        )
    }

    // MARK: - First / terminal always send

    @Test("the first snapshot of a session always sends (no previous)")
    func firstSnapshotSends() {
        #expect(LiveSessionSnapshot.shouldSend(
            previous: nil, candidate: snapshot(), lastSentAt: nil, now: start
        ))
    }

    @Test("the terminal snapshot always sends, even when content is unchanged and no heartbeat is due")
    func terminalSnapshotSends() {
        let previous = snapshot()
        let terminal = snapshot(isActive: false)
        // now == lastSentAt: no heartbeat, identical content bar isActive → still sends.
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: terminal, lastSentAt: start, now: start
        ))
    }

    // MARK: - Suppression at the surface

    @Test("an unchanged surface tick is suppressed before the heartbeat is due")
    func unchangedSurfaceTickSuppressed() {
        let previous = snapshot()
        let candidate = snapshot(updatedAt: start.addingTimeInterval(2))
        #expect(!LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    @Test("a sub-quantum depth wiggle is suppressed (below 0.1 m display precision)")
    func subQuantumDepthSuppressed() {
        let previous = snapshot(depth: 3.30)
        let candidate = snapshot(depth: 3.34, updatedAt: start.addingTimeInterval(2))
        #expect(previous.contentEquals(candidate))
        #expect(!LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    // MARK: - Meaningful changes send

    @Test("crossing a 0.1 m display quantum sends")
    func crossingDepthQuantumSends() {
        let previous = snapshot(depth: 3.30)
        let candidate = snapshot(depth: 3.45, updatedAt: start.addingTimeInterval(2))
        #expect(!previous.contentEquals(candidate))
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    @Test("a diveCount change always sends")
    func diveCountChangeSends() {
        let previous = snapshot(diveCount: 1)
        let candidate = snapshot(diveCount: 2, updatedAt: start.addingTimeInterval(2))
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    @Test("an isSubmerged flip always sends")
    func submergedFlipSends() {
        let previous = snapshot(isSubmerged: false)
        let candidate = snapshot(isSubmerged: true, updatedAt: start.addingTimeInterval(2))
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    @Test("a new max depth crossing the display quantum sends")
    func maxDepthChangeSends() {
        let previous = snapshot(maxDepth: 4.0)
        let candidate = snapshot(maxDepth: 4.2, updatedAt: start.addingTimeInterval(2))
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(2)
        ))
    }

    // MARK: - Heartbeat

    @Test("a heartbeat forces a send after heartbeatInterval even with unchanged content")
    func heartbeatSends() {
        let previous = snapshot()
        let elapsed = LiveSessionSnapshot.heartbeatInterval
        let candidate = snapshot(updatedAt: start.addingTimeInterval(elapsed))
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(elapsed)
        ))
    }

    @Test("just before the heartbeat interval, unchanged content is still suppressed")
    func justBeforeHeartbeatSuppressed() {
        let previous = snapshot()
        let elapsed = LiveSessionSnapshot.heartbeatInterval - 0.5
        let candidate = snapshot(updatedAt: start.addingTimeInterval(elapsed))
        #expect(!LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start, now: start.addingTimeInterval(elapsed)
        ))
    }

    /// The Watch's live-sync loop only *checks* the heartbeat on its ~2 s tick
    /// (`SessionCoordinator.startLiveSync` → `Task.sleep(for: .seconds(2))`), so the
    /// effective cadence is `heartbeatInterval` rounded up to the next tick — bounded
    /// above by `heartbeatInterval + tickInterval`.
    private static let tickInterval: TimeInterval = 2

    @Test("heartbeat + tick quantization + one dropped delivery stays under the stale threshold")
    func heartbeatSurvivesOneDroppedDelivery() {
        // WatchConnectivity coalesces / defers the application context, so a heartbeat
        // can arrive a full cadence late. The worst-case gap between two *received*
        // heartbeats is therefore two effective cadences — and that must stay under
        // `staleThreshold`, or a single deferred delivery transiently grays a healthy,
        // connected session.
        //
        //   effectiveCadence = heartbeatInterval + tickInterval  (upper bound)
        //   worstCaseGap     = 2 × effectiveCadence              (one dropped delivery)
        //   invariant:         worstCaseGap ≤ staleThreshold
        //
        // Concretely: 2 × (5 + 2) = 14 ≤ 15. (A half-threshold heartbeat would give
        // 2 × (7.5 + 2) = 19 > 15 — the reason we use a third.)
        let effectiveCadence = LiveSessionSnapshot.heartbeatInterval + Self.tickInterval
        #expect(2 * effectiveCadence <= LiveSessionSnapshot.staleThreshold)
        #expect(LiveSessionSnapshot.heartbeatInterval == LiveSessionSnapshot.staleThreshold / 3)
    }

    @Test("a backwards wall-clock jump (negative elapsed) forces a heartbeat send")
    func negativeElapsedForcesSend() {
        // `Date` is not monotonic: an NTP correction can step `now` *before*
        // `lastSentAt`, yielding a negative elapsed. That must not silently mute the
        // heartbeat (which would let the phone gray a healthy session until the clock
        // caught back up) — a backwards jump is treated as heartbeat-due.
        let previous = snapshot()
        let candidate = snapshot() // unchanged content
        #expect(LiveSessionSnapshot.shouldSend(
            previous: previous, candidate: candidate,
            lastSentAt: start.addingTimeInterval(10), now: start
        ))
    }

    // MARK: - Slow-creep accumulation (suppression measures against the last SENT)

    @Test("a slow depth creep is suppressed until it accumulates past the display quantum vs the last SENT")
    func slowCreepAccumulatesAgainstLastSent() {
        // Depth rises 0.04 m per tick — each single step is below the 0.1 m display
        // quantum, so suppression must compare each candidate against the last snapshot
        // we actually *sent* (a frozen baseline), letting the drift accumulate until
        // the phone's rendered "%.1f" depth would change. (Comparing against the
        // previous *tick* instead would reset the baseline every tick.)
        var lastSent = snapshot(depth: 3.00)
        var lastSentAt = start
        var depth = 3.00
        var sends: [Double] = []
        for i in 1...5 {
            depth += 0.04
            let now = start.addingTimeInterval(Double(i) * Self.tickInterval)
            let candidate = snapshot(depth: depth, updatedAt: now)
            if LiveSessionSnapshot.shouldSend(
                previous: lastSent, candidate: candidate, lastSentAt: lastSentAt, now: now
            ) {
                sends.append(depth)
                lastSent = candidate
                lastSentAt = now
            }
        }
        // 3.00→3.04 (still "3.0", suppressed) → 3.08 (renders "3.1", SEND) → reset;
        // 3.08→3.12 ("3.1", suppressed) → 3.16 (renders "3.2", SEND) → reset; 3.20 ("3.2").
        #expect(sends.count == 2)
        #expect(sends.map { ($0 * 100).rounded() } == [308, 316])
    }

    @Test("the tick after a send is measured against the last SENT baseline, not the session start")
    func creepBaselineIsLastSentNotStart() {
        // After a send at 3.08 the baseline advances to 3.08. A follow-up 3.11 is only
        // +0.03 above that SENT baseline → suppressed, even though it is +0.11 above
        // the session's opening 3.00 (which, if used as the baseline, would send).
        let sent = snapshot(depth: 3.08, updatedAt: start.addingTimeInterval(4))
        let followUp = snapshot(depth: 3.11, updatedAt: start.addingTimeInterval(6))
        #expect(!LiveSessionSnapshot.shouldSend(
            previous: sent, candidate: followUp,
            lastSentAt: start.addingTimeInterval(4), now: start.addingTimeInterval(6)
        ))
    }

    // MARK: - contentEquals directly

    @Test("contentEquals ignores updatedAt")
    func contentEqualsIgnoresUpdatedAt() {
        let a = snapshot(depth: 2.0, updatedAt: start)
        let b = snapshot(depth: 2.0, updatedAt: start.addingTimeInterval(9))
        #expect(a.contentEquals(b))
    }

    @Test("contentEquals buckets currentDiveElapsed to 5 s")
    func elapsedBucketed() {
        let a = snapshot(isSubmerged: true, elapsed: 6)
        let b = snapshot(isSubmerged: true, elapsed: 9) // same 5..<10 bucket
        let c = snapshot(isSubmerged: true, elapsed: 11) // next bucket
        #expect(a.contentEquals(b))
        #expect(!a.contentEquals(c))
    }
}
