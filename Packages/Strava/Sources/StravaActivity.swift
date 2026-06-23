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

    /// Builds an activity from a completed session. The description is a short
    /// dive summary; the GPS position rides in the uploaded track, so the raw
    /// coordinate isn't spelled out in the text.
    public init(session: DiveSession) {
        let end = session.endTime ?? session.startTime
        let summary = "\(session.diveCount) dives, max depth \(String(format: "%.1f", session.maxDepthMeters)) m"
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
/// encoded file (FIT); `dataType` is Strava's format tag (`fit`).
public struct StravaUpload: Sendable, Equatable {
    public var data: Data
    public var dataType: String
    public var name: String
    public var description: String?
    /// Idempotency key echoed back by Strava — the session id, so re-uploading
    /// the same session is detected as a duplicate rather than silently doubled.
    public var externalID: String?
    /// Sport type to force on the resulting activity (Strava infers a generic
    /// type from the upload, so the uploader sets this explicitly afterward).
    public var sportType: String

    public init(
        data: Data,
        dataType: String = "fit",
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
