import Testing
import Foundation
@testable import Domain

@Suite("DiveStats.compute")
struct DiveStatsTests {
    /// Deterministic UTC Gregorian calendar so month bucketing doesn't depend on
    /// the test machine's locale/timezone.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func session(_ y: Int, _ m: Int, _ d: Int, dives: Int = 1, depth: Double = 10, bottom: TimeInterval = 60, longest: TimeInterval = 60) -> SessionStat {
        SessionStat(startTime: day(y, m, d), diveCount: dives, maxDepthMeters: depth, bottomTime: bottom, longestDive: longest)
    }

    @Test("totals sum across sessions; bests take the max")
    func totals() {
        let stats = DiveStats.compute(
            sessions: [
                session(2026, 1, 10, dives: 3, depth: 8, bottom: 180, longest: 70),
                session(2026, 1, 20, dives: 2, depth: 12, bottom: 120, longest: 90),
            ],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 25), calendar: cal
        )
        #expect(stats.totalSessions == 2)
        #expect(stats.totalDives == 5)
        #expect(stats.totalBottomTime == 300)
        #expect(stats.maxDepthMeters == 12)
        #expect(stats.longestDive == 90)
    }

    @Test("days diving counts distinct calendar days")
    func daysDiving() {
        let stats = DiveStats.compute(
            sessions: [session(2026, 1, 10), session(2026, 1, 10), session(2026, 1, 11)],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 12), calendar: cal
        )
        #expect(stats.daysDiving == 2)
    }

    @Test("countries are de-duplicated and blanks ignored")
    func countries() {
        let stats = DiveStats.compute(
            sessions: [], spotCount: 3,
            spotCountries: ["Indonesia", "Indonesia", "", "Philippines"],
            now: day(2026, 1, 1), calendar: cal
        )
        #expect(stats.spotsVisited == 3)
        #expect(stats.countriesVisited == 2)
        #expect(stats.countries == ["Indonesia", "Philippines"])
    }

    @Test("monthly buckets sum dives per month, oldest first")
    func monthly() {
        let stats = DiveStats.compute(
            sessions: [
                session(2025, 12, 5, dives: 2),
                session(2026, 1, 3, dives: 1),
                session(2026, 1, 28, dives: 4),
            ],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 30), calendar: cal
        )
        #expect(stats.monthly.count == 2)
        #expect(stats.monthly.first?.dives == 2)   // Dec 2025
        #expect(stats.monthly.last?.dives == 5)    // Jan 2026 (1 + 4)
    }

    @Test("streak counts consecutive months ending at now")
    func streak() {
        // Nov, Dec, Jan all have a session; now is January → streak 3.
        let consecutive = DiveStats.compute(
            sessions: [session(2025, 11, 2), session(2025, 12, 9), session(2026, 1, 4)],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 20), calendar: cal
        )
        #expect(consecutive.monthStreak == 3)

        // A gap (no December) breaks it; only January counts.
        let broken = DiveStats.compute(
            sessions: [session(2025, 11, 2), session(2026, 1, 4)],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 20), calendar: cal
        )
        #expect(broken.monthStreak == 1)

        // No session this month → streak 0 even if last month had one.
        let lapsed = DiveStats.compute(
            sessions: [session(2025, 12, 9)],
            spotCount: 0, spotCountries: [], now: day(2026, 1, 20), calendar: cal
        )
        #expect(lapsed.monthStreak == 0)
    }
}
