import SwiftUI
import Domain
import Persistence
import Strava

/// Per-session detail: summary stats plus a depth-profile chart for each dive,
/// stacked and scrollable for multi-dive sessions.
struct SessionDetailView: View {
    let session: SessionRecord
    @Environment(StravaAuthManager.self) private var strava

    private enum ExportStatus: Equatable {
        case idle, uploading, uploaded, failed(String)
    }
    @State private var exportStatus: ExportStatus = .idle
    @State private var showFullMap = false

    /// Drives the single edit/crop/share sheet. Multiple `.sheet(item:)` modifiers
    /// on one view can mis-fire in SwiftUI (only one presents reliably), so they all
    /// share one `.sheet(item:)`.
    private enum ActiveSheet: Identifiable {
        case edit, crop
        /// An exported file to hand off to the system share sheet.
        case share(URL)

        var id: String {
            switch self {
            case .edit: "edit"
            case .crop: "crop"
            case .share(let url): "share:\(url.path)"
            }
        }
    }
    @State private var activeSheet: ActiveSheet?

    /// Set when an export can't be produced (FIT without location/time data) or a
    /// temp-file write fails.
    @State private var exportError: LocalizedStringKey?
    private var isShowingExportError: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    var body: some View {
        let domain = session.toDomain()
        List {
            Section {
                LabeledContent("Date", value: domain.startTime.formatted(date: .abbreviated, time: .shortened))
                if let name = domain.locationName, !name.isEmpty {
                    LabeledContent("Area", value: name)
                }
                LabeledContent("Total", value: Duration.seconds(domain.totalDuration).formatted(.time(pattern: .hourMinuteSecond)))
                LabeledContent("Dives", value: "\(domain.diveCount)")
                LabeledContent("Max depth", value: DepthFormat.string(domain.maxDepthMeters))
                if let average = domain.averageSurfaceInterval {
                    LabeledContent(
                        "Avg surface",
                        value: Duration.seconds(average).formatted(.time(pattern: .minuteSecond))
                    )
                }
                if domain.surfaceDistanceMeters >= 1 {
                    LabeledContent("Distance", value: DistanceFormat.string(domain.surfaceDistanceMeters))
                }
                if let rating = domain.rating {
                    LabeledContent("Rating") { StarRating(rating: rating) }
                }
            }

            if let notes = domain.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            conditionsSection(domain)

            weatherSection(domain)

            SessionPhotosSection(session: session)

            chartsSection(domain)

            segmentsSection(domain)

            MarkerListSection(markers: domain.markers, session: session)

            // Full session map.
            locationSection(domain)

            // Export lives at the very bottom, under the map.
            stravaSection(domain)

            // iCloud sync status — surfaces the actual CloudKit error if a
            // cross-device sync (e.g. this session's photos) is failing.
            Section("iCloud Sync") {
                CloudKitSyncStatusRows()
            }
        }
        .navigationTitle(domain.title ?? domain.startTime.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .task { reconcileVoiceNotes() }
        .fullScreenCover(isPresented: $showFullMap) { fullMap(domain) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .edit: SessionEditView(session: session)
            case .crop: NavigationStack { SessionCropView(session: session) }
            case .share(let url): ActivityView(activityItems: [url])
            }
        }
        .alert("Export failed", isPresented: isShowingExportError, presenting: exportError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Edit") {
                    Button("Edit Details") { activeSheet = .edit }
                    // A live/mirrored session (no endTime) can't be cropped —
                    // applyCrop would force-finalize it. Only offer it once the
                    // session has ended.
                    if domain.endTime != nil {
                        Button("Crop Session…") { activeSheet = .crop }
                    }
                    Menu("Export…") {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.displayName) { export(domain, as: format) }
                        }
                    }
                }
            }
        }
    }

    /// Serializes `domain` in `format`, writes a temp file, and presents the share
    /// sheet. Surfaces an alert when the format can't be produced (FIT without
    /// location/time data) or the temp-file write fails — never crashes.
    private func export(_ domain: DiveSession, as format: ExportFormat) {
        do {
            if let url = try format.writeTempFile(for: domain) {
                activeSheet = .share(url)
            } else {
                exportError = "Not enough location/time data for FIT."
            }
        } catch {
            exportError = "Couldn't write the export file. Please try again."
        }
    }

    // MARK: - Weather

    @ViewBuilder
    private func weatherSection(_ domain: DiveSession) -> some View {
        if let weather = domain.weather, !weather.isEmpty {
            Section("Weather") {
                if let condition = weather.conditionDescription {
                    LabeledContent("Conditions", value: condition)
                }
                if let wind = WindSpeedFormat.summary(speedKmh: weather.windSpeedKmh, directionDegrees: weather.windDirectionDegrees) {
                    LabeledContent("Wind", value: wind)
                }
                if let wave = weather.waveHeightMeters {
                    LabeledContent("Waves", value: String(format: "%.1f m", wave))
                }
            }
        }
    }

    // MARK: - Conditions

    @ViewBuilder
    private func conditionsSection(_ domain: DiveSession) -> some View {
        let c = domain.conditions
        if !c.isEmpty {
            Section("Conditions") {
                if let v = c.visibility { LabeledContent("Visibility", value: v.label) }
                if let current = c.current { LabeledContent("Current", value: current.label) }
                if let s = c.surface { LabeledContent("Surface", value: s.label) }
                if let t = c.tide { LabeledContent("Tide", value: t.label) }
                if let wt = c.waterTemperatureCelsius {
                    LabeledContent("Water temp", value: TemperatureFormat.string(wt))
                }
                if let at = c.airTemperatureCelsius {
                    LabeledContent("Air temp", value: TemperatureFormat.string(at))
                }
            }
        }
    }

    // MARK: - Location

    /// The session map: full surface path + dive/marker points when a track was
    /// recorded, else a single dive-site pin. Non-interactive inline; tap to open
    /// the full interactive map.
    @ViewBuilder
    private func locationSection(_ domain: DiveSession) -> some View {
        Section("Location") {
            if !domain.track.isEmpty {
                mapPreview { SessionTrackMapView(session: domain, interactive: false) }
                Toggle("Smooth GPS track", isOn: Binding(
                    get: { session.smoothTrack },
                    set: { session.smoothTrack = $0 }
                ))
            } else if let location = domain.location {
                mapPreview { SessionMapView(location: location, interactive: false) }
            } else {
                // GPS rarely fixes underwater, so a missing location is normal.
                Label("No location recorded", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mapPreview<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(height: 220)
            .listRowInsets(EdgeInsets())
            .contentShape(Rectangle())
            .onTapGesture { showFullMap = true }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.callout)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
            }
    }

    @ViewBuilder
    private func fullMap(_ domain: DiveSession) -> some View {
        NavigationStack {
            Group {
                if !domain.track.isEmpty {
                    SessionTrackMapView(session: domain, interactive: true).ignoresSafeArea()
                } else if let location = domain.location {
                    SessionMapView(location: location, interactive: true).ignoresSafeArea()
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showFullMap = false }
                }
            }
        }
    }

    // MARK: - Segments

    /// The session timeline: surface intervals and dives, each with start offset,
    /// duration, and (for dives) max depth. Dive rows push the depth profile.
    @ViewBuilder
    private func segmentsSection(_ domain: DiveSession) -> some View {
        let segments = domain.segments
        if !segments.isEmpty {
            Section("Segments") {
                ForEach(segments) { segment in
                    if let dive = segment.dive {
                        // Dive → depth profile (with markers).
                        NavigationLink {
                            DiveDetailView(
                                dive: dive,
                                index: diveNumber(of: dive, in: domain),
                                markers: domain.markers,
                                heartRateSamples: domain.heartRateSamples,
                                temperatureSamples: domain.temperatureSamples
                            )
                        } label: {
                            segmentRow(segment, sessionStart: domain.startTime, hasAudio: segmentHasAudio(segment, in: domain))
                        }
                    } else {
                        // Surface → that leg's static map, distance/time, markers.
                        NavigationLink {
                            SurfaceDetailView(session: domain, segment: segment)
                        } label: {
                            segmentRow(segment, sessionStart: domain.startTime, hasAudio: segmentHasAudio(segment, in: domain))
                        }
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: SessionSegment, sessionStart: Date, hasAudio: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: segment.isDive ? "arrow.down" : "water.waves")
                .foregroundStyle(segment.isDive ? .teal : .blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.isDive ? "Dive" : "Surface")
                HStack(spacing: 4) {
                    Text("+" + offset(segment.startTime, from: sessionStart)
                         + (segment.markerCount > 0 ? "  📍\(segment.markerCount)" : ""))
                        .monospacedDigit()
                    // Flags a segment whose markers carry a voice note.
                    if hasAudio {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.teal)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Duration.seconds(segment.duration).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                if let dive = segment.dive {
                    Text(DepthFormat.string(dive.maxDepthMeters))
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .monospacedDigit()
                } else if segment.distanceMeters >= 1 {
                    Text(DistanceFormat.string(segment.distanceMeters))
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .monospacedDigit()
                }
            }
        }
    }

    private func offset(_ time: Date, from start: Date) -> String {
        Duration.seconds(time.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond))
    }

    private func diveNumber(of dive: Dive, in domain: DiveSession) -> Int {
        (domain.dives.sorted { $0.startTime < $1.startTime }.firstIndex { $0.id == dive.id } ?? 0) + 1
    }

    /// Whether any marker in this segment's window carries a voice note.
    private func segmentHasAudio(_ segment: SessionSegment, in domain: DiveSession) -> Bool {
        domain.markers.contains {
            $0.audioFileName != nil && $0.timestamp >= segment.startTime && $0.timestamp <= segment.endTime
        }
    }

    /// Bridges voice-note files and their CloudKit-synced bytes both ways (#169):
    /// uploads local-only clips (sets `audioData`) so they sync, and materializes
    /// synced-only clips (writes the file) so they play on this device. Runs when
    /// the detail view appears; only touches files when one side is missing, so the
    /// same-device path is unaffected.
    private func reconcileVoiceNotes() {
        guard session.modelContext != nil else { return } // skip a deleted session (#148)
        var changed = false
        for marker in (session.markers ?? []) {
            guard let name = marker.audioFileName else { continue }
            if VoiceNoteStore.mirrorAudioData(into: marker) {     // local file → CloudKit
                changed = true
            } else if let data = marker.audioData, !VoiceNoteStore.exists(name) {
                if VoiceNoteStore.materialize(data, as: name) {  // CloudKit → local file
                    NotificationCenter.default.post(name: .voiceNoteReceived, object: nil)
                }
            }
        }
        if changed { try? session.modelContext?.save() }
    }

    /// Whole-session heart-rate and water-temperature charts (each shown only when
    /// that series has data — e.g. no temperature on a non-Ultra watch).
    @ViewBuilder
    private func chartsSection(_ domain: DiveSession) -> some View {
        if !domain.heartRateSamples.isEmpty {
            Section("Heart rate") {
                MetricChartView(heartRate: domain.heartRateSamples)
            }
        }
        if !domain.temperatureSamples.isEmpty {
            Section("Temperature") {
                MetricChartView(temperature: domain.temperatureSamples)
            }
        }
    }

    @ViewBuilder
    private func stravaSection(_ domain: DiveSession) -> some View {
        Section("Strava") {
            if exportStatus == .uploaded {
                Label("Exported to Strava", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                let isFailed = { if case .failed = exportStatus { return true } else { return false } }()
                Button(action: { Task { await export(domain) } }) {
                    HStack {
                        Label(
                            isFailed ? "Retry Export" : "Export to Strava",
                            systemImage: isFailed ? "arrow.clockwise" : "square.and.arrow.up"
                        )
                        if exportStatus == .uploading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(exportStatus == .uploading || !strava.isConnected)

                if !strava.isConnected {
                    Text("Connect Strava in Settings to export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = exportStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func export(_ domain: DiveSession) async {
        exportStatus = .uploading
        do {
            try await StravaExport.export(domain, auth: strava, uploader: StravaClient())
            exportStatus = .uploaded
        } catch StravaError.notAuthenticated {
            exportStatus = .failed("Connect Strava in Settings first.")
        } catch StravaError.rateLimited {
            exportStatus = .failed("Strava rate limit reached. Try again later.")
        } catch StravaError.uploadFailed(let message) {
            exportStatus = .failed(message)
        } catch StravaError.uploadTimedOut {
            exportStatus = .failed("Strava is still processing the upload. Check Strava in a minute.")
        } catch {
            exportStatus = .failed("Export failed. Please try again.")
        }
    }
}

private struct SessionDetailPreview: View {
    // SessionDetailView reads the record directly (no @Query), so no container needed.
    private let record: SessionRecord = {
        let t0 = Date()
        let sample = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(1_200),
            dives: [
                Dive(
                    startTime: t0.addingTimeInterval(30),
                    endTime: t0.addingTimeInterval(90),
                    maxDepthMeters: 14.2,
                    samples: (0...12).map { i in
                        DepthSample(timestamp: t0.addingTimeInterval(30 + Double(i) * 5), depthMeters: Double(i) * 1.2)
                    }
                )
            ],
            location: GeoPoint(latitude: 20.5, longitude: -87.0),
            heartRateSamples: (0...120).map { i in
                HeartRateSample(timestamp: t0.addingTimeInterval(Double(i) * 10), bpm: 70 + 25 * sin(Double(i) / 6))
            },
            temperatureSamples: (0...120).map { i in
                TemperatureSample(timestamp: t0.addingTimeInterval(Double(i) * 10), celsius: 20 + 2 * cos(Double(i) / 8))
            }
        )
        return SessionRecord(from: sample)
    }()

    var body: some View {
        NavigationStack {
            SessionDetailView(session: record)
        }
        .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
        .environment(PhotoPagerPresenter())
        .environment(PhotoSuggestionPresenter())
        .environment(CloudKitSyncMonitor())
    }
}

#Preview {
    SessionDetailPreview()
}

/// A "Markers" list section: one row per marker (emoji, label, optional note,
/// a play button when a voice note is attached, and the clock time). Shared by
/// the whole-session detail and the per-segment dive/surface detail screens.
struct MarkerListSection: View {
    let markers: [EventMarker]
    /// When provided, rows are tappable to edit the matching record (#143).
    var session: SessionRecord? = nil
    @State private var editing: MarkerRecord?

    var body: some View {
        if !markers.isEmpty {
            Section("Markers") {
                ForEach(markers.sorted { $0.timestamp < $1.timestamp }) { marker in
                    let record = session.flatMap { session in (session.markers ?? []).first { $0.id == marker.id } }
                    MarkerRow(marker: marker)
                        .contentShape(Rectangle())
                        .onTapGesture { if let record { editing = record } }
                }
            }
            .sheet(item: $editing) { record in
                if let session { MarkerEditView(marker: record, session: session) }
            }
        }
    }
}

private struct MarkerRow: View {
    let marker: EventMarker

    var body: some View {
        HStack(spacing: 12) {
            Text(marker.kind.emoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(marker.kind.label)
                if let text = marker.text, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fileName = marker.audioFileName {
                    VoiceNotePlayButton(fileName: fileName)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            Spacer()
            Text(marker.timestamp, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
