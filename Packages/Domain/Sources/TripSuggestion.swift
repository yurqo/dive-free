import Foundation

/// A session reduced to what trip grouping needs (#111).
public struct TripSuggestionInput: Sendable, Equatable {
    public let id: UUID
    public let startTime: Date
    public let location: GeoPoint?   // nil when the session had no GPS fix

    public init(id: UUID, startTime: Date, location: GeoPoint?) {
        self.id = id
        self.startTime = startTime
        self.location = location
    }
}

/// Groups sessions into suggested trips (#111). A new trip starts when the gap to
/// the previous session exceeds `maxGapDays`, or the location jumps farther than
/// `maxDistanceMeters` from the last known fix. Sessions without a GPS fix chain by
/// time only (they never split a trip on location). Returns groups of session ids
/// in chronological order, the trips themselves ordered oldest → newest.
///
/// Pure and side-effect-free so the heuristic is unit-testable.
public func suggestTrips(
    from sessions: [TripSuggestionInput],
    maxGapDays: Int = 3,
    maxDistanceMeters: Double = 100_000
) -> [[UUID]] {
    let sorted = sessions.sorted { $0.startTime < $1.startTime }
    let maxGap = TimeInterval(maxGapDays) * 86_400
    var trips: [[UUID]] = []
    var current: [UUID] = []
    var lastTime: Date?
    var lastLocation: GeoPoint?

    for session in sorted {
        if let lastTime {
            let gapOK = session.startTime.timeIntervalSince(lastTime) <= maxGap
            let locationOK: Bool
            if let a = lastLocation, let b = session.location {
                locationOK = a.distance(to: b) <= maxDistanceMeters
            } else {
                locationOK = true   // can't compare without two fixes → don't split
            }
            if !(gapOK && locationOK) {
                trips.append(current)
                current = []
            }
        }
        current.append(session.id)
        lastTime = session.startTime
        if let location = session.location { lastLocation = location }
    }
    if !current.isEmpty { trips.append(current) }
    return trips
}
