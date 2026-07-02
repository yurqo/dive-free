import SwiftUI
import SwiftData
import MapKit
import Domain
import Persistence
import Sensors

/// The Spots tab: a map of every dive spot plus a list grouped by country (#147).
struct SpotsListView: View {
    @Query(sort: \Spot.name) private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    /// Spots whose country geocode was attempted this launch (a failed lookup
    /// isn't persisted, so it retries on a later launch).
    @State private var countryAttempted: Set<UUID> = []

    /// `@Query` can briefly include a just-deleted spot before it refreshes;
    /// reading a deleted model traps (#148), so work off the live ones. Orphan
    /// spots (all their sessions deleted) are shown too, so they can be
    /// swipe-deleted.
    private var liveSpots: [Spot] { spots.filter { $0.modelContext != nil } }

    /// Spots grouped by country (name-sorted within each), countries A→Z with the
    /// not-yet-resolved "Unknown" bucket last.
    private var grouped: [(country: String, spots: [Spot])] {
        Dictionary(grouping: liveSpots) { $0.country ?? "" }
            .map { (country: $0.key, spots: $0.value) }
            .sorted { lhs, rhs in
                if lhs.country.isEmpty != rhs.country.isEmpty { return !lhs.country.isEmpty }
                return lhs.country.localizedCaseInsensitiveCompare(rhs.country) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if liveSpots.isEmpty {
                    ContentUnavailableView(
                        "No Spots Yet",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Dive spots appear here as you log sessions on your Apple Watch.")
                    )
                } else {
                    List {
                        Section {
                            SpotsMap(spots: liveSpots)
                                .frame(height: 200)
                                .listRowInsets(EdgeInsets())
                        }
                        ForEach(grouped, id: \.country) { group in
                            Section(group.country.isEmpty ? "Unknown" : group.country) {
                                ForEach(group.spots) { spot in
                                    NavigationLink(value: spot) { SpotRow(spot: spot) }
                                }
                                .onDelete { deleteSpots($0, in: group.spots) }
                            }
                        }
                    }
                    .navigationDestination(for: Spot.self) { SpotDetailView(spot: $0) }
                    .navigationDestination(for: SessionRecord.self) { SessionDetailView(session: $0) }
                    .task { await backfillCountries() }
                }
            }
            .navigationTitle("Spots")
        }
    }

    /// Swipe-delete a spot. Detaches its sessions/photos first so an orphaned spot
    /// (its sessions already deleted) removes cleanly instead of choking on a
    /// dangling relationship — the sessions and photos stay in the log (nullify).
    /// A spot that still has sessions may be re-created later by the auto-assigner,
    /// since spots are derived from session locations.
    private func deleteSpots(_ offsets: IndexSet, in groupSpots: [Spot]) {
        for spot in offsets.map({ groupSpots[$0] }) {
            spot.sessions = nil
            spot.photos = nil
            modelContext.delete(spot)
        }
        try? modelContext.save()
    }

    /// Reverse-geocodes the country for any spot missing one, one at a time
    /// (CLGeocoder expects serial requests). Guards against a spot deleted mid-
    /// await (same model-invalidation crash as #148).
    private func backfillCountries() async {
        for spot in spots {
            if Task.isCancelled { return }
            guard spot.modelContext != nil else { continue }
            guard spot.country == nil, !countryAttempted.contains(spot.id) else { continue }
            countryAttempted.insert(spot.id)
            guard let place = await LocationName.resolveCountry(
                latitude: spot.centerLatitude, longitude: spot.centerLongitude
            ) else { continue }
            guard spot.modelContext != nil else { continue }
            spot.country = place.name
            spot.countryCode = place.code
            try? modelContext.save()
        }
    }
}

/// All spots as pins; the map auto-frames them.
private struct SpotsMap: View {
    let spots: [Spot]

    var body: some View {
        Map {
            ForEach(spots) { spot in
                Marker(
                    spot.name,
                    systemImage: "figure.open.water.swim",
                    coordinate: CLLocationCoordinate2D(latitude: spot.centerLatitude, longitude: spot.centerLongitude)
                )
                .tint(.teal)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SpotRow: View {
    let spot: Spot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spot.name)
                .font(.headline)
            Text(SpotStats(spot).summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
