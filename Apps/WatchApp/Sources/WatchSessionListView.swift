import SwiftUI
import SwiftData
import Domain
import Persistence

/// Second page of the watch home pager: the dives recorded on this watch
/// (also synced to the iPhone, where the full detail/charts/map live).
struct WatchSessionListView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "water.waves",
                        description: Text("Your dives show up here, and on iPhone.")
                    )
                } else {
                    List {
                        ForEach(sessions) { record in
                            let domain = record.toDomain()
                            NavigationLink(value: record) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                        .font(.headline)
                                    Text(domain.diveCount > 0
                                         ? "\(domain.diveCount) dives · \(DepthFormat.value(domain.maxDepthMeters)) m max"
                                         : "\(domain.diveCount) dives")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionRecord.self) { record in
                WatchSessionSummaryView(session: record.toDomain())
                    .navigationTitle(record.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            }
        }
    }
}
