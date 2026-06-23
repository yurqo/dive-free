import SwiftUI
import SwiftData
import Domain
import Persistence
import Strava

/// Phone home screen: the dive history. Charts, maps, and Strava export
/// hang off the per-session detail (Phases 6 & 7).
struct SessionListView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext

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
                    List {
                        ForEach(sessions) { session in
                        let domain = session.toDomain()
                        NavigationLink(value: session) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.startTime, style: .date)
                                        .font(.headline)
                                    Text("\(domain.diveCount) dives · max \(DepthFormat.string(domain.maxDepthMeters))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    // Every session on the phone arrived from the
                                    // Watch over WatchConnectivity.
                                    Label("Synced from Apple Watch", systemImage: "checkmark.icloud")
                                        .font(.caption2)
                                        .foregroundStyle(.teal)
                                        .labelStyle(.titleAndIcon)
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
                        .onDelete(perform: deleteSessions)
                    }
                    .navigationDestination(for: SessionRecord.self) { session in
                        SessionDetailView(session: session)
                    }
                }
            }
            .navigationTitle("Dives")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    SessionListView()
        .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
        .modelContainer(for: SessionRecord.self, inMemory: true)
}
