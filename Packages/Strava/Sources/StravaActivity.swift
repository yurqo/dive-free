import Foundation
import Domain

/// Minimal Strava "activity" payload mapped from a dive session. Strava has no
/// freediving type, so sessions are exported as a `Swim`.
public struct StravaActivity: Sendable, Equatable, Codable {
    public var name: String
    /// Strava `sport_type` (e.g. "Swim").
    public var type: String
    public var startDate: Date
    public var elapsedSeconds: Int
    public var description: String?

    public init(name: String, type: String = "Swim", startDate: Date, elapsedSeconds: Int, description: String? = nil) {
        self.name = name
        self.type = type
        self.startDate = startDate
        self.elapsedSeconds = elapsedSeconds
        self.description = description
    }

    /// Builds an activity from a completed session. The dive-spot coordinate is
    /// folded into the description — Strava's manual activity-create endpoint
    /// carries no GPS track, so there's nowhere else to put it.
    public init(session: DiveSession) {
        let end = session.endTime ?? session.startTime
        var summary = "\(session.diveCount) dives, max depth \(String(format: "%.1f", session.maxDepthMeters)) m"
        if let location = session.location {
            summary += String(format: " · 📍 %.5f, %.5f", location.latitude, location.longitude)
        }
        self.init(
            name: "Freedive Session",
            type: "Swim",
            startDate: session.startTime,
            elapsedSeconds: Int(end.timeIntervalSince(session.startTime)),
            description: summary
        )
    }

    /// POST body fields for `/v3/activities`.
    public var formFields: [String: String] {
        var fields = [
            "name": name,
            "sport_type": type,
            "start_date_local": ISO8601DateFormatter().string(from: startDate),
            "elapsed_time": String(elapsedSeconds),
        ]
        if let description { fields["description"] = description }
        return fields
    }
}

/// An activity **file** to upload to Strava (`POST /v3/uploads`), carrying the
/// time-series data the manual activity-create endpoint can't. `data` is the
/// encoded file (GPX); `dataType` is Strava's format tag (`gpx`).
public struct StravaUpload: Sendable, Equatable {
    public var data: Data
    public var dataType: String
    public var name: String
    public var description: String?
    /// Idempotency key echoed back by Strava — the session id, so re-uploading
    /// the same session is detected as a duplicate rather than silently doubled.
    public var externalID: String?
    /// Sport type to force on the resulting activity (Strava infers a generic
    /// type from a GPX, so the uploader sets this explicitly afterward).
    public var sportType: String

    public init(
        data: Data,
        dataType: String = "gpx",
        name: String,
        description: String? = nil,
        externalID: String? = nil,
        sportType: String = "Swim"
    ) {
        self.data = data
        self.dataType = dataType
        self.name = name
        self.description = description
        self.externalID = externalID
        self.sportType = sportType
    }

    /// Multipart text fields accompanying the file part (`data_type`, `name`, …).
    public var formFields: [String: String] {
        var fields = ["data_type": dataType, "name": name]
        if let description { fields["description"] = description }
        if let externalID { fields["external_id"] = externalID }
        return fields
    }
}

/// Builds a GPX 1.1 activity file from a session's surface track plus its depth,
/// heart-rate, and water-temperature series, for Strava's `/uploads` endpoint.
///
/// Every `<trkpt>` needs a position, so the builder returns `nil` when the
/// session has no position source (no track and no tagged location) or no
/// time-series data at all — the caller then falls back to a manual activity
/// create (which carries the text summary instead).
///
/// Depth has no GPX concept, so it's mapped to (negative) elevation; heart rate
/// and water temperature ride along in the Garmin `TrackPointExtension`
/// (temperature as `atemp`, which Strava surfaces as "Temperature").
public enum StravaGPX {
    public static func build(_ session: DiveSession) -> Data? {
        let hasPosition = !session.track.isEmpty || session.location != nil
        let hasSeries = session.dives.contains { !$0.samples.isEmpty }
            || !session.heartRateSamples.isEmpty
            || !session.temperatureSamples.isEmpty
        guard hasPosition, hasSeries else { return nil }

        // Merge every source's instants into one time-ordered set of track points.
        var instants = Set<Date>()
        instants.formUnion(session.track.map(\.timestamp))
        for dive in session.dives { instants.formUnion(dive.samples.map(\.timestamp)) }
        instants.formUnion(session.heartRateSamples.map(\.timestamp))
        instants.formUnion(session.temperatureSamples.map(\.timestamp))
        let times = instants.sorted()
        guard !times.isEmpty else { return nil }

        let heartRate = session.heartRateSamples
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.bpm) }
        let temperature = session.temperatureSamples
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.celsius) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DiveFree" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
        <metadata><time>\(iso.string(from: session.startTime))</time></metadata>
        <trk><name>Freedive Session</name><type>swimming</type><trkseg>
        """
        for time in times {
            guard let position = session.surfaceLocation(at: time) ?? session.location else { continue }
            let depth = depthMeters(in: session, at: time)
            let elevation = depth > 0 ? -depth : 0
            xml += "\n<trkpt lat=\"\(coordinate(position.latitude))\" lon=\"\(coordinate(position.longitude))\">"
            xml += "<ele>\(String(format: "%.1f", elevation))</ele>"
            xml += "<time>\(iso.string(from: time))</time>"
            let bpm = interpolate(heartRate, at: time)
            let degrees = interpolate(temperature, at: time)
            if bpm != nil || degrees != nil {
                xml += "<extensions><gpxtpx:TrackPointExtension>"
                if let bpm { xml += "<gpxtpx:hr>\(Int(bpm.rounded()))</gpxtpx:hr>" }
                if let degrees { xml += "<gpxtpx:atemp>\(Int(degrees.rounded()))</gpxtpx:atemp>" }
                xml += "</gpxtpx:TrackPointExtension></extensions>"
            }
            xml += "</trkpt>"
        }
        xml += "\n</trkseg></trk>\n</gpx>\n"
        return Data(xml.utf8)
    }

    /// `%.6f` (~0.1 m) coordinate, locale-independent (`%f` always uses a period).
    private static func coordinate(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Depth (m, positive down) at an instant: interpolated within whatever dive
    /// contains it, else 0 (at the surface).
    static func depthMeters(in session: DiveSession, at time: Date) -> Double {
        for dive in session.dives where time >= dive.startTime && time <= dive.endTime {
            if let depth = dive.interpolatedDepth(at: time) { return depth }
        }
        return 0
    }

    /// Linearly-interpolated value over time-ordered `(date, value)` pairs,
    /// clamped to the endpoints; `nil` when there are no samples.
    static func interpolate(_ samples: [(Date, Double)], at time: Date) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.0 { return first.1 }
        if time >= last.0 { return last.1 }
        for (a, b) in zip(samples, samples.dropFirst()) where time >= a.0 && time <= b.0 {
            let span = b.0.timeIntervalSince(a.0)
            guard span > 0 else { return a.1 }
            let fraction = time.timeIntervalSince(a.0) / span
            return a.1 + (b.1 - a.1) * fraction
        }
        return last.1
    }
}
