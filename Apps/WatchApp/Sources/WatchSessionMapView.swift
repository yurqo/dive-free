import SwiftUI
import MapKit
import Domain

/// Compact watch map: the surface path, each dive's submersion → surfacing dash,
/// and numbered dive points + event markers. No clustering — the watch screen is
/// small and these are quick-glance maps. Falls back to a single dive-site pin
/// when only a one-shot location was captured.
struct WatchSessionMapView: View {
    private let surfacePath: [CLLocationCoordinate2D]
    private let diveSegments: [Segment]
    private let points: [Point]
    private let fallbackPin: CLLocationCoordinate2D?
    /// Pan/zoom enabled. Off for the inline thumbnail (tap opens the full map).
    private let interactive: Bool

    /// `range` limits the map to a single segment's time window (the surface
    /// path + markers within it); `nil` shows the whole session.
    init(session: DiveSession, interactive: Bool = true, range: ClosedRange<Date>? = nil) {
        self.interactive = interactive
        func inRange(_ time: Date) -> Bool { range.map { $0.contains(time) } ?? true }

        let path = session.track
            .sorted { $0.timestamp < $1.timestamp }
            .filter { inRange($0.timestamp) }
            .map { $0.location.coordinate }
        self.surfacePath = path

        let dives = session.dives.sorted { $0.startTime < $1.startTime }
        self.diveSegments = dives.enumerated().compactMap { index, dive in
            guard inRange(dive.startTime) || inRange(dive.endTime),
                  let s = session.surfaceLocation(at: dive.startTime),
                  let e = session.surfaceLocation(at: dive.endTime) else { return nil }
            return Segment(id: index, start: s.coordinate, end: e.coordinate)
        }

        var pts: [Point] = []
        for (index, dive) in dives.enumerated() where inRange(dive.startTime) || inRange(dive.endTime) {
            let number = index + 1
            if let s = session.surfaceLocation(at: dive.startTime) {
                pts.append(Point(id: "down-\(dive.id)", coordinate: s.coordinate, glyph: .submersion(number)))
            }
            if let e = session.surfaceLocation(at: dive.endTime) {
                pts.append(Point(id: "up-\(dive.id)", coordinate: e.coordinate, glyph: .surfacing(number)))
            }
        }
        for marker in session.markers where inRange(marker.timestamp) {
            if let geo = session.markerLocation(marker) {
                pts.append(Point(id: "marker-\(marker.id)", coordinate: geo.coordinate, glyph: .marker(marker.kind.emoji)))
            }
        }
        self.points = pts
        self.fallbackPin = (path.isEmpty && pts.isEmpty) ? session.location?.coordinate : nil
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            if surfacePath.count >= 2 {
                MapPolyline(coordinates: surfacePath)
                    .stroke(.teal, lineWidth: 2)
            }
            ForEach(diveSegments) { segment in
                MapPolyline(coordinates: [segment.start, segment.end])
                    .stroke(.teal.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
            ForEach(points) { point in
                Annotation(point.id, coordinate: point.coordinate) { glyphView(point.glyph) }
                    .annotationTitles(.hidden)
            }
            if let fallbackPin {
                Annotation("Dive site", coordinate: fallbackPin) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    // MARK: - Geometry

    private struct Segment: Identifiable {
        let id: Int
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    private struct Point: Identifiable {
        enum Glyph {
            case submersion(Int)
            case surfacing(Int)
            case marker(String)
        }
        let id: String
        let coordinate: CLLocationCoordinate2D
        let glyph: Glyph
    }

    @ViewBuilder
    private func glyphView(_ glyph: Point.Glyph) -> some View {
        switch glyph {
        case .submersion(let number): badge("arrow.down", number, .teal)
        case .surfacing(let number): badge("arrow.up", number, .blue)
        case .marker(let emoji): Text(emoji).font(.caption)
        }
    }

    private func badge(_ symbol: String, _ number: Int, _ tint: Color) -> some View {
        ZStack {
            Circle().fill(tint)
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                Text("\(number)").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
