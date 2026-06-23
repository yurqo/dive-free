import SwiftUI
import Domain
import Persistence

/// Aggregate stats for a spot, read from its sessions' scalar fields (no deep copy).
struct SpotStats {
    let sessionCount: Int
    let diveCount: Int
    let maxDepthMeters: Double?
    let firstDived: Date?
    let lastDived: Date?

    init(_ spot: Spot) {
        let sessions = spot.sessions
        sessionCount = sessions.count
        let dives = sessions.flatMap { $0.dives }
        diveCount = dives.count
        maxDepthMeters = dives.map(\.maxDepthMeters).max()
        firstDived = sessions.map(\.startTime).min()
        lastDived = sessions.map(\.startTime).max()
    }

    /// e.g. "12 dives · last Jun 2026".
    var summaryLine: String {
        var parts = ["\(diveCount) dive\(diveCount == 1 ? "" : "s")"]
        if let lastDived {
            parts.append("last \(lastDived.formatted(.dateTime.month(.abbreviated).year()))")
        }
        return parts.joined(separator: " · ")
    }

    /// e.g. "Jun 2026" or "May 2025 – Jun 2026".
    var dateRangeText: String? {
        guard let firstDived, let lastDived else { return nil }
        let from = firstDived.formatted(.dateTime.month(.abbreviated).year())
        let to = lastDived.formatted(.dateTime.month(.abbreviated).year())
        return from == to ? from : "\(from) – \(to)"
    }
}

/// A spot's detail: aggregate stats, a map, its sessions, and rename.
struct SpotDetailView: View {
    @Bindable var spot: Spot
    @Environment(\.modelContext) private var modelContext
    @State private var showRename = false
    @State private var draftName = ""

    var body: some View {
        let stats = SpotStats(spot)
        let sessions = spot.sessions.sorted { $0.startTime > $1.startTime }
        List {
            Section {
                LabeledContent("Sessions", value: "\(stats.sessionCount)")
                LabeledContent("Dives", value: "\(stats.diveCount)")
                if let maxDepth = stats.maxDepthMeters {
                    LabeledContent("Max depth", value: DepthFormat.string(maxDepth))
                }
                if let range = stats.dateRangeText {
                    LabeledContent("Dived", value: range)
                }
            }

            Section("Location") {
                SessionMapView(
                    location: GeoPoint(latitude: spot.centerLatitude, longitude: spot.centerLongitude),
                    interactive: false
                )
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
            }

            Section("Sessions") {
                ForEach(sessions) { session in
                    NavigationLink(value: session) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                            Text("\(session.dives.count) dive\(session.dives.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(spot.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") { draftName = spot.name; showRename = true }
            }
        }
        .alert("Rename Spot", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    spot.name = trimmed
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a name for this dive spot.")
        }
    }
}
