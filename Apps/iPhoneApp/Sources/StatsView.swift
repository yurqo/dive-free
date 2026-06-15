import SwiftUI
import SwiftData
import Domain
import Persistence

/// All-time totals across every stored session: the at-a-glance overview page.
struct StatsView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]

    private var totals: Totals {
        sessions.reduce(into: Totals()) { totals, record in
            let domain = record.toDomain()
            totals.sessions += 1
            totals.dives += domain.diveCount
            totals.duration += domain.totalDuration
            totals.markers += domain.markers.count
            totals.maxDepth = max(totals.maxDepth, domain.maxDepthMeters)
        }
    }

    private struct Totals {
        var sessions = 0
        var dives = 0
        var duration: TimeInterval = 0
        var markers = 0
        var maxDepth: Double = 0
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Stats Yet",
                    systemImage: "chart.bar",
                    description: Text("Record a session on your Apple Watch to see your totals here.")
                )
            } else {
                let totals = totals
                List {
                    Section("All-Time") {
                        statRow("Sessions", "\(totals.sessions)", systemImage: "water.waves")
                        statRow("Dives", "\(totals.dives)", systemImage: "figure.open.water.swim")
                        statRow("Deepest", DepthFormat.string(totals.maxDepth), systemImage: "arrow.down.to.line")
                        statRow(
                            "Total time",
                            Duration.seconds(totals.duration).formatted(.time(pattern: .hourMinuteSecond)),
                            systemImage: "clock"
                        )
                        statRow("Markers", "\(totals.markers)", systemImage: "mappin.and.ellipse")
                    }
                }
            }
        }
        .navigationTitle("Stats")
    }

    private func statRow(_ label: String, _ value: String, systemImage: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label(label, systemImage: systemImage)
        }
    }
}

#Preview {
    NavigationStack {
        StatsView()
    }
    .modelContainer(for: SessionRecord.self, inMemory: true)
}
