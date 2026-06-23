import SwiftUI
import SwiftData
import MapKit
import Domain
import Persistence

/// The Spots tab: a map of every dive spot plus a list (name, dives, last dived).
struct SpotsListView: View {
    @Query(sort: \Spot.name) private var spots: [Spot]

    var body: some View {
        NavigationStack {
            Group {
                if spots.isEmpty {
                    ContentUnavailableView(
                        "No Spots Yet",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Dive spots appear here as you log sessions on your Apple Watch.")
                    )
                } else {
                    List {
                        Section {
                            SpotsMap(spots: spots)
                                .frame(height: 200)
                                .listRowInsets(EdgeInsets())
                        }
                        ForEach(spots) { spot in
                            NavigationLink(value: spot) { SpotRow(spot: spot) }
                        }
                    }
                    .navigationDestination(for: Spot.self) { SpotDetailView(spot: $0) }
                    .navigationDestination(for: SessionRecord.self) { SessionDetailView(session: $0) }
                }
            }
            .navigationTitle("Spots")
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
