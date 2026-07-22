import Foundation

/// A coalesced, latest-value snapshot of an in-progress dive session, sent from
/// the Watch to the iPhone (over WatchConnectivity's application context) so the
/// phone can reflect the live session — an in-app banner and a Live Activity
/// (#118). Pure value type: no platform dependencies, so both the Watch (sender)
/// and the iPhone/widget (receiver) share it.
///
/// Delivery is best-effort and latest-wins: while the Watch is out of range the
/// phone keeps the last snapshot and shows the elapsed timer as an **estimate**
/// (the start time lets it tick locally), catching up when a fresher snapshot
/// arrives. `updatedAt` drives that staleness treatment.
public struct LiveSessionSnapshot: Codable, Hashable, Sendable {
    /// Backstop staleness: after this long without a fresher snapshot the phone
    /// treats the live values as an estimate (grays them, marks the timer
    /// "estimated"). The primary, real-time disconnect signal is WCSession
    /// reachability; this only covers the case where reachability stays up but
    /// data stops flowing.
    public static let staleThreshold: TimeInterval = 15

    /// Hard cap: if no snapshot arrives for this long and no explicit "ended"
    /// was received, the phone dismisses the live session on its own.
    public static let maxAge: TimeInterval = 60 * 60

    /// False marks the terminal snapshot the Watch sends on stop, so the phone
    /// ends the banner/Live Activity promptly rather than waiting to time out.
    public var isActive: Bool
    /// Session start — lets the phone tick the elapsed timer locally, even while
    /// the Watch is unreachable.
    public var startTime: Date
    /// When the Watch produced this snapshot (its clock). Drives staleness.
    public var updatedAt: Date
    /// Current depth (m). Frozen (and grayed) on the phone while stale.
    public var depthMeters: Double
    /// Running maximum depth (m) this session.
    public var maxDepthMeters: Double
    /// Finalized dives detected so far this session.
    public var diveCount: Int
    /// True while the diver is below the surface threshold (drives the phone's
    /// "diving" vs "at surface" treatment).
    public var isSubmerged: Bool
    /// Elapsed time of the dive currently in progress, or nil at the surface.
    public var currentDiveElapsed: TimeInterval?

    public init(
        isActive: Bool,
        startTime: Date,
        updatedAt: Date = Date(),
        depthMeters: Double,
        maxDepthMeters: Double,
        diveCount: Int,
        isSubmerged: Bool,
        currentDiveElapsed: TimeInterval? = nil
    ) {
        self.isActive = isActive
        self.startTime = startTime
        self.updatedAt = updatedAt
        self.depthMeters = depthMeters
        self.maxDepthMeters = maxDepthMeters
        self.diveCount = diveCount
        self.isSubmerged = isSubmerged
        self.currentDiveElapsed = currentDiveElapsed
    }

    /// Whether the snapshot is older than `staleThreshold` as of `now` — i.e. the
    /// Watch has likely gone out of range, so the live values should be shown as
    /// estimates.
    public func isStale(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleThreshold
    }

