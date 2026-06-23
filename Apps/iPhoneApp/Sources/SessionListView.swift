import SwiftUI
import SwiftData
import Domain
import Persistence
import Sensors
import Strava

/// Phone home screen: the dive history. Charts, maps, and Strava export
/// hang off the per-session detail (Phases 6 & 7).
struct SessionListView: View {
    @Query(sort: \SessionRecord.startTime, order: .reverse)
    private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext
    /// Sessions geocoded this launch, so a coordinate that resolves to no name
    /// (open water, remote spots) isn't retried on every list appearance.
    @State private var geocodeAttempted: Set<UUID> = []
    /// Sessions whose weather fetch was attempted this launch (a failed fetch
    /// isn't persisted, so it retries on a later launch when back online).
    @State private var weatherAttempted: Set<UUID> = []

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
                                    if let title = domain.title, !title.isEmpty {
                                        Text(title)
                                            .font(.headline)
                                        Text(session.startTime, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(session.startTime, style: .date)
                                            .font(.headline)
                                    }
                                    if let rating = domain.rating {
                                        StarRating(rating: rating)
                                            .font(.caption2)
                                    }
                                    Text(statsLine(domain, photoCount: session.photos.count))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let name = domain.locationName, !name.isEmpty {
                                        Label(name, systemImage: "mappin.and.ellipse")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .labelStyle(.titleAndIcon)
                                            .lineLimit(1)
                                    }
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
                    .task { await backfillLocationNames(); assignSpots() }
                    .task { await backfillWeather() }
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

    /// Row subtitle: dive count, max depth, and a photo count when present.
    private func statsLine(_ domain: DiveSession, photoCount: Int) -> String {
        var line = "\(domain.diveCount) dives · max \(DepthFormat.string(domain.maxDepthMeters))"
        if photoCount > 0 { line += " · 📷\(photoCount)" }
        return line
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            // SwiftData cascade-deletes the PhotoRecords; remove their files too.
            for photo in session.photos { PhotoStore.delete(photo.fileName) }
            modelContext.delete(session)
        }
        try? modelContext.save()
    }

    /// Resolves and persists the area name for any session missing one (e.g. a
    /// session synced from a watch that never got connectivity to geocode), one at
    /// a time — CLGeocoder expects serial requests. Mirrors the watch backfill:
    /// runs on appear, skips a session once attempted this launch, and never
    /// overwrites an existing (possibly user-edited) name.
    private func backfillLocationNames() async {
        for session in sessions {
            if Task.isCancelled { return }
            // A session can be deleted while we await an earlier one; reading or
            // writing a deleted SwiftData model crashes (#148). modelContext is
            // nil once an object has been deleted and saved.
            guard session.modelContext != nil else { continue }
            guard session.locationName == nil,
                  !session.locationNameEdited,
                  !geocodeAttempted.contains(session.id),
                  let lat = session.latitude, let lon = session.longitude else { continue }
            geocodeAttempted.insert(session.id)
            guard let name = await LocationName.resolve(latitude: lat, longitude: lon),
                  !name.isEmpty else { continue }
            // Re-check: this session may have been deleted during the await.
            guard session.modelContext != nil else { continue }
            session.locationName = name
            try? modelContext.save()
        }
    }

    /// Assigns any located, spot-less session to a dive spot (nearest within
    /// radius, else a new one named from its area). Runs after geocoding so a new
    /// spot gets the resolved area name; idempotent, so it also backfills existing
    /// sessions on first launch.
    private func assignSpots() {
        _ = try? SpotAssigner(context: modelContext).assignUnassignedSessions()
    }

    /// Fetches weather + marine data for any session missing it, one at a time,
    /// time-boxed. A success persists (`weatherFetched`) so it never refetches; a
    /// failure (offline) isn't persisted, so a later online launch retries — the
    /// historical/forecast endpoint keeps a late fetch accurate for the dive time.
    /// Fetched air/sea temperatures pre-fill the manual conditions where unset.
    private func backfillWeather() async {
        for session in sessions {
            if Task.isCancelled { return }
            // Skip a session deleted while we awaited an earlier one (#148).
            guard session.modelContext != nil else { continue }
            guard !session.weatherFetched,
                  !weatherAttempted.contains(session.id),
                  let lat = session.latitude, let lon = session.longitude else { continue }
            weatherAttempted.insert(session.id)
            guard let snapshot = await WeatherProvider.fetch(latitude: lat, longitude: lon, date: session.startTime) else { continue }
            // Re-check: this session may have been deleted during the await.
            guard session.modelContext != nil else { continue }
            session.weather = snapshot.weather
            session.weatherFetched = true
            // Pre-fill manual conditions where the user hasn't entered a value.
            if session.airTemperatureCelsius == nil { session.airTemperatureCelsius = snapshot.airTemperatureCelsius }
            if session.waterTemperatureCelsius == nil { session.waterTemperatureCelsius = snapshot.seaTemperatureCelsius }
            try? modelContext.save()
        }
    }
}

#Preview {
    SessionListView()
        .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
        .modelContainer(for: SessionRecord.self, inMemory: true)
}
