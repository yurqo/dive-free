import SwiftUI
import Charts
import Domain

/// Time-vs-depth line chart for a single dive. The Y-axis is inverted so depth
/// increases downward (mirroring how a dive feels), and tapping the plot shows a
/// callout with the exact depth and clock time at that moment.
struct DepthChartView: View {
    let dive: Dive
    /// Markers placed during this dive, overlaid on the profile at the depth the
    /// diver was at when each landed.
    var markers: [EventMarker] = []

    /// X value (seconds from dive start) the user is scrubbing, if any.
    @State private var selectedSecond: TimeInterval?

    /// Markers that fall within this dive's window, positioned on the profile.
    private struct PlacedMarker: Identifiable {
        let id: UUID
        let emoji: String
        let secondsFromStart: TimeInterval
        let depthMeters: Double
    }

    private var placedMarkers: [PlacedMarker] {
        markers.compactMap { marker in
            guard marker.timestamp >= dive.startTime, marker.timestamp <= dive.endTime,
                  let depth = dive.interpolatedDepth(at: marker.timestamp) else { return nil }
            return PlacedMarker(
                id: marker.id,
                emoji: marker.kind.emoji,
                secondsFromStart: marker.timestamp.timeIntervalSince(dive.startTime),
                depthMeters: depth
            )
        }
    }

    /// Sample nearest the scrubbed X position, for the callout.
    private func nearestPoint(in points: [DepthProfilePoint]) -> DepthProfilePoint? {
        guard let selectedSecond else { return nil }
        return points.min {
            abs($0.secondsFromStart - selectedSecond) < abs($1.secondsFromStart - selectedSecond)
        }
    }

    var body: some View {
        // Compute the profile once per body pass (it sorts), then reuse it for
        // both the line and the scrub callout.
        let points = dive.depthProfile
        let selectedPoint = nearestPoint(in: points)
        return Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Elapsed", point.secondsFromStart),
                    y: .value("Depth", point.depthMeters)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.teal)
            }

            ForEach(placedMarkers) { marker in
                PointMark(
                    x: .value("Elapsed", marker.secondsFromStart),
                    y: .value("Depth", marker.depthMeters)
                )
                .symbolSize(0)
                .annotation(position: .overlay, spacing: 0) {
                    Text(marker.emoji)
                        .font(.caption)
                }
            }

            if let selectedPoint {
                RuleMark(x: .value("Elapsed", selectedPoint.secondsFromStart))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        callout(for: selectedPoint)
                    }
                PointMark(
                    x: .value("Elapsed", selectedPoint.secondsFromStart),
                    y: .value("Depth", selectedPoint.depthMeters)
                )
                .foregroundStyle(.teal)
            }
        }
        // Depth increases downward: reverse the Y domain and keep the surface (0) in view.
        .chartYScale(domain: .automatic(includesZero: true, reversed: true))
        .chartXAxisLabel("Elapsed (s)")
        .chartYAxisLabel("Depth (m)")
        .chartXSelection(value: $selectedSecond)
        .frame(height: 220)
    }

    private func callout(for point: DepthProfilePoint) -> some View {
        let clockTime = dive.startTime.addingTimeInterval(point.secondsFromStart)
        return VStack(alignment: .leading, spacing: 2) {
            Text(DepthFormat.string(point.depthMeters))
                .font(.caption).bold()
                .monospacedDigit()
            Text(clockTime, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A simple time-series line chart for a session metric (heart rate, water
/// temperature) — used for the whole session or a single segment's window.
struct MetricChartView: View {
    struct Point: Identifiable { let id: Int; let date: Date; let value: Double }
    let title: String
    let unit: String
    let tint: Color
    let points: [Point]

    var isEmpty: Bool { points.isEmpty }

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value(title, point.value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tint)
        }
        .chartYAxisLabel(unit)
        .frame(height: 160)
    }
}

extension MetricChartView {
    /// Heart-rate chart (bpm), optionally limited to a time window.
    init(heartRate samples: [HeartRateSample], in range: ClosedRange<Date>? = nil) {
        self.init(
            title: "Heart rate", unit: "bpm", tint: .red,
            points: Self.points(samples.map { ($0.timestamp, $0.bpm) }, in: range)
        )
    }

    /// Water-temperature chart (°C), optionally limited to a time window.
    init(temperature samples: [TemperatureSample], in range: ClosedRange<Date>? = nil) {
        self.init(
            title: "Temperature", unit: "°C", tint: .green,
            points: Self.points(samples.map { ($0.timestamp, $0.celsius) }, in: range)
        )
    }

    private static func points(_ raw: [(Date, Double)], in range: ClosedRange<Date>?) -> [Point] {
        raw.filter { range?.contains($0.0) ?? true }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { Point(id: $0, date: $1.0, value: $1.1) }
    }
}

#Preview("Heart-rate chart") {
    MetricChartView(
        heartRate: (0...60).map {
            HeartRateSample(timestamp: Date(timeIntervalSinceNow: Double($0) * 10), bpm: 70 + 25 * sin(Double($0) / 6))
        }
    )
    .padding()
}
