import SwiftUI
import MapKit
import Domain

/// Surface track and estimated dive boundaries. Clusters use screen proximity;
/// tapping reveals individual points without moving their geographic anchors.
struct SessionTrackMapView: View {
    let session: DiveSession
    var interactive: Bool = true

    @Namespace private var mapSpace
    @State private var latitudeSpan: Double = 0.02
    @State private var projected: [String: CGPoint] = [:]
    @State private var lastCameraRect: MKMapRect?
    @State private var expandedCluster: SessionMapCluster?
    @State private var selectedPointID: String?

    private let surfacePath: [CLLocationCoordinate2D]
    private let diveSegments: [DiveSegment]
    private let points: [SessionMapPoint]

    /// A range shows just one surface leg, without the bracketing dive pins.
    init(session: DiveSession, interactive: Bool = true, range: ClosedRange<Date>? = nil) {
        self.session = session
        self.interactive = interactive
        func inRange(_ time: Date) -> Bool { range.map { $0.contains(time) } ?? true }
        let track = session.effectiveTrack
        surfacePath = TrackCleaner.simplify(track.filter { inRange($0.timestamp) }, toleranceMeters: 3)
            .map { $0.location.coordinate }

        let dives = range == nil ? session.dives.sorted { $0.startTime < $1.startTime } : []
        diveSegments = dives.enumerated().compactMap { index, dive in
            guard let start = DiveSession.surfacePosition(in: track, at: dive.startTime),
                  let end = DiveSession.surfacePosition(in: track, at: dive.endTime) else { return nil }
            return DiveSegment(id: index, submersion: start.coordinate, surfacing: end.coordinate)
        }
        var points: [SessionMapPoint] = []
        for (index, dive) in dives.enumerated() {
            if let geo = DiveSession.surfacePosition(in: track, at: dive.startTime) {
                points.append(SessionMapPoint(id: "down-\(dive.id)", geo: geo, timestamp: dive.startTime,
                    kind: .submersion(diveID: dive.id, number: index + 1)))
            }
            if let geo = DiveSession.surfacePosition(in: track, at: dive.endTime) {
                points.append(SessionMapPoint(id: "up-\(dive.id)", geo: geo, timestamp: dive.endTime,
                    kind: .surfacing(diveID: dive.id, number: index + 1)))
            }
        }
        for marker in session.markers where inRange(marker.timestamp) {
            if let geo = session.markerLocation(marker) {
                points.append(SessionMapPoint(id: "marker-\(marker.id)", geo: geo, timestamp: marker.timestamp,
                    kind: .marker(emoji: marker.kind.emoji, label: marker.displayTitle)))
            }
        }
        self.points = points
    }

