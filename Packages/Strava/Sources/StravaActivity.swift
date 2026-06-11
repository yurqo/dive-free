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
