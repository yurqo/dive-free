import Foundation

/// Pure, deterministic GPX 1.1 serializer for a `DiveSession`.
///
/// Produces a `<gpx version="1.1">` document containing:
/// - one `<trk>` with a single `<trkseg>` of the session's surface `track`, as
///   `<trkpt lat lon><time/><ele>0</ele></trkpt>` (surface elevation is 0); and
/// - one `<wpt>` per `EventMarker`, placed at the marker's derived surface/dive
///   position (`DiveSession.markerLocation`, falling back to `session.location`),
///   with the marker's emoji+label (or its text) as the `<name>`.
///
/// GPX carries the track + waypoints only. Heart-rate and water-temperature are
/// deliberately **not** folded into the track: on a sparse surface track the
/// nearest-point folding attached dive-time readings to far-away surface fixes,
/// which is misleading. Those series ride in the FIT/TCX exports instead.
///
/// Markers with no derivable location are skipped (GPX waypoints require coords).
/// All output is UTC ISO-8601 and C-locale numeric, so it is byte-stable.
public enum GPXExport {
    public static func export(_ session: DiveSession) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append(
            "<gpx version=\"1.1\" creator=\"DiveFree\" "
            + "xmlns=\"http://www.topografix.com/GPX/1/1\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
            + "xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 "
            + "http://www.topografix.com/GPX/1/1/gpx.xsd\">"
        )

        // Metadata: session time + optional name.
        lines.append("  <metadata>")
        lines.append("    <time>\(ExportFormatting.isoString(session.startTime))</time>")
        if let name = trackName(session) {
            lines.append("    <name>\(ExportFormatting.xmlEscaped(name))</name>")
        }
        lines.append("  </metadata>")

        // Waypoints for markers with a derivable location.
        for marker in session.markers.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let point = session.markerLocation(marker) ?? session.location else { continue }
            lines.append(
                "  <wpt lat=\"\(ExportFormatting.coordinate(point.latitude))\" "
                + "lon=\"\(ExportFormatting.coordinate(point.longitude))\">"
            )
            lines.append("    <time>\(ExportFormatting.isoString(marker.timestamp))</time>")
            lines.append("    <name>\(ExportFormatting.xmlEscaped(markerName(marker)))</name>")
            lines.append("  </wpt>")
        }

        // The surface track: raw track points with a zero surface elevation.
        let track = session.track.sorted { $0.timestamp < $1.timestamp }
        if !track.isEmpty {
            lines.append("  <trk>")
            if let name = trackName(session) {
                lines.append("    <name>\(ExportFormatting.xmlEscaped(name))</name>")
            }
            lines.append("    <trkseg>")
            for pt in track {
                lines.append(
                    "      <trkpt lat=\"\(ExportFormatting.coordinate(pt.location.latitude))\" "
                    + "lon=\"\(ExportFormatting.coordinate(pt.location.longitude))\">"
                )
                lines.append("        <ele>0</ele>")
                lines.append("        <time>\(ExportFormatting.isoString(pt.timestamp))</time>")
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `<name>` for a marker: emoji + label, appended with its text when set.
    private static func markerName(_ marker: EventMarker) -> String {
        let head = "\(marker.kind.emoji) \(marker.kind.label)"
        if let text = marker.text, !text.isEmpty { return "\(head): \(text)" }
        return head
    }

    /// A stable, human-friendly name for the track/metadata: the session title,
    /// else the location name, else `nil`.
    private static func trackName(_ session: DiveSession) -> String? {
        if let title = session.title, !title.isEmpty { return title }
        if let name = session.locationName, !name.isEmpty { return name }
        return nil
    }
}
