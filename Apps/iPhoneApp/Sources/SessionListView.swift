import SwiftUI
import SwiftData
import Persistence

/// Phone home screen: the dive history. Charts, maps, and Strava export
/// hang off the per-session detail (Phases 6 & 7).
struct SessionListView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "water.waves",
                        description: Text("Start a session on your Apple Watch to see it here.")
                    )
                } else {
                    List(sessions) { session in
                        NavigationLink(value: session) {
                            VStack(alignment: .leading) {
                                Text(session.startTime, style: .date)
                                    .font(.headline)
                                Text("\(session.dives.count) dives · max \(String(format: "%.1f", session.toDomain().maxDepthMeters)) m")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationDestination(for: SessionRecord.self) { session in
                        SessionDetailView(session: session)
                    }
                }
            }
            .navigationTitle("Dives")
        }
    }
}

#Preview {
    SessionListView()
        .modelContainer(for: SessionRecord.self, inMemory: true)
}
