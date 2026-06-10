import Foundation
import Domain

/// Minimal Strava "activity" payload mapped from a dive session.
/// Strava has no freediving type, so sessions are exported as a generic workout.
public struct StravaActivity: Sendable, Equatable, Codable {
    public var name: String
    public var type: String
    public var startDate: Date
    public var elapsedSeconds: Int
    public var description: String?

    public init(name: String, type: String = "Workout", startDate: Date, elapsedSeconds: Int, description: String? = nil) {
        self.name = name
        self.type = type
        self.startDate = startDate
        self.elapsedSeconds = elapsedSeconds
        self.description = description
    }

    /// Builds an activity from a completed session.
    public init(session: DiveSession) {
        let end = session.endTime ?? session.startTime
        self.init(
            name: "Freedive Session",
            startDate: session.startTime,
            elapsedSeconds: Int(end.timeIntervalSince(session.startTime)),
            description: "\(session.diveCount) dives, max depth \(String(format: "%.1f", session.maxDepthMeters)) m"
        )
    }
}
