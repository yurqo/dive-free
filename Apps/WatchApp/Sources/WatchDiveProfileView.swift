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
    /// 1-based position of this dive within the session, for the "Dive #N" title.
    var number: Int?
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
                // Headline stats up top, as a table matching the session summary.
                VStack(spacing: 4) {
                    statRow("Max depth", DepthFormat.string(dive.maxDepthMeters))
                    statRow("Dive time", Duration.seconds(dive.duration).formatted(.time(pattern: .minuteSecond)))
                }

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
                                chartMarkerGlyph(marker.emoji)
                            }
                        }
                    }
                    // Depth increases downward: reverse Y and keep the surface in view.
                    .chartYScale(domain: .automatic(includesZero: true, reversed: true))
                    .frame(height: 130)
                }

                watchMetricCharts(heartRate: heartRateSamples, temperature: temperatureSamples, in: dive.startTime...dive.endTime)

                WatchMarkerList(markers: diveMarkers)
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(number.map { "Dive #\($0)" } ?? "Dive")
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

/// A label-left / value-right stat row, matching the session summary's table.
private func statRow(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
        Spacer()
        Text(value)
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
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
    @State private var currentTime: TimeInterval = 0

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

    /// "Play" / "Stop" with a time appended — the elapsed position while playing,
    /// the clip length when idle.
    private var buttonLabel: String {
        let base = isPlaying ? "Stop" : "Play"
        guard let time = isPlaying ? currentTime : duration else { return base }
        return "\(base) · \(Duration.seconds(time.rounded()).formatted(.time(pattern: .minuteSecond)))"
    }

    private func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.play()
            player = newPlayer
            currentTime = 0
            isPlaying = true
            // Tick the elapsed position for the clip's length, then reset. Bounded
            // by wall-clock rather than isPlaying (which can read false the instant
            // after play(), cutting playback off immediately).
            Task {
                let total = max(newPlayer.duration, 0.1)
                let start = Date()
                while player === newPlayer, Date().timeIntervalSince(start) < total {
                    currentTime = newPlayer.currentTime
                    try? await Task.sleep(for: .seconds(0.3))
                }
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

/// Emoji marker glyph for charts: the ink-cropped image (see `EmojiInk`) centred
/// on its point, falling back to plain text. Shared by the per-dive profile and
/// the whole-session depth chart.
@MainActor
@ViewBuilder
private func chartMarkerGlyph(_ emoji: String, fontSize: CGFloat = 12) -> some View {
    if let ink = EmojiInk.image(emoji, fontSize: fontSize) {
        ink
    } else {
        Text(emoji).font(.system(size: fontSize))
    }
}

/// Compact time-series line chart for a watch metric (heart rate, temperature),
/// for the whole session or a single segment's window.
struct WatchMetricChart: View {
    struct Point: Identifiable { let id: Int; let date: Date; let value: Double }
    /// Optional emoji markers drawn over the line (used by the depth chart).
    struct Marker: Identifiable { let id: UUID; let date: Date; let value: Double; let emoji: String }
    let title: String
    let tint: Color
    let points: [Point]
    var markers: [Marker] = []
    /// Invert the Y axis so depth increases downward. Off for heart rate / temp.
    var reversedY = false

    var isEmpty: Bool { points.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            chart
                .frame(height: 70)
        }
    }

    @ViewBuilder private var chart: some View {
        let base = Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value(title, point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
            }
            ForEach(markers) { marker in
                PointMark(x: .value("Time", marker.date), y: .value(title, marker.value))
                    .symbolSize(0)
                    .annotation(position: .overlay, spacing: 0) {
                        chartMarkerGlyph(marker.emoji)
                    }
            }
        }
        if reversedY {
            base.chartYScale(domain: .automatic(includesZero: true, reversed: true))
        } else {
            base
        }
    }
}

extension WatchMetricChart {
    init(depth samples: [DepthSample], markers: [EventMarker] = [], in range: ClosedRange<Date>? = nil) {
        self.init(
            title: DepthFormat.axisLabel(),
            tint: .teal,
            points: Self.points(samples.map { ($0.timestamp, DepthFormat.displayDepth($0.depthMeters)) }, in: range),
            markers: Self.depthMarkers(markers, on: samples, in: range),
            reversedY: true
        )
    }

    init(heartRate samples: [HeartRateSample], in range: ClosedRange<Date>? = nil) {
        self.init(title: "Heart rate (bpm)", tint: .red, points: Self.points(samples.map { ($0.timestamp, $0.bpm) }, in: range))
    }

    init(temperature samples: [TemperatureSample], in range: ClosedRange<Date>? = nil) {
        self.init(title: "Temp (\(TemperatureFormat.unitLabel()))", tint: .green, points: Self.points(samples.map { ($0.timestamp, TemperatureFormat.displayValue($0.celsius)) }, in: range))
    }

    private static func points(_ raw: [(Date, Double)], in range: ClosedRange<Date>?) -> [Point] {
        raw.filter { range?.contains($0.0) ?? true }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { Point(id: $0, date: $1.0, value: $1.1) }
    }

    /// Places each marker on the depth line at its interpolated depth, dropping
    /// any outside `range` or with no samples to land on.
    private static func depthMarkers(_ markers: [EventMarker], on samples: [DepthSample], in range: ClosedRange<Date>?) -> [Marker] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        return markers.compactMap { marker in
            guard range?.contains(marker.timestamp) ?? true,
                  let depth = interpolatedDepth(at: marker.timestamp, in: sorted) else { return nil }
            return Marker(id: marker.id, date: marker.timestamp, value: DepthFormat.displayDepth(depth), emoji: marker.kind.emoji)
        }
    }

    /// Linear-interpolated depth at `time` along the sorted samples (clamped to
    /// the ends); `nil` when there are no samples.
    private static func interpolatedDepth(at time: Date, in sorted: [DepthSample]) -> Double? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if time <= first.timestamp { return first.depthMeters }
        if time >= last.timestamp { return last.depthMeters }
        for i in 1..<sorted.count where time <= sorted[i].timestamp {
            let a = sorted[i - 1], b = sorted[i]
            let span = b.timestamp.timeIntervalSince(a.timestamp)
            guard span > 0 else { return a.depthMeters }
            let t = time.timeIntervalSince(a.timestamp) / span
            return a.depthMeters + (b.depthMeters - a.depthMeters) * t
        }
        return last.depthMeters
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
