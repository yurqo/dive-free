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

    var body: some View {
        let domain = session.toDomain()
        List {
            Section {
                LabeledContent("Date", value: domain.startTime.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Dives", value: "\(domain.diveCount)")
                LabeledContent("Max depth", value: DepthFormat.string(domain.maxDepthMeters))
                if let average = domain.averageSurfaceInterval {
                    LabeledContent(
                        "Avg surface",
                        value: Duration.seconds(average).formatted(.time(pattern: .minuteSecond))
                    )
                }
            }

            Section("Location") {
                if !domain.track.isEmpty {
                    // Full surface path + dive points + markers when we recorded a track.
                    SessionTrackMapView(session: domain)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                } else if let location = domain.location {
                    SessionMapView(location: location)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } else {
                    // GPS rarely fixes underwater, so a missing location is normal.
                    Label("No location recorded", systemImage: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }

            markersSection(domain)

            stravaSection(domain)

            if domain.dives.isEmpty {
                ContentUnavailableView(
                    "No Dives",
                    systemImage: "chart.xyaxis.line",
                    description: Text("This session has no recorded dives.")
                )
            } else {
                ForEach(Array(domain.dives.enumerated()), id: \.element.id) { index, dive in
                    Section("Dive \(index + 1) · \(DepthFormat.string(dive.maxDepthMeters)) max") {
                        DepthChartView(dive: dive, markers: domain.markers)
                    }
                }
            }
        }
        .navigationTitle(domain.startTime.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
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
