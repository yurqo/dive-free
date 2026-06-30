import SwiftUI
import SwiftData
import Domain
import Persistence

/// A trip's detail: editable name + notes, the date range, aggregate stats, and the
/// sessions it groups (#111).
struct TripDetailView: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    private var liveSessions: [SessionRecord] {
        (trip.sessions ?? []).filter { $0.modelContext != nil }.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        List {
            Section {
                TextField("Trip name", text: $trip.name)
                LabeledContent("Dates", value: dateRange)
                LabeledContent("Sessions", value: "\(liveSessions.count)")
            }

            statsSection

            Section("Notes") {
                TextField("Add notes", text: notesBinding, axis: .vertical)
                    .lineLimit(1...6)
            }

            Section("Sessions") {
                ForEach(liveSessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                            if let name = session.locationName, !name.isEmpty {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(trip.name.isEmpty ? "Trip" : trip.name)
        .navigationBarTitleDisplayMode(.inline)
        // Persist name/notes edits when leaving (SwiftData autosave also covers it).
        .onDisappear { try? modelContext.save() }
    }

    @ViewBuilder private var statsSection: some View {
        let stats = DiveStats.compute(
            sessions: liveSessions.map { record in
                let durations = (record.dives ?? []).map { $0.endTime.timeIntervalSince($0.startTime) }
                return SessionStat(
                    startTime: record.startTime,
                    diveCount: record.dives?.count ?? 0,
                    maxDepthMeters: (record.dives ?? []).map(\.maxDepthMeters).max() ?? 0,
                    bottomTime: durations.reduce(0, +),
                    longestDive: durations.max() ?? 0
                )
            },
            spotCount: Set(liveSessions.compactMap { $0.spot?.id }).count,
            spotCountries: liveSessions.compactMap { $0.spot?.country }
        )
        Section("Totals") {
            LabeledContent("Dives", value: "\(stats.totalDives)").monospacedDigit()
            if stats.maxDepthMeters > 0 {
                LabeledContent("Max depth", value: DepthFormat.string(stats.maxDepthMeters))
            }
            LabeledContent("Bottom time", value: Duration.seconds(stats.totalBottomTime).formatted(.time(pattern: .hourMinuteSecond)))
                .monospacedDigit()
            if stats.countriesVisited > 0 {
                LabeledContent("Countries", value: "\(stats.countriesVisited)")
            }
        }
    }

    private var notesBinding: Binding<String> {
        Binding(get: { trip.notes ?? "" }, set: { trip.notes = $0.isEmpty ? nil : $0 })
    }

    private var dateRange: String {
        let full = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        guard let first = liveSessions.first?.startTime, let last = liveSessions.last?.startTime else {
            return trip.startDate.formatted(full)
        }
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(full) }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(full))"
    }
}