    var body: some View {
        MapReader { proxy in
            // MapKit reuses annotation hosts. Capture these values here so
            // expansion and list selection invalidate their rendered content.
            let expandedID = expandedCluster?.id
            let selectedID = selectedPointID
            Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
                if surfacePath.count >= 2 {
                    MapPolyline(coordinates: surfacePath).stroke(.teal, lineWidth: 3)
                }
                ForEach(diveSegments) { segment in
                    MapPolyline(coordinates: [segment.submersion, segment.surfacing])
                        .stroke(.teal.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                }
                ForEach(clusters) { cluster in
                    Annotation(clusterTitle(cluster), coordinate: cluster.geo.coordinate) {
                        Button { expand(cluster) } label: { clusterBadge(cluster) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .disabled(!interactive)
                            .opacity(expandedID == cluster.id ? 0 : 1)
                            .allowsHitTesting(expandedID != cluster.id)
                            .accessibilityHidden(expandedID == cluster.id)
                            .accessibilityLabel(clusterTitle(cluster))
                            .accessibilityHint("Show all points")
                            .accessibilityIdentifier(clusterIdentifier(cluster))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                if let previous = lastCameraRect, !MKMapRectEqualToRect(previous, context.rect) { collapse() }
                lastCameraRect = context.rect
                latitudeSpan = context.region.span.latitudeDelta
                updateProjection(proxy)
            }
            .overlay {
                GeometryReader { geometry in
                    Group {
                        if interactive, let cluster = expandedCluster {
                            expandedPoints(cluster, proxy: proxy, geometry: geometry, selectedID: selectedID)
                        }
                    }
                    .onChange(of: geometry.size) { _, _ in
                        collapse()
                        updateProjection(proxy)
                    }
                }
                .coordinateSpace(name: mapSpace)
            }
        }
    }

    private struct DiveSegment: Identifiable {
        let id: Int
        let submersion: CLLocationCoordinate2D
        let surfacing: CLLocationCoordinate2D
    }

    private var clusters: [SessionMapCluster] {
        SessionMapLayout.clusters(points: points, projected: projected, fallbackLatitudeSpan: latitudeSpan)
    }

    private func updateProjection(_ proxy: MapProxy) {
        projected = Dictionary(uniqueKeysWithValues: points.compactMap { point in
            guard let position = proxy.convert(point.geo.coordinate, to: .named(mapSpace)),
                  position.x.isFinite, position.y.isFinite else { return nil }
            return (point.id, position)
        })
    }

    private func expand(_ cluster: SessionMapCluster) {
        expandedCluster = cluster
        selectedPointID = nil
    }

    private func collapse() {
        expandedCluster = nil
        selectedPointID = nil
    }

    // MARK: Expanded labels and complete point list

    private func expandedPoints(_ cluster: SessionMapCluster, proxy: MapProxy, geometry: GeometryProxy,
                                selectedID: String?) -> some View {
        let panelHeight = min(230.0, 64 + Double(cluster.members.count) * 48)
        // Keep MapKit's attribution and the home indicator unobscured.
        let bottomInset = max(geometry.safeAreaInsets.bottom, 32)
        let topInset = max(geometry.safeAreaInsets.top + 12, 80)
        let bounds = CGRect(x: 16, y: topInset, width: geometry.size.width - 32,
                            height: max(0, geometry.size.height - topInset - panelHeight - bottomInset - 28))
        let centre = proxy.convert(cluster.geo.coordinate, to: .named(mapSpace))
            ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
        let positions = SessionMapLayout.expandedPositions(ids: cluster.members.map(\.id), centre: centre,
                                                          bounds: bounds, selectedID: selectedID)
        return ZStack(alignment: .bottom) {
            Canvas { context, _ in
                for point in cluster.members {
                    guard let label = positions[point.id], let anchor = projected[point.id] else { continue }
                    var line = Path()
                    line.move(to: anchor)
                    line.addLine(to: label)
                    context.stroke(line, with: .color(.secondary), lineWidth: 1)
                    let dot = CGRect(x: anchor.x - 3, y: anchor.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(pointTint(point)))
                }
            }
            .allowsHitTesting(false)

            ForEach(cluster.members.filter { positions[$0.id] != nil }) { point in
                Button { selectedPointID = point.id } label: { pointBadge(point) }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .background {
                        if selectedID == point.id {
                            Circle().stroke(.primary, lineWidth: 2).padding(3)
                        }
                    }
                    .position(positions[point.id]!)
                    .accessibilityLabel(pointTitle(point))
                    .accessibilityValue(point.timestamp.formatted(date: .omitted, time: .standard))
                    .accessibilityIdentifier("session.map.expanded.point.\(point.id)")
            }

            pointList(cluster, displayedCount: positions.count, selectedID: selectedID)
                .frame(maxWidth: 380)
                .frame(height: panelHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 12)
                .padding(.bottom, bottomInset)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private func pointList(_ cluster: SessionMapCluster, displayedCount: Int, selectedID: String?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(clusterTitle(cluster)).font(.headline)
                Spacer()
                Button(action: collapse) {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide points")
                    .accessibilityIdentifier("session.map.collapse")
            }
            .padding(.leading, 16)
            if displayedCount < cluster.members.count {
                Text("Showing \(displayedCount) of \(cluster.members.count) points")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(cluster.members) { point in
                        Button { selectedPointID = point.id } label: {
                            HStack(spacing: 10) {
                                pointBadge(point)
                                Text(pointTitle(point)).font(.subheadline)
                                Spacer(minLength: 4)
                                Text(point.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .padding(.horizontal, 12)
                            .background(selectedID == point.id ? Color.teal.opacity(0.12) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session.map.point-row.\(point.id)")
                    }
                }
            }
            .accessibilityIdentifier("session.map.point-list")
        }
        .padding(.bottom, 8)
    }

    // MARK: Distinct dive and aggregate badges

    @ViewBuilder private func clusterBadge(_ cluster: SessionMapCluster) -> some View {
        switch cluster.presentation {
        case .point: pointBadge(cluster.members[0])
        case .divePair(let number):
            badge(systemImage: "arrow.up.arrow.down", number: number,
                  fill: LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
        case .count(let count):
            HStack(spacing: 4) {
                Image(systemName: "square.stack.fill").font(.system(size: 10, weight: .semibold))
                Text(count, format: .number).font(.caption).bold().monospacedDigit()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.4), lineWidth: 1))
            .shadow(radius: 1)
        }
    }

    @ViewBuilder private func pointBadge(_ point: SessionMapPoint) -> some View {
        switch point.kind {
        case .submersion(_, let number): badge(systemImage: "arrow.down", number: number, fill: Color.teal)
        case .surfacing(_, let number): badge(systemImage: "arrow.up", number: number, fill: Color.blue)
        case .marker(let emoji, _):
            Text(emoji).font(.body).padding(4)
                .background(.thinMaterial, in: Circle()).shadow(radius: 1)
        }
    }

    private func badge(systemImage: String, number: Int, fill: some ShapeStyle) -> some View {
        HStack(spacing: 1) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            Text(number, format: .number).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(minWidth: 28, minHeight: 28)
        .background(fill, in: Circle())
        .shadow(radius: 1)
    }

    private func clusterTitle(_ cluster: SessionMapCluster) -> String {
        switch cluster.presentation {
        case .point: pointTitle(cluster.members[0])
        case .divePair(let number): String(localized: "Dive \(number)") + " · " + String(localized: "Start and end")
        case .count(let count): String(localized: "Points: \(count)")
        }
    }

    private func pointTitle(_ point: SessionMapPoint) -> String {
        switch point.kind {
        case .submersion(_, let number): String(localized: "Dive \(number)") + " · " + String(localized: "Submersion")
        case .surfacing(_, let number): String(localized: "Dive \(number)") + " · " + String(localized: "Surfacing")
        case .marker(_, let label): label
        }
    }

    private func pointTint(_ point: SessionMapPoint) -> Color {
        if case .surfacing = point.kind { .blue } else { .teal }
    }

    private func clusterIdentifier(_ cluster: SessionMapCluster) -> String {
        switch cluster.presentation {
        case .point: "session.map.point.\(cluster.members[0].id)"
        case .divePair(let number): "session.map.dive-pair.\(number)"
        case .count: "session.map.aggregate.\(cluster.id)"
        }
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
