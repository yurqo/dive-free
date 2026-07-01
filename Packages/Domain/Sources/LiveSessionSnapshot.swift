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
    /// After this long without a fresher snapshot, the phone treats the live
    /// values as stale (grays them out, marks the timer "estimated").
    public static let staleThreshold: TimeInterval = 30

    /// Hard cap: if no snapshot arrives for this long and no explicit "ended"
    /// was received, the phone dismisses the live session on its own. Sized for a
    /// long freedive outing (surface intervals can stretch a session to 1–2 h)
    /// spent entirely out of range.
    public static let maxAge: TimeInterval = 4 * 60 * 60

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
}
