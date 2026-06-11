import SwiftUI
import Domain
import Persistence

/// Per-session detail: summary stats plus a depth-profile chart for each dive,
/// stacked and scrollable for multi-dive sessions.
struct SessionDetailView: View {
    let session: SessionRecord

    var body: some View {
        let domain = session.toDomain()
        List {
            Section {
                LabeledContent("Date", value: domain.startTime.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Dives", value: "\(domain.diveCount)")
                LabeledContent("Max depth", value: String(format: "%.1f m", domain.maxDepthMeters))
                if let average = domain.averageSurfaceInterval {
                    LabeledContent(
                        "Avg surface",
                        value: Duration.seconds(average).formatted(.time(pattern: .minuteSecond))
                    )
                }
            }

            Section("Location") {
                if let location = domain.location {
                    SessionMapView(location: location)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } else {
                    // GPS rarely fixes underwater, so a missing location is normal.
                    Label("No location recorded", systemImage: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }

            if domain.dives.isEmpty {
                ContentUnavailableView(
                    "No Dives",
                    systemImage: "chart.xyaxis.line",
                    description: Text("This session has no recorded dives.")
                )
            } else {
                ForEach(Array(domain.dives.enumerated()), id: \.element.id) { index, dive in
                    Section("Dive \(index + 1) · \(String(format: "%.1f m", dive.maxDepthMeters)) max") {
                        DepthChartView(dive: dive)
                    }
                }
            }
        }
        .navigationTitle(domain.startTime.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }
}
