import SwiftUI
import SwiftData
import Domain
import Persistence
import Sensors

/// Second page of the watch home pager: the dives recorded on this watch
/// (also synced to the iPhone, where the full detail/charts/map live).
struct WatchSessionListView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext

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
                                    Text(statsLine(domain))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    if let name = domain.locationName, !name.isEmpty {
                                        Text(name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .task { await backfillLocationNames() }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionRecord.self) { record in
                WatchSessionSummaryView(session: record.toDomain())
                    .navigationTitle(record.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            }
        }
    }

    /// Second-line summary: total time · distance · ↓ dives · 📍 markers.
    private func statsLine(_ session: DiveSession) -> String {
        let time = Duration.seconds(session.totalDuration).formatted(.time(pattern: .minuteSecond))
        let distance = DistanceFormat.string(session.surfaceDistanceMeters)
        return "⏱\(time) · \(distance) · ↓\(session.diveCount) · 📍\(session.markers.count)"
    }

    /// Resolves and persists the area name for any session missing one, one at a
    /// time (CLGeocoder expects serial requests). Runs when the list appears, so
    /// new sessions get named and older ones backfill; failures just retry next
    /// time. Skipped per-session once a name is saved, so each spot geocodes once.
    private func backfillLocationNames() async {
        for record in sessions {
            if Task.isCancelled { return }
            guard record.locationName == nil,
                  let lat = record.latitude, let lon = record.longitude else { continue }
            guard let name = await LocationName.resolve(latitude: lat, longitude: lon),
                  !name.isEmpty else { continue }
            record.locationName = name
            try? modelContext.save()
        }
    }
}
