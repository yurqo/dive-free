import SwiftUI
import Charts
import Domain

/// Depth-over-time profile for a single dive on the watch — a compact line chart
/// (Y inverted so depth increases downward) with any markers placed at the depth
/// they landed, plus max depth and duration. Pushed from a dive row in the
/// session summary's segment list.
struct WatchDiveProfileView: View {
    let dive: Dive
    var markers: [EventMarker] = []

    private struct Placed: Identifiable {
        let id: UUID
        let emoji: String
        let secondsFromStart: TimeInterval
        let depthMeters: Double
    }

    private var placed: [Placed] {
        markers.compactMap { marker in
            guard marker.timestamp >= dive.startTime, marker.timestamp <= dive.endTime,
                  let depth = dive.interpolatedDepth(at: marker.timestamp) else { return nil }
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
                    metric("Max", DepthFormat.string(dive.maxDepthMeters))
                    metric("Time", Duration.seconds(dive.duration).formatted(.time(pattern: .minuteSecond)))
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Dive")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
