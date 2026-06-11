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
                LabeledContent("Max depth", value: String(format: "%.1f m", domain.maxDepthMeters))
                if let average = domain.averageSurfaceInterval {
                    LabeledContent(
                        "Avg surface",
                        value: Duration.seconds(average).formatted(.time(pattern: .minuteSecond))
                    )
                }
            }

            Section("Location") {
                if let location = domain.location {
                    SessionMapView(location: location)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } else {
                    // GPS rarely fixes underwater, so a missing location is normal.
                    Label("No location recorded", systemImage: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }

            stravaSection(domain)

            if domain.dives.isEmpty {
                ContentUnavailableView(
                    "No Dives",
                    systemImage: "chart.xyaxis.line",
                    description: Text("This session has no recorded dives.")
                )
            } else {
                ForEach(Array(domain.dives.enumerated()), id: \.element.id) { index, dive in
                    Section("Dive \(index + 1) · \(String(format: "%.1f m", dive.maxDepthMeters)) max") {
                        DepthChartView(dive: dive)
                    }
                }
            }
        }
        .navigationTitle(domain.startTime.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func stravaSection(_ domain: DiveSession) -> some View {
        Section("Strava") {
            if exportStatus == .uploaded {
                Label("Exported to Strava", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(action: { Task { await export(domain) } }) {
                    HStack {
                        Label("Export to Strava", systemImage: "square.and.arrow.up")
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
