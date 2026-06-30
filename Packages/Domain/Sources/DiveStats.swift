import Foundation

/// One session's contribution to lifetime stats (#109). Lightweight so the
/// "dive passport" can be computed without deep-copying every session.
public struct SessionStat: Sendable, Equatable {
    public let startTime: Date
    public let diveCount: Int
    public let maxDepthMeters: Double
    public let bottomTime: TimeInterval   // sum of this session's dive durations
    public let longestDive: TimeInterval  // longest single dive this session

    public init(startTime: Date, diveCount: Int, maxDepthMeters: Double, bottomTime: TimeInterval, longestDive: TimeInterval) {
        self.startTime = startTime
        self.diveCount = diveCount
        self.maxDepthMeters = maxDepthMeters
        self.bottomTime = bottomTime
        self.longestDive = longestDive
    }
}

/// A month bucket for the activity chart (#109).
public struct MonthlyDiveCount: Sendable, Equatable, Identifiable {
    public let month: Date   // first instant of the month
    public let dives: Int
    public var id: Date { month }
    public init(month: Date, dives: Int) { self.month = month; self.dives = dives }
}

/// Lifetime "dive passport" stats, derived from the logged sessions + spots (#109).
/// A pure value type — nothing is persisted; it's recomputed on demand, so no
/// schema change or migration.
public struct DiveStats: Sendable, Equatable {
    public var totalSessions = 0
    public var totalDives = 0
    public var totalBottomTime: TimeInterval = 0
    public var maxDepthMeters: Double = 0
    public var longestDive: TimeInterval = 0
    public var daysDiving = 0
    public var spotsVisited = 0
    public var countriesVisited = 0
    public var countries: [String] = []
    /// Consecutive months up to and including the current one that have a session.
    /// (Freediving isn't daily, so a monthly cadence is the meaningful "streak".)
    public var monthStreak = 0
    /// Per-month dive counts, oldest → newest, for the activity chart.
    public var monthly: [MonthlyDiveCount] = []

    public init() {}

    /// Computes lifetime stats from per-session contributions and spot info.
    /// `now`/`calendar` are injectable for deterministic tests.
    public static func compute(
        sessions: [SessionStat],
        spotCount: Int,
        spotCountries: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DiveStats {
        var stats = DiveStats()
        stats.totalSessions = sessions.count
        stats.totalDives = sessions.reduce(0) { $0 + $1.diveCount }
        stats.totalBottomTime = sessions.reduce(0) { $0 + $1.bottomTime }
        stats.maxDepthMeters = sessions.map(\.maxDepthMeters).max() ?? 0
        stats.longestDive = sessions.map(\.longestDive).max() ?? 0
        stats.daysDiving = Set(sessions.map { calendar.startOfDay(for: $0.startTime) }).count
        stats.spotsVisited = spotCount

        let uniqueCountries = Set(spotCountries.filter { !$0.isEmpty })
        stats.countries = uniqueCountries.sorted()
        stats.countriesVisited = uniqueCountries.count

        var buckets: [Date: Int] = [:]
        for session in sessions {
            guard let month = monthStart(session.startTime, calendar) else { continue }
            buckets[month, default: 0] += session.diveCount
        }
        stats.monthly = buckets.keys.sorted().map { MonthlyDiveCount(month: $0, dives: buckets[$0] ?? 0) }
        stats.monthStreak = monthStreak(monthsWithDives: Set(buckets.keys), now: now, calendar: calendar)
        return stats
    }

    private static func monthStart(_ date: Date, _ calendar: Calendar) -> Date? {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
    }

    /// Walks back month-by-month from `now` while each month has a session.
    private static func monthStreak(monthsWithDives: Set<Date>, now: Date, calendar: Calendar) -> Int {
        guard var cursor = monthStart(now, calendar) else { return 0 }
        var streak = 0
        while monthsWithDives.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .month, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
