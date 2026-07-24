import Foundation
import Testing
@testable import Domain

/// Tests for the pure Domain export serializers (GPX, CSV, UDDF, TCX). All build
/// on one deterministic fixture so output is byte-stable and golden-comparable.
@Suite("Export")
struct ExportTests {
    // MARK: - Fixtures

    /// A `Date` `t` seconds past the epoch.
    private func d(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

    /// Session start at epoch, two dives with depth samples, a short surface
    /// track, two markers (one carrying a comma+quote+`<`+`&` note), and one HR +
    /// one temperature sample coincident with dive samples.
    private func fixture() -> DiveSession {
        let dive1 = Dive(
            startTime: d(60),
            endTime: d(90),
            maxDepthMeters: 12,
            samples: [
                DepthSample(timestamp: d(60), depthMeters: 0),
                DepthSample(timestamp: d(75), depthMeters: 12),
                DepthSample(timestamp: d(90), depthMeters: 0),
            ]
        )
        let dive2 = Dive(
            startTime: d(150),
            endTime: d(180),
            maxDepthMeters: 18,
            samples: [
                DepthSample(timestamp: d(150), depthMeters: 0),
                DepthSample(timestamp: d(165), depthMeters: 18),
                DepthSample(timestamp: d(180), depthMeters: 0),
            ]
        )
        let track = [
            TrackPoint(timestamp: d(0), location: GeoPoint(latitude: 10.0, longitude: 20.0)),
            TrackPoint(timestamp: d(120), location: GeoPoint(latitude: 10.001, longitude: 20.001)),
            TrackPoint(timestamp: d(200), location: GeoPoint(latitude: 10.002, longitude: 20.002)),
        ]
        let markers = [
            EventMarker(timestamp: d(75), kind: .wildlife, text: "Turtle, big, said \"wow\" & <cool>"),
            EventMarker(timestamp: d(165), kind: .note, text: "deep"),
        ]
        return DiveSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            startTime: d(0),
            endTime: d(210),
            dives: [dive1, dive2],
            markers: markers,
            location: GeoPoint(latitude: 10.0, longitude: 20.0),
            track: track,
            heartRateSamples: [HeartRateSample(timestamp: d(75), bpm: 82)],
            temperatureSamples: [TemperatureSample(timestamp: d(165), celsius: 21)],
            locationName: "Blue Hole",
            title: "Morning session",
            notes: "Great, viz 30m",
            rating: 4,
            smoothTrack: false // exact track, no cleaning, for deterministic coords
        )
    }

    private func emptySession() -> DiveSession {
        DiveSession(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, startTime: d(0), endTime: d(10))
    }

    /// Counts non-overlapping occurrences of `needle` in `haystack`.
    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - XML escaping helper

