import SwiftUI
import Charts
import AVFoundation
import Domain

/// Depth-over-time profile for a single dive on the watch — a compact line chart
/// (Y inverted so depth increases downward) with any markers placed at the depth
/// they landed, max depth + duration, and the markers placed during the dive.
/// Pushed from a dive row in the session summary's segment list.
struct WatchDiveProfileView: View {
    let dive: Dive
    var markers: [EventMarker] = []
    var heartRateSamples: [HeartRateSample] = []
    var temperatureSamples: [TemperatureSample] = []

    /// Markers placed during this dive's window.
    private var diveMarkers: [EventMarker] {
        markers.filter { $0.timestamp >= dive.startTime && $0.timestamp <= dive.endTime }
    }

    private struct Placed: Identifiable {
        let id: UUID
        let emoji: String
        let secondsFromStart: TimeInterval
        let depthMeters: Double
    }

    private var placed: [Placed] {
        diveMarkers.compactMap { marker in
            guard let depth = dive.interpolatedDepth(at: marker.timestamp) else { return nil }
            return Placed(
                id: marker.id,
                emoji: marker.kind.emoji,
                secondsFromStart: marker.timestamp.timeIntervalSince(dive.startTime),
                depthMeters: depth
            )
        }
    }

    var body: some View {
        let points = dive.depthProfile
        ScrollView {
            VStack(spacing: 10) {
                if points.isEmpty {
                    ContentUnavailableView("No profile", systemImage: "chart.xyaxis.line")
                } else {
                    Chart {
                        ForEach(points) { point in
                            LineMark(
                                x: .value("Elapsed", point.secondsFromStart),
                                y: .value("Depth", point.depthMeters)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.teal)
                        }
                        ForEach(placed) { marker in
                            PointMark(
                                x: .value("Elapsed", marker.secondsFromStart),
                                y: .value("Depth", marker.depthMeters)
                            )
                            .symbolSize(0)
                            .annotation(position: .overlay, spacing: 0) {
                                Text(marker.emoji).font(.caption2)
                            }
                        }
                    }
                    // Depth increases downward: reverse Y and keep the surface in view.
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .frame(height: 130)
                }

                HStack(spacing: 16) {
                    segmentMetric("Max", DepthFormat.string(dive.maxDepthMeters))
                    segmentMetric("Time", Duration.seconds(dive.duration).formatted(.time(pattern: .minuteSecond)))
                }

                watchMetricCharts(heartRate: heartRateSamples, temperature: temperatureSamples, in: dive.startTime...dive.endTime)

                WatchMarkerList(markers: diveMarkers)
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Dive")
    }
}

/// A single surface interval's detail on the watch: a static map of that leg's
/// path (tap to push the full zoomable map), its distance and duration, and any
/// markers placed during it. Pushed from a surface row in the segment list.
struct WatchSurfaceDetailView: View {
    let session: DiveSession
    let segment: SessionSegment

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
        ScrollView {
            VStack(spacing: 10) {
                if hasPath {
                    // Static (non-zoomable) preview, sized like the dive profile;
                    // tap pushes the full interactive map for this leg.
                    NavigationLink {
                        WatchSessionMapView(session: session, interactive: true, range: range)
                            .ignoresSafeArea()
                            .navigationTitle("Surface")
                    } label: {
                        WatchSessionMapView(session: session, interactive: false, range: range)
                            .frame(height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .allowsHitTesting(false)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(5)
                            }
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 16) {
                    segmentMetric("Distance", DistanceFormat.string(segment.distanceMeters))
                    segmentMetric("Time", Duration.seconds(segment.duration).formatted(.time(pattern: .minuteSecond)))
                }

                watchMetricCharts(heartRate: session.heartRateSamples, temperature: session.temperatureSamples, in: range)

                WatchMarkerList(markers: surfaceMarkers)
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Surface")
    }
}

/// Stacked value-over-label metric used by the watch segment detail screens.
private func segmentMetric(_ label: String, _ value: String) -> some View {
    VStack(spacing: 1) {
        Text(value)
            .font(.headline)
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// A compact "Markers" list for a segment on the watch: each marker's emoji +
/// label, optional note text, a play button when a voice note is attached, and
/// the time. Hidden when there are no markers.
struct WatchMarkerList: View {
    let markers: [EventMarker]

    var body: some View {
        if !markers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Markers")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(markers.sorted { $0.timestamp < $1.timestamp }) { marker in
                    row(marker)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ marker: EventMarker) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker.kind.emoji)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(marker.kind.label).font(.caption)
                    Spacer()
                    Text(marker.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let text = marker.text, !text.isEmpty {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let fileName = marker.audioFileName {
                    WatchVoiceNotePlayButton(fileName: fileName)
                }
            }
        }
    }
}

/// Plays a marker's voice note on the watch from the local VoiceNotes directory
/// (where `AudioNoteRecorder` saved it during the session). Disabled if the file
/// is missing.
struct WatchVoiceNotePlayButton: View {
    let fileName: String

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var duration: TimeInterval?

    private var url: URL { AudioNoteRecorder.url(for: fileName) }
    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        Button {
            isPlaying ? stop() : play()
        } label: {
            Label(buttonLabel, systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .foregroundStyle(exists ? .teal : .secondary)
        // Read the clip length once so the row shows its duration before playing.
        .onAppear { if exists, duration == nil { duration = try? AVAudioPlayer(contentsOf: url).duration } }
    }

    /// "Play" / "Stop" with the clip length appended once it's known.
    private var buttonLabel: String {
        let base = isPlaying ? "Stop" : "Play"
        guard let duration else { return base }
        return "\(base) · \(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond)))"
    }

    private func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.play()
            player = newPlayer
            isPlaying = true
            // Reset when the clip finishes (unless stopped or replaced first).
            Task {
                try? await Task.sleep(for: .seconds(max(newPlayer.duration, 0.1)))
                if player === newPlayer { stop() }
            }
        } catch {
            isPlaying = false
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        // Release the session so other audio can resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Compact time-series line chart for a watch metric (heart rate, temperature),
/// for the whole session or a single segment's window.
struct WatchMetricChart: View {
    struct Point: Identifiable { let id: Int; let date: Date; let value: Double }
    let title: String
    let tint: Color
    let points: [Point]

    var isEmpty: Bool { points.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart(points) { point in
                LineMark(x: .value("Time", point.date), y: .value(title, point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
            }
            .frame(height: 70)
        }
    }
}

extension WatchMetricChart {
    init(heartRate samples: [HeartRateSample], in range: ClosedRange<Date>? = nil) {
        self.init(title: "Heart rate (bpm)", tint: .red, points: Self.points(samples.map { ($0.timestamp, $0.bpm) }, in: range))
    }

    init(temperature samples: [TemperatureSample], in range: ClosedRange<Date>? = nil) {
        self.init(title: "Temp (°C)", tint: .green, points: Self.points(samples.map { ($0.timestamp, $0.celsius) }, in: range))
    }

    private static func points(_ raw: [(Date, Double)], in range: ClosedRange<Date>?) -> [Point] {
        raw.filter { range?.contains($0.0) ?? true }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { Point(id: $0, date: $1.0, value: $1.1) }
    }
}

/// Heart-rate + temperature charts for a window, each omitted when it has no data.
@ViewBuilder
func watchMetricCharts(heartRate: [HeartRateSample], temperature: [TemperatureSample], in range: ClosedRange<Date>?) -> some View {
    let hr = WatchMetricChart(heartRate: heartRate, in: range)
    let temp = WatchMetricChart(temperature: temperature, in: range)
    if !hr.isEmpty { hr }
    if !temp.isEmpty { temp }
}