    /// Whether the snapshot has aged past `maxAge` as of `now`, at which point the
    /// phone gives up on a missed "ended" and dismisses the live session.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.maxAge
    }

    // MARK: - Redundant-tick suppression (#118 efficiency)

    /// The Watch produces a snapshot every ~2 s, but each send re-applies the whole
    /// WatchConnectivity application context (markers/units/detection blobs ride
    /// along — see `SyncManager.sendLiveSession`). Most of a freediving session is
    /// spent at the surface with nothing changing, so the lever is *call frequency*:
    /// only actually send when the phone would render something different, plus a
    /// periodic heartbeat so a healthy session never crosses `staleThreshold`.

    /// Depth comparison quantum (m). The phone renders depth to 0.1 m
    /// (`DepthFormat.value` formats metres as `"%.1f"`; feet are whole, i.e. even
    /// coarser), so a change smaller than this is invisible on the banner and Live
    /// Activity and need not be transmitted. Matches the finest display precision.
    public static let depthSendQuantum = 0.1

    /// Elapsed-dive comparison quantum (s). The phone does NOT render
    /// `currentDiveElapsed` at all (its "Elapsed" ticks locally off `startTime`), so
    /// this only guards against needless sends; 5 s is a conservative bucket.
    public static let elapsedSendQuantum: TimeInterval = 5

    /// Force a send at least this often even when the content is unchanged, so the
    /// phone's staleness treatment (`isStale` / the Live Activity `staleDate`, both
    /// keyed off `staleThreshold`) never grays a healthy, connected session.
    ///
    /// The heartbeat is only *checked* on the Watch's ~2 s tick, so it is quantized:
    /// the effective cadence is the first tick at or after `heartbeatInterval`, not
    /// the interval itself. With a 2 s tick and `heartbeatInterval == staleThreshold
    /// / 3 == 5 s`, that is a send every 6 s (the 3rd tick). The tolerance we need is
    /// one whole missed delivery — WatchConnectivity coalesces / defers the
    /// application context, so a heartbeat can arrive a full cadence late: worst-case
    /// receive gap = 2 × 6 s = 12 s, still under `staleThreshold` (15 s). Halving the
    /// threshold instead (7.5 s → 8 s effective) would give a 2 × 8 s = 16 s
    /// worst-case gap — *past* the threshold — transiently graying a healthy,
    /// connected session, so we use a third, not a half.
    public static let heartbeatInterval: TimeInterval = staleThreshold / 3

    /// Bucketed depth. `shouldSend` runs on every ~2 s Watch tick with
    /// sensor-derived depth that has no sanitize guard, so a non-finite value must
    /// never reach `Int(_:)` (which traps on NaN/±inf). Non-finite → bucket 0.
    private static func depthBucket(_ meters: Double) -> Int {
        guard meters.isFinite else { return 0 }
        return Int((meters / depthSendQuantum).rounded())
    }

    /// Bucketed elapsed, guarded like `depthBucket`: non-finite → bucket 0 (never
    /// traps `Int(_:)`), absent stays absent.
    private static func elapsedBucket(_ elapsed: TimeInterval?) -> Int? {
        elapsed.map { $0.isFinite ? Int(($0 / elapsedSendQuantum).rounded(.down)) : 0 }
    }

    /// Whether two snapshots would render identically on the phone, comparing the
    /// fast-changing depth/elapsed fields at display precision (`depthSendQuantum` /
    /// `elapsedSendQuantum`) and the discrete fields (`diveCount`, `isSubmerged`,
    /// bucketed `maxDepthMeters`) exactly. Ignores `updatedAt` (wall-clock only).
    public func contentEquals(_ other: LiveSessionSnapshot) -> Bool {
        isActive == other.isActive
            && startTime == other.startTime
            && diveCount == other.diveCount
            && isSubmerged == other.isSubmerged
            && Self.depthBucket(depthMeters) == Self.depthBucket(other.depthMeters)
            && Self.depthBucket(maxDepthMeters) == Self.depthBucket(other.maxDepthMeters)
            && Self.elapsedBucket(currentDiveElapsed) == Self.elapsedBucket(other.currentDiveElapsed)
    }

    /// Whether `candidate` should actually be transmitted, given the last snapshot
    /// we *sent* (`previous`, `nil` before the first send of a session) and when
    /// (`lastSentAt`). Pure, so the Watch's tick loop stays a thin caller.
    ///
    /// - The terminal snapshot (`isActive == false`) ALWAYS sends, so the phone
    ///   tears its live display down promptly rather than waiting to time out.
    /// - The first snapshot of a session (`previous`/`lastSentAt` nil) always sends.
    /// - A heartbeat forces a send once `heartbeatInterval` has passed, even with
    ///   unchanged content, to keep the phone from graying a healthy session.
    /// - Otherwise, send only when the displayed content changed (`contentEquals`).
    public static func shouldSend(
        previous: LiveSessionSnapshot?,
        candidate: LiveSessionSnapshot,
        lastSentAt: Date?,
        now: Date = Date()
    ) -> Bool {
        if !candidate.isActive { return true }
        guard let previous, let lastSentAt else { return true }
        // `Date` is wall-clock, not monotonic: an NTP correction can step `now`
        // *backwards* past `lastSentAt`, yielding a negative interval that would
        // otherwise silently mute the heartbeat until the clock caught back up
        // (leaving the phone to gray a healthy session). Treat any backwards jump
        // as heartbeat-due so we resync immediately.
        let sinceLast = now.timeIntervalSince(lastSentAt)
        if sinceLast < 0 || sinceLast >= heartbeatInterval { return true }
        return !previous.contentEquals(candidate)
    }
}