    @Test("xmlEscaped escapes the five predefined entities")
    func xmlEscaping() {
        #expect(ExportFormatting.xmlEscaped("a & b < c > d \" e ' f")
            == "a &amp; b &lt; c &gt; d &quot; e &apos; f")
    }

    // MARK: - GPX

    @Test("GPX is well-formed with track + waypoints and escaped names")
    func gpxWellFormed() {
        let gpx = GPXExport.export(fixture())
        #expect(gpx.hasPrefix("<?xml"))
        #expect(gpx.contains("<gpx version=\"1.1\" creator=\"DiveFree\""))
        #expect(gpx.hasSuffix("</gpx>\n"))
        // One trkpt per track point.
        #expect(count("<trkpt", in: gpx) == 3)
        // One wpt per marker (both have derivable locations).
        #expect(count("<wpt", in: gpx) == 2)
        // Surface elevation is zero.
        #expect(gpx.contains("<ele>0</ele>"))
        // GPX carries the track + waypoints only; HR/temp are not folded in.
        #expect(!gpx.contains("gpxtpx"))
        #expect(!gpx.contains("<extensions>"))
    }

    @Test("GPX escapes special characters in marker names")
    func gpxEscaping() {
        let gpx = GPXExport.export(fixture())
        #expect(gpx.contains("&quot;wow&quot;"))
        #expect(gpx.contains("&amp;"))
        #expect(gpx.contains("&lt;cool&gt;"))
        // Raw unescaped angle brackets must not leak from the note.
        #expect(!gpx.contains("<cool>"))
    }

    @Test("GPX of an empty session is a well-formed minimal document")
    func gpxEmpty() {
        let gpx = GPXExport.export(emptySession())
        #expect(gpx.hasPrefix("<?xml"))
        #expect(gpx.contains("<gpx version=\"1.1\""))
        #expect(gpx.hasSuffix("</gpx>\n"))
        #expect(count("<trkpt", in: gpx) == 0)
        #expect(count("<wpt", in: gpx) == 0)
    }

    // MARK: - CSV

    @Test("CSV has a header plus one row per dive")
    func csvRows() {
        let csv = CSVExport.export(fixture())
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        // header + 2 dives.
        #expect(rows.count == 3)
        #expect(rows[0].hasPrefix("session_id,session_start,session_end,dive_number"))
        // First dive: number 1, offset 60s, duration 30s, depth 12.00.
        #expect(rows[1].contains(",1,60,30,12.00,"))
        // Second dive: number 2, offset 150s, duration 30s, depth 18.00.
        #expect(rows[2].contains(",2,150,30,18.00,"))
    }

    @Test("CSV RFC-4180 quotes fields with comma/quote and doubles quotes")
    func csvEscaping() {
        var session = fixture()
        session.notes = "hazard, said \"stop\""
        let csv = CSVExport.export(session)
        // Comma + doubled quotes → whole field wrapped in quotes.
        #expect(csv.contains("\"hazard, said \"\"stop\"\"\""))
    }

    @Test("CSV defuses spreadsheet formula injection in free-text fields")
    func csvFormulaInjection() {
        var session = fixture()
        session.notes = "=HYPERLINK(\"http://evil\",\"x\")"
        let csv = CSVExport.export(session)
        // The note is neutralized with a leading apostrophe and still correctly
        // RFC-4180 quoted (it contains commas and quotes). The apostrophe sits
        // inside the opening quote so the formula never leads the cell.
        #expect(csv.contains("\"'=HYPERLINK("))
        // The raw, un-defused formula must not appear as a field start.
        #expect(!csv.contains(",=HYPERLINK"))
        #expect(!csv.contains("\"=HYPERLINK"))
    }

    @Test("CSV of an empty session is header-only")
    func csvEmpty() {
        let csv = CSVExport.export(emptySession())
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.count == 1)
        #expect(rows[0].hasPrefix("session_id,"))
    }

    // MARK: - UDDF

    @Test("UDDF is well-formed with a dive per Dive and converted temperature")
    func uddfWellFormed() {
        let uddf = UDDFExport.export(fixture())
        #expect(uddf.hasPrefix("<?xml"))
        #expect(uddf.contains("<uddf version=\"3.2.0\">"))
        #expect(uddf.hasSuffix("</uddf>\n"))
        #expect(uddf.contains("<name>DiveFree</name>"))
        #expect(uddf.contains("<type>logbook</type>"))
        // Two dives.
        #expect(count("<dive id=", in: uddf) == 2)
        // Six waypoints total (3 per dive).
        #expect(count("<waypoint>", in: uddf) == 6)
        // Divetime seconds-from-dive-start present (dive1 mid-sample at 15s).
        #expect(uddf.contains("<divetime>15</divetime>"))
        // Depth in meters.
        #expect(uddf.contains("<depth>12.00</depth>"))
        #expect(uddf.contains("<greatestdepth>18.00</greatestdepth>"))
        // Temperature 21°C → 294.15 K on the coincident waypoint (dive2 @165s).
        #expect(uddf.contains("<temperature>294.15</temperature>"))
        // Dive site from location.
        #expect(uddf.contains("<latitude>10.0000000</latitude>"))
        // Freedive marker.
        #expect(uddf.contains("<apnoe>1</apnoe>"))
    }

    @Test("UDDF escapes special characters in the site name")
    func uddfEscaping() {
        var session = fixture()
        session.locationName = "Reef <A> & \"B\""
        let uddf = UDDFExport.export(session)
        #expect(uddf.contains("&lt;A&gt; &amp; &quot;B&quot;"))
        #expect(!uddf.contains("<A>"))
    }

    @Test("UDDF of an empty session is a well-formed minimal document")
    func uddfEmpty() {
        let uddf = UDDFExport.export(emptySession())
        #expect(uddf.hasPrefix("<?xml"))
        #expect(uddf.contains("<uddf version=\"3.2.0\">"))
        #expect(uddf.hasSuffix("</uddf>\n"))
        #expect(count("<dive id=", in: uddf) == 0)
        // No location → no divesite.
        #expect(!uddf.contains("<divesite>"))
    }

    // MARK: - TCX

    @Test("TCX is well-formed with a Lap per dive and coincident HR")
    func tcxWellFormed() {
        let tcx = TCXExport.export(fixture())
        #expect(tcx.hasPrefix("<?xml"))
        #expect(tcx.contains("<TrainingCenterDatabase"))
        #expect(tcx.contains("<Activity Sport=\"Other\">"))
        #expect(tcx.hasSuffix("</TrainingCenterDatabase>\n"))
        // Two laps.
        #expect(count("<Lap StartTime=", in: tcx) == 2)
        // Six trackpoints (3 depth samples per dive).
        #expect(count("<Trackpoint>", in: tcx) == 6)
        // Depth 12 → altitude -12.00.
        #expect(tcx.contains("<AltitudeMeters>-12.00</AltitudeMeters>"))
        // HR sample near dive1 mid-point.
        #expect(tcx.contains("<Value>82</Value>"))
        // Position derived from the surface track.
        #expect(tcx.contains("<LatitudeDegrees>"))
    }

    @Test("TCX with active energy writes Calories on the first lap only")
    func tcxCalories() {
        var session = fixture()
        session.activeEnergyKilocalories = 137.6
        let tcx = TCXExport.export(session)
        #expect(count("<Calories>", in: tcx) == 1)
        #expect(tcx.contains("<Calories>138</Calories>"))
    }

    @Test("TCX of an empty session is a well-formed minimal document")
    func tcxEmpty() {
        let tcx = TCXExport.export(emptySession())
        #expect(tcx.hasPrefix("<?xml"))
        #expect(tcx.contains("<TrainingCenterDatabase"))
        #expect(tcx.hasSuffix("</TrainingCenterDatabase>\n"))
        #expect(count("<Lap StartTime=", in: tcx) == 0)
        #expect(count("<Trackpoint>", in: tcx) == 0)
    }

    // MARK: - Determinism

    @Test("all exporters are deterministic across two runs")
    func determinism() {
        let session = fixture()
        #expect(GPXExport.export(session) == GPXExport.export(session))
        #expect(CSVExport.export(session) == CSVExport.export(session))
        #expect(UDDFExport.export(session) == UDDFExport.export(session))
        #expect(TCXExport.export(session) == TCXExport.export(session))
    }
}
