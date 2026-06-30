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
    /// Sessions geocoded this launch, so a coordinate that resolves to no name
    /// (open water, remote spots) isn't retried on every list appearance.
    @State private var geocodeAttempted: Set<UUID> = []
    /// Lightweight per-row view models, rebuilt only when the session set changes
    /// (not per scroll/redraw) — avoids deep-copying each session and re-running
    /// the track haversine on every render.
    @State private var rowCache: [PersistentIdentifier: SessionRow] = [:]

    /// `sessions` (the @Query) can briefly still contain a just-deleted record
    /// before the query refreshes; reading its properties then traps (#148). Use
    /// only live records (deleted + saved → modelContext is nil) for display.
    private var liveSessions: [SessionRecord] { sessions.filter { $0.modelContext != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if liveSessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "water.waves",
                        description: Text("Your dives show up here, and on iPhone.")
                    )
                } else {
                    List {
                        ForEach(liveSessions) { record in
                            let row = rowCache[record.persistentModelID] ?? SessionRow(record)
                            NavigationLink(value: record) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                        .font(.headline)
                                    Text(statsLine(row))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    if let name = row.locationName, !name.isEmpty {
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
                    .onChange(of: rowSignature, initial: true) { rebuildRowCache() }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionRecord.self) { record in
                // The pushed record can be deleted from inside the detail view
                // (Delete Session); SwiftUI may re-evaluate this destination with
                // the now-deleted @Model before the pop finishes, and reading a
                // deleted model's stored properties traps (#148). modelContext is
                // nil once deleted+saved, so guard on it and render nothing while
                // the pop is in flight. (#175 guarded the list rows; this is the
                // same crash on the detail-navigation path.)
                if record.modelContext != nil {
                    WatchSessionSummaryView(session: record.toDomain())
                        .navigationTitle(record.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                } else {
                    Color.clear
                }
            }
        }
    }

    /// Second-line summary: total time · distance · ↓ dives · 📍 markers.
    private func statsLine(_ row: SessionRow) -> String {
        let time = Duration.seconds(row.totalDuration).formatted(.time(pattern: .minuteSecond))
        let distance = DistanceFormat.string(row.distanceMeters)
        return "⏱\(time) · \(distance) · ↓\(row.diveCount) · 📍\(row.markerCount)"
    }

    /// Cheap signature of the displayed fields; when it changes, rebuild the row
    /// cache. Distance depends only on the track (fixed once a session is saved),
    /// so it isn't part of the signature.
    private var rowSignature: String {
        liveSessions
            .map { "\($0.persistentModelID.hashValue):\($0.locationName ?? ""):\($0.dives.count):\($0.markers.count)" }
            .joined(separator: "|")
    }

    private func rebuildRowCache() {
        rowCache = Dictionary(uniqueKeysWithValues: liveSessions.map { ($0.persistentModelID, SessionRow($0)) })
    }

    /// Resolves and persists the area name for any session missing one, one at a
    /// time (CLGeocoder expects serial requests). Runs when the list appears, so
    /// new sessions get named and older ones backfill; failures just retry next
    /// time. Skipped per-session once a name is saved, so each spot geocodes once.
    private func backfillLocationNames() async {
        for record in liveSessions {
            if Task.isCancelled { return }
            // The record can be deleted while we await an earlier one; reading or
            // writing a deleted model traps (#148). modelContext is nil once deleted.
            guard record.modelContext != nil else { continue }
            guard record.locationName == nil,
                  !record.locationNameEdited,
                  !geocodeAttempted.contains(record.id),
                  let lat = record.latitude, let lon = record.longitude else { continue }
            // Mark attempted up front so a coordinate that geocodes to nothing
            // isn't re-tried this launch; a fresh launch clears it and retries
            // (e.g. after the watch regains connectivity).
            geocodeAttempted.insert(record.id)
            guard let name = await LocationName.resolve(latitude: lat, longitude: lon),
                  !name.isEmpty else { continue }
            // The session may have been deleted during the await.
            guard record.modelContext != nil else { continue }
            record.locationName = name
            try? modelContext.save()
        }
    }
}

/// Lightweight, precomputed view model for a session-list row: scalar fields read
/// directly from the record plus the surface distance — without deep-copying the
/// whole session (`toDomain`) per render.
private struct SessionRow {
    let startTime: Date
    let totalDuration: TimeInterval
    let diveCount: Int
    let markerCount: Int
    let distanceMeters: Double
    let locationName: String?

    init(_ record: SessionRecord) {
        startTime = record.startTime
        totalDuration = (record.endTime ?? record.startTime).timeIntervalSince(record.startTime)
        diveCount = record.dives.count
        markerCount = record.markers.count
        // Distance from the track only (no dives/samples copy); honors smoothTrack.
        distanceMeters = DiveSession(
            startTime: record.startTime, track: record.track, smoothTrack: record.smoothTrack
        ).surfaceDistanceMeters
        locationName = record.locationName
    }
}
