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
                        let domain = session.toDomain()
                        NavigationLink(value: session) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text(session.startTime, style: .date)
                                        .font(.headline)
                                    Text("\(domain.diveCount) dives · max \(String(format: "%.1f", domain.maxDepthMeters)) m")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let location = domain.location {
                                    Spacer()
                                    // Static thumbnail; the full, interactive map is on the detail.
                                    SessionMapView(location: location, interactive: false)
                                        .frame(width: 72, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .allowsHitTesting(false)
                                }
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
