import SwiftUI
import Domain
import Persistence

/// Reusable session summary: headline stats, a map with the surface path +
/// dive/marker points, and the marker breakdown. Shown right after a dive (with
/// the Done / Dive-again toolbar and a sync badge, `showSync: true`) and when a
/// past session is tapped in the list (pushed with a back button).
struct WatchSessionSummaryView: View {
    let session: DiveSession
    /// Show the watch→iPhone sync badge — only meaningful for the session that
    /// just finished, not historical ones browsed from the list.
    var showSync = false

    @Environment(SessionCoordinator.self) private var coordinator

    private var hasGeo: Bool { !session.track.isEmpty || session.location != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                stats

                segmentsSection

                markerSummary

                if showSync { syncStatus }

                // Full session map at the bottom.
                if hasGeo { mapSection }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
    }

    private var stats: some View {
        VStack(spacing: 4) {
            summaryRow("Date", session.startTime.formatted(date: .abbreviated, time: .shortened))
            summaryRow("Total", Duration.seconds(session.totalDuration).formatted(.time(pattern: .hourMinuteSecond)))
            summaryRow("Dives", "\(session.diveCount)")
            summaryRow("Max depth", DepthFormat.string(session.maxDepthMeters))
            summaryRow("Bottom time", Duration.seconds(totalDiveTime).formatted(.time(pattern: .minuteSecond)))
            if let longest = longestDive {
                summaryRow("Longest dive", Duration.seconds(longest).formatted(.time(pattern: .minuteSecond)))
            }
            if let average = session.averageSurfaceInterval {
                summaryRow("Avg surface", Duration.seconds(average).formatted(.time(pattern: .minuteSecond)))
            }
            summaryRow("Distance", distanceText(session.surfaceDistanceMeters))
            summaryRow("Location", locationText)
        }
    }

    /// Total time spent below the surface (sum of dive durations).
    private var totalDiveTime: TimeInterval { session.dives.map(\.duration).reduce(0, +) }
    private var longestDive: TimeInterval? { session.dives.map(\.duration).max() }

    private var locationText: String {
        guard let location = session.location else { return "No GPS fix" }
        return String(format: "%.4f, %.4f", location.latitude, location.longitude)
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
    }

    // MARK: - Segments

    /// The session timeline: each surface interval / dive with its start offset,
    /// duration, and (for dives) max depth. Dive rows push the depth profile.
    @ViewBuilder
    private var segmentsSection: some View {
        let segments = session.segments
        if !segments.isEmpty {
            VStack(spacing: 4) {
                sectionHeader("Segments")
                ForEach(segments) { segment in
                    if let dive = segment.dive {
                        // Dive → depth profile (with markers).
                        NavigationLink {
                            WatchDiveProfileView(dive: dive, markers: session.markers)
                        } label: {
                            segmentRow(segment)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Surface → that leg's path on the map (with markers).
                        NavigationLink {
                            WatchSessionMapView(
                                session: session,
                                interactive: true,
                                range: segment.startTime...segment.endTime
                            )
                            .ignoresSafeArea()
                            .navigationTitle("Surface")
                        } label: {
                            segmentRow(segment)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Uniform row for every segment: icon · +offset · metric · duration, where
    /// the metric is surface distance (surface) or max depth (dive).
    private func segmentRow(_ segment: SessionSegment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: segment.isDive ? "arrow.down" : "water.waves")
                .foregroundStyle(segment.isDive ? AnyShapeStyle(.teal) : AnyShapeStyle(.blue))
                .frame(width: 16)
            Text("+" + offset(segment.startTime))
                .foregroundStyle(.secondary)
            if segment.markerCount > 0 {
                Text("📍\(segment.markerCount)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(metricText(segment))
                .foregroundStyle(.teal)
                .frame(minWidth: 42, alignment: .trailing)
            Text(Duration.seconds(segment.duration).formatted(.time(pattern: .minuteSecond)))
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.vertical, 2)
    }

    /// The metric column: surface distance for surface intervals, max depth for dives.
    private func metricText(_ segment: SessionSegment) -> String {
        if let dive = segment.dive { return DepthFormat.string(dive.maxDepthMeters) }
        return distanceText(segment.distanceMeters)
    }

    /// Segment start expressed as an offset from the session start (mm:ss).
    private func offset(_ time: Date) -> String {
        Duration.seconds(time.timeIntervalSince(session.startTime)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: - Map

    /// Inline non-interactive map; tap to push the full interactive map.
    private var mapSection: some View {
        VStack(spacing: 4) {
            sectionHeader("Map")
            NavigationLink {
                WatchSessionMapView(session: session, interactive: true)
                    .ignoresSafeArea()
                    .navigationTitle("Map")
            } label: {
                WatchSessionMapView(session: session, interactive: false)
                    .frame(height: 120)
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
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Background-safe transfer status for the just-finished session: still in
    /// the WatchConnectivity queue, or confirmed delivered to the iPhone.
    private var syncStatus: some View {
        let pending = coordinator.pendingSyncCount > 0
        return Label(
            pending ? "Syncing to iPhone…" : "Synced to iPhone",
            systemImage: pending ? "arrow.triangle.2.circlepath" : "checkmark.icloud"
        )
        .font(.caption2)
        .foregroundStyle(pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.teal))
        .symbolVariant(pending ? .none : .fill)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
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

    @ViewBuilder
    private var markerSummary: some View {
        let counts = session.markerCountsByKind
        if counts.isEmpty {
            Text("No markers")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 2) {
                Text("\(session.markers.count) markers")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(
                    counts
                        .sorted { $0.key.id < $1.key.id }
                        .map { "\($0.key.emoji) \($0.value)" }
                        .joined(separator: "  ")
                )
                .font(.caption2)
                .multilineTextAlignment(.center)
            }
        }
    }
}
