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

    var body: some View {
        let domain = session.toDomain()
        List {
            Section {
                LabeledContent("Date", value: domain.startTime.formatted(date: .abbreviated, time: .shortened))
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
                    LabeledContent("Distance", value: distanceText(domain.surfaceDistanceMeters))
                }
            }

            segmentsSection(domain)

            markersSection(domain)

            stravaSection(domain)

            // Full session map at the bottom.
            locationSection(domain)
        }
        .navigationTitle(domain.startTime.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullMap) { fullMap(domain) }
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
                            DiveDetailView(dive: dive, index: diveNumber(of: dive, in: domain), markers: domain.markers)
                        } label: {
                            segmentRow(segment, sessionStart: domain.startTime)
                        }
                    } else {
                        // Surface → that leg's path on the map (with markers).
                        NavigationLink {
                            SessionTrackMapView(session: domain, range: segment.startTime...segment.endTime)
                                .ignoresSafeArea()
                                .navigationTitle("Surface")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            segmentRow(segment, sessionStart: domain.startTime)
                        }
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: SessionSegment, sessionStart: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: segment.isDive ? "arrow.down" : "water.waves")
                .foregroundStyle(segment.isDive ? .teal : .blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.isDive ? "Dive" : "Surface")
                Text("+" + offset(segment.startTime, from: sessionStart)
                     + (segment.markerCount > 0 ? "  📍\(segment.markerCount)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
                    Text(distanceText(segment.distanceMeters))
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

    private func distanceText(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
    }

    @ViewBuilder
    private func markersSection(_ domain: DiveSession) -> some View {
        if !domain.markers.isEmpty {
            Section("Markers") {
                ForEach(domain.markers.sorted { $0.timestamp < $1.timestamp }) { marker in
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
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
        return SessionRecord(from: sample)
    }()

    var body: some View {
        NavigationStack {
            SessionDetailView(session: record)
        }
        .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
    }
}

#Preview {
    SessionDetailPreview()
}
