import SwiftUI
import MapKit
import Domain

/// Full session map: the surface path, each dive's submersion → surfacing
/// segment (dashed, underwater), and event markers placed along the path or the
/// underwater segment. Nearby points collapse into a numbered cluster when the
/// map is zoomed out.
struct SessionTrackMapView: View {
    let session: DiveSession
    /// Pan/zoom enabled. Off for the inline preview (tap opens the full map).
    var interactive: Bool = true

    /// Current visible latitude span, driving how aggressively points cluster.
    @State private var latitudeSpan: Double = 0.02

    // Session-derived geometry, computed once (it doesn't depend on zoom) so the
    // continuous camera-change handler doesn't rebuild/re-sort it every frame.
    private let surfacePath: [CLLocationCoordinate2D]
    private let diveSegments: [DiveSegment]
    private let points: [Point]

    /// `range` limits the map to a single segment's time window (the surface
    /// path + markers within it); `nil` shows the whole session.
    init(session: DiveSession, interactive: Bool = true, range: ClosedRange<Date>? = nil) {
        self.session = session
        self.interactive = interactive
        func inRange(_ time: Date) -> Bool { range.map { $0.contains(time) } ?? true }

        self.surfacePath = session.effectiveTrack
            .filter { inRange($0.timestamp) }
            .map { $0.location.coordinate }

        // Dives belong to the full-session map only — a surface-leg map (range set)
        // shows just that leg's path + markers, not the bracketing dives whose
        // boundary times coincide with the leg's range endpoints.
        let orderedDives = range == nil ? session.dives.sorted { $0.startTime < $1.startTime } : []
        self.diveSegments = orderedDives.enumerated().compactMap { index, dive in
            guard let s = session.surfaceLocation(at: dive.startTime),
                  let e = session.surfaceLocation(at: dive.endTime) else { return nil }
            return DiveSegment(id: index, submersion: s.coordinate, surfacing: e.coordinate)
        }

        var points: [Point] = []
        for (index, dive) in orderedDives.enumerated() {
            let number = index + 1
            if let s = session.surfaceLocation(at: dive.startTime) {
                points.append(Point(id: "down-\(dive.id)", geo: s, glyph: .submersion(number)))
            }
            if let e = session.surfaceLocation(at: dive.endTime) {
                points.append(Point(id: "up-\(dive.id)", geo: e, glyph: .surfacing(number)))
            }
        }
        for marker in session.markers where inRange(marker.timestamp) {
            if let geo = session.markerLocation(marker) {
                points.append(Point(id: "marker-\(marker.id)", geo: geo, glyph: .marker(marker.kind.emoji)))
            }
        }
        self.points = points
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            // Surface path.
            if surfacePath.count >= 2 {
                MapPolyline(coordinates: surfacePath)
                    .stroke(.teal, lineWidth: 3)
            }

            // Underwater segments: submersion → surfacing, dashed.
            ForEach(diveSegments) { segment in
                MapPolyline(coordinates: [segment.submersion, segment.surfacing])
                    .stroke(.teal.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
            }

            // Points, clustered by current zoom.
            ForEach(clusters) { cluster in
                Annotation(cluster.title, coordinate: cluster.coordinate) {
                    clusterView(cluster)
                }
                .annotationTitles(.hidden)
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            latitudeSpan = context.region.span.latitudeDelta
        }
    }

    // MARK: - Geometry types

    private struct DiveSegment: Identifiable {
        let id: Int
        let submersion: CLLocationCoordinate2D
        let surfacing: CLLocationCoordinate2D
    }

    /// A single placeable point before clustering.
    private struct Point: Identifiable {
        enum Glyph {
            case submersion(Int)
            case surfacing(Int)
            case marker(String)
        }
        let id: String
        let geo: GeoPoint
        let glyph: Glyph
    }

    // MARK: - Clustering

    private struct Cluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let members: [Point]
        var count: Int { members.count }
        var title: String { members.count == 1 ? members[0].id : "\(members.count) points" }
    }

    private var clusters: [Cluster] {
        let all = points
        // Cluster within ~5% of the visible latitude span.
        let groups = GeoClustering.cluster(all.map(\.geo), thresholdDegrees: latitudeSpan * 0.05)
        return groups.map { indices in
            let members = indices.map { all[$0] }
            let lat = members.map(\.geo.latitude).reduce(0, +) / Double(members.count)
            let lon = members.map(\.geo.longitude).reduce(0, +) / Double(members.count)
            return Cluster(
                id: members.map(\.id).joined(separator: "+"),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                members: members
            )
        }
    }

    // MARK: - Annotation views

    @ViewBuilder
    private func clusterView(_ cluster: Cluster) -> some View {
        if cluster.count > 1 {
            ZStack {
                Circle().fill(.teal)
                Text("\(cluster.count)")
                    .font(.caption2).bold()
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(radius: 1)
        } else {
            pointView(cluster.members[0])
        }
    }

    @ViewBuilder
    private func pointView(_ point: Point) -> some View {
        switch point.glyph {
        case .submersion(let n):
            badge(systemImage: "arrow.down", number: n, tint: .teal)
        case .surfacing(let n):
            badge(systemImage: "arrow.up", number: n, tint: .blue)
        case .marker(let emoji):
            Text(emoji)
                .font(.body)
                .padding(4)
                .background(Circle().fill(.thinMaterial))
                .shadow(radius: 1)
        }
    }

    private func badge(systemImage: String, number: Int, tint: Color) -> some View {
        ZStack {
            Circle().fill(tint)
            HStack(spacing: 1) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                Text("\(number)").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        .shadow(radius: 1)
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
