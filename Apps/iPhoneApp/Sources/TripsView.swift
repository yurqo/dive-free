import SwiftUI
import SwiftData
import Domain
import Persistence

/// The "Trips" tab — multi-day dive trips grouped from the session log by date and
/// location (#111). Auto-suggested; the user can rename, add notes, or delete.
struct TripsView: View {
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @Query private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext

    /// `@Query` can briefly include a just-deleted trip before it refreshes;
    /// reading a deleted model traps (#148), so display only live ones. Trips left
    /// empty (all their sessions deleted) are shown too, so the diver can
    /// swipe-delete them — we never auto-remove a trip, since one whose sessions
    /// simply haven't synced to this device yet would also look empty.
    private var liveTrips: [Trip] { trips.filter { $0.modelContext != nil } }

    /// Sessions still in the store for a trip. A deleted session can linger in the
    /// relationship until `@Query` refreshes, and reading a deleted model traps
    /// (#148), so count only those still backed by a context.
    private func liveSessionCount(_ trip: Trip) -> Int {
        (trip.sessions ?? []).filter { $0.modelContext != nil }.count
    }

    /// Row subtitle: the live session count (an orphaned trip reads "0 sessions",
    /// signalling it's safe to swipe away).
    private func sessionCountText(_ trip: Trip) -> String {
        let n = liveSessionCount(trip)
        // `String(localized:)` doesn't process inflection markup, so round-trip
        // through `AttributedString` to get the inflected plain string per language.
        return String(AttributedString(localized: "^[\(n) session](inflect: true)").characters)
    }

    var body: some View {
        NavigationStack {
            Group {
                if liveTrips.isEmpty {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "suitcase")
                    } description: {
                        Text("Group your logged dives into multi-day trips by date and location.")
                    } actions: {
                        Button("Group my dives") { autoGroup() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(liveTrips) { trip in
                            NavigationLink { TripDetailView(trip: trip) } label: { tripRow(trip) }
                        }
                        .onDelete(perform: deleteTrips)
                    }
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                if !liveTrips.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Group new dives", systemImage: "wand.and.stars") { autoGroup() }
                    }
                }
            }
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trip.name.isEmpty ? "Trip" : trip.name).font(.headline)
            Text(dateRange(trip)).font(.caption).foregroundStyle(.secondary)
            Text(sessionCountText(trip))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dateRange(_ trip: Trip) -> String {
        let short = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if Calendar.current.isDate(trip.startDate, inSameDayAs: trip.endDate) {
            return trip.startDate.formatted(short.year())
        }
        return "\(trip.startDate.formatted(short)) – \(trip.endDate.formatted(short.year()))"
    }

    private func deleteTrips(_ offsets: IndexSet) {
        for trip in offsets.map({ liveTrips[$0] }) {
            // Detach the sessions first so deleting an orphaned trip whose sessions
            // were already removed doesn't choke on a dangling relationship (which
            // is what made an empty trip un-deletable). Sessions stay in the log.
            trip.sessions = nil
            modelContext.delete(trip)
        }
        try? modelContext.save()
    }

    /// Groups currently unassigned sessions into Trip records, leaving existing
    /// trips intact — only sessions with no trip are considered, so re-running is
    /// safe and never stomps manual edits. A trip needs at least two sessions.
    private func autoGroup() {
        let unassigned = sessions.filter { $0.modelContext != nil && $0.trip == nil }
        let inputs = unassigned.map { record in
            TripSuggestionInput(
                id: record.id,
                startTime: record.startTime,
                location: record.latitude.flatMap { lat in record.longitude.map { GeoPoint(latitude: lat, longitude: $0) } }
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: unassigned.map { ($0.id, $0) })
        for group in suggestTrips(from: inputs) {
            let records = group.compactMap { byID[$0] }.sorted { $0.startTime < $1.startTime }
            guard records.count >= 2 else { continue }
            let trip = Trip(
                name: tripName(for: records),
                startDate: records.first!.startTime,
                endDate: records.last!.startTime
            )
            modelContext.insert(trip)
            for record in records { record.trip = trip }
        }
        try? modelContext.save()
    }

    /// A friendly default name: a single shared country, else the first area name,
    /// else the month. The user can rename it in the detail view.
    private func tripName(for sessions: [SessionRecord]) -> String {
        let countries = Set(sessions.compactMap { $0.spot?.country }.filter { !$0.isEmpty })
        if countries.count == 1, let country = countries.first { return country }
        if let area = sessions.compactMap(\.locationName).first(where: { !$0.isEmpty }) { return area }
        return sessions.first!.startTime.formatted(.dateTime.month(.wide).year())
    }
}
