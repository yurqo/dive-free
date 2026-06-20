import SwiftUI
import Domain

/// A single dive's detail: headline figures, its depth-profile chart, and the
/// markers placed during the dive. Pushed from a dive row in the session's
/// segment list.
struct DiveDetailView: View {
    let dive: Dive
    let index: Int
    var markers: [EventMarker] = []
    var heartRateSamples: [HeartRateSample] = []
    var temperatureSamples: [TemperatureSample] = []

    /// Markers placed during this dive's window.
    private var diveMarkers: [EventMarker] {
        markers.filter { $0.timestamp >= dive.startTime && $0.timestamp <= dive.endTime }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Max depth", value: DepthFormat.string(dive.maxDepthMeters))
                LabeledContent("Duration", value: Duration.seconds(dive.duration).formatted(.time(pattern: .minuteSecond)))
                LabeledContent("Start", value: dive.startTime.formatted(date: .omitted, time: .standard))
            }
            Section("Depth profile") {
                DepthChartView(dive: dive, markers: diveMarkers)
            }
            metricChartSection("Heart rate", MetricChartView(heartRate: heartRateSamples, in: dive.startTime...dive.endTime))
            metricChartSection("Temperature", MetricChartView(temperature: temperatureSamples, in: dive.startTime...dive.endTime))
            MarkerListSection(markers: diveMarkers)
        }
        .navigationTitle("Dive \(index)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A single surface interval's detail: a static map of that leg's path (the same
/// size as a dive's depth profile; tap it to open the full zoomable map), its
/// distance and duration, and any markers placed during it. Pushed from a surface
/// row in the session's segment list.
struct SurfaceDetailView: View {
    let session: DiveSession
    let segment: SessionSegment

    @State private var showFullMap = false

    private var range: ClosedRange<Date> { segment.startTime...segment.endTime }

    /// Markers placed during this surface interval.
    private var surfaceMarkers: [EventMarker] {
        session.markers.filter { $0.timestamp >= segment.startTime && $0.timestamp <= segment.endTime }
    }

    /// Whether this leg has a surface path to draw.
    private var hasPath: Bool {
        session.track.contains { range.contains($0.timestamp) }
    }

    var body: some View {
        List {
            if hasPath {
                Section {
                    // Static (non-zoomable) preview, sized like the dive profile;
                    // tap opens the full interactive map for this leg.
                    SessionTrackMapView(session: session, interactive: false, range: range)
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
            }
            Section {
                LabeledContent("Distance", value: DistanceFormat.string(segment.distanceMeters))
                LabeledContent("Duration", value: Duration.seconds(segment.duration).formatted(.time(pattern: .minuteSecond)))
                LabeledContent("Start", value: segment.startTime.formatted(date: .omitted, time: .standard))
            }
            metricChartSection("Heart rate", MetricChartView(heartRate: session.heartRateSamples, in: range))
            metricChartSection("Temperature", MetricChartView(temperature: session.temperatureSamples, in: range))
            MarkerListSection(markers: surfaceMarkers)
        }
        .navigationTitle("Surface")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullMap) {
            NavigationStack {
                SessionTrackMapView(session: session, interactive: true, range: range)
                    .ignoresSafeArea()
                    .navigationTitle("Surface")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showFullMap = false }
                        }
                    }
            }
        }
    }
}

/// Wraps a metric chart in a titled `Section`, omitting it entirely when the
/// chart has no points in range (e.g. no temperature on a non-Ultra watch).
@ViewBuilder
private func metricChartSection(_ title: String, _ chart: MetricChartView) -> some View {
    if !chart.isEmpty {
        Section(title) { chart }
    }
}
