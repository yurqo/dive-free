import SwiftUI
import SwiftData
import Charts
import Domain
import Persistence

/// The "Passport" tab — the dive passport: lifetime totals, personal bests, the
/// spots and countries you've visited, monthly activity, a streak, and milestone
/// badges. All derived from logged sessions and spots (#109); nothing extra is
/// stored, so there's no migration.
struct StatsView: View {
    @Query private var sessions: [SessionRecord]
    @Query private var spots: [Spot]

    var body: some View {
        NavigationStack {
            // Computed once per render and threaded through the sections (rather
            // than a computed property, which would re-aggregate on every access).
            let stats = computeStats()
            List {
                if stats.totalSessions == 0 {
                    ContentUnavailableView(
                        "No dives yet",
                        systemImage: "rosette",
                        description: Text("Log a session and your dive passport fills in here.")
                    )
                } else {
                    totalsSection(stats)
                    bestsSection(stats)
                    passportSection(stats)
                    if stats.monthly.count > 1 { activitySection(stats) }
                    badgesSection(stats)
                }
            }
            .navigationTitle("Passport")
        }
    }

    /// Maps the live records to lightweight inputs and runs the pure aggregator.
    private func computeStats() -> DiveStats {
        let liveSessions = sessions.filter { $0.modelContext != nil }
        let inputs = liveSessions.map { record -> SessionStat in
            let durations = record.dives.map { $0.endTime.timeIntervalSince($0.startTime) }
            return SessionStat(
                startTime: record.startTime,
                diveCount: record.dives.count,
                maxDepthMeters: record.dives.map(\.maxDepthMeters).max() ?? 0,
                bottomTime: durations.reduce(0, +),
                longestDive: durations.max() ?? 0
            )
        }
        let liveSpots = spots.filter { $0.modelContext != nil }
        return DiveStats.compute(
            sessions: inputs,
            spotCount: liveSpots.count,
            spotCountries: liveSpots.compactMap(\.country)
        )
    }

    private func totalsSection(_ stats: DiveStats) -> some View {
        Section("Totals") {
            statRow("Sessions", "\(stats.totalSessions)")
            statRow("Dives", "\(stats.totalDives)")
            statRow("Bottom time", Duration.seconds(stats.totalBottomTime).formatted(.time(pattern: .hourMinuteSecond)))
            statRow("Days diving", "\(stats.daysDiving)")
            if stats.monthStreak > 0 {
                statRow("Month streak", "\(stats.monthStreak)")
            }
        }
    }

    private func bestsSection(_ stats: DiveStats) -> some View {
        Section("Personal bests") {
            statRow("Max depth", DepthFormat.string(stats.maxDepthMeters))
            statRow("Longest dive", Duration.seconds(stats.longestDive).formatted(.time(pattern: .minuteSecond)))
        }
    }

    @ViewBuilder private func passportSection(_ stats: DiveStats) -> some View {
        Section("Passport") {
            statRow("Spots", "\(stats.spotsVisited)")
            statRow("Countries", "\(stats.countriesVisited)")
            if !stats.countries.isEmpty {
                Text(stats.countries.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activitySection(_ stats: DiveStats) -> some View {
        Section("Activity") {
            Chart(stats.monthly) { bucket in
                BarMark(
                    x: .value("Month", bucket.month, unit: .month),
                    y: .value("Dives", bucket.dives)
                )
                .foregroundStyle(.teal)
            }
            .frame(height: 160)
        }
    }

    private func badgesSection(_ stats: DiveStats) -> some View {
        Section("Badges") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                ForEach(badges(stats), id: \.name) { badge in
                    VStack(spacing: 6) {
                        Image(systemName: badge.icon)
                            .font(.title2)
                            .foregroundStyle(badge.unlocked ? AnyShapeStyle(.teal) : AnyShapeStyle(.secondary))
                        Text(badge.name)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .opacity(badge.unlocked ? 1 : 0.4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func badges(_ stats: DiveStats) -> [(name: String, icon: String, unlocked: Bool)] {
        [
            ("10 Dives", "drop.fill", stats.totalDives >= 10),
            ("50 Dives", "drop.fill", stats.totalDives >= 50),
            ("100 Dives", "drop.fill", stats.totalDives >= 100),
            ("5 Spots", "mappin.circle.fill", stats.spotsVisited >= 5),
            ("10 Spots", "mappin.circle.fill", stats.spotsVisited >= 10),
            ("3 Countries", "globe", stats.countriesVisited >= 3),
            ("10 Days", "calendar", stats.daysDiving >= 10),
        ]
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value).monospacedDigit()
    }
}
