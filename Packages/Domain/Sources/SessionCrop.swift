import Foundation

/// The outcome of cropping a session's surface tails: the trimmed session plus a
/// tally of everything that was dropped. Persistence uses `droppedMarkers` to
/// clean up voice-note artifacts, and the UI uses the counts (and whether any
/// dropped marker `hasAudio`) for the confirmation copy.
public struct SessionCropResult: Sendable, Equatable {
    /// The cropped copy of the session (new `startTime`/`endTime`, trimmed series).
    public var session: DiveSession
    /// Number of `track` points removed (outside the kept range).
    public var droppedTrackPoints: Int
    /// Number of `heartRateSamples` removed.
    public var droppedHeartRateSamples: Int
    /// Number of `temperatureSamples` removed.
    public var droppedTemperatureSamples: Int
    /// Markers removed (their timestamp fell outside the kept range). Includes any
    /// attached voice notes, so callers can delete the audio artifacts.
    public var droppedMarkers: [EventMarker]

    public init(
        session: DiveSession,
        droppedTrackPoints: Int,
        droppedHeartRateSamples: Int,
        droppedTemperatureSamples: Int,
        droppedMarkers: [EventMarker]
    ) {
        self.session = session
        self.droppedTrackPoints = droppedTrackPoints
        self.droppedHeartRateSamples = droppedHeartRateSamples
        self.droppedTemperatureSamples = droppedTemperatureSamples
        self.droppedMarkers = droppedMarkers
    }
}

public extension DiveSession {
    // MARK: - Crop bounds (for the UI's slider handles)

    /// Earliest dive start, or `nil` when there are no dives.
    var firstDiveStart: Date? {
        dives.map(\.startTime).min()
    }

    /// Latest dive end, or `nil` when there are no dives.
    var lastDiveEnd: Date? {
        dives.map(\.endTime).max()
    }

    /// Where the crop-start handle may move: from `startTime` up to (but never
    /// past) the first dive. Falls back to the session end (or start) with no
    /// dives. Always a valid range (lower ≤ upper), even when the bounds coincide.
    var croppableStartRange: ClosedRange<Date> {
        let lower = startTime
        let upperCandidate = firstDiveStart ?? endTime ?? startTime
        let upper = max(lower, upperCandidate)
        return lower...upper
    }

    /// Where the crop-end handle may move: from the last dive's end up to the
    /// session end (never before the last dive). Falls back to `startTime` /
    /// session end with no dives. Always a valid range (lower ≤ upper).
    var croppableEndRange: ClosedRange<Date> {
        let sessionEnd = endTime ?? startTime
        let lowerCandidate = lastDiveEnd ?? startTime
        // Clamp the lower bound into the session so it can't exceed the upper.
        let lower = min(lowerCandidate, sessionEnd)
        let upper = max(lower, sessionEnd)
        return lower...upper
    }

    // MARK: - Crop operation

    /// A copy of this session cropped to `range`, with the dropped series/markers
    /// reported alongside.
    ///
    /// The incoming range is **defensively clamped** so a crop can never cut
    /// through a dive or exceed the session:
    /// - `newStart` is pulled forward to at least `startTime` and no later than
    ///   the first dive's start (so the first dive always survives intact).
    /// - `newEnd` is pushed back to at most the session end and no earlier than
    ///   the last dive's end (so the last dive always survives intact).
    ///
    /// If clamping would invert the bounds, it falls back to the dive span (or the
    /// original session bounds) so the result is always a valid range.
    ///
    /// `track` / `heartRateSamples` / `temperatureSamples` / `markers` are kept
    /// when their `timestamp` is within the **inclusive** `[newStart, newEnd]`.
    /// Everything else (dives, location, weather, conditions, energy,
    /// `workoutUUID`, title/notes/rating, `smoothTrack`, `id`, …) is unchanged.
    func cropped(to range: ClosedRange<Date>) -> SessionCropResult {
        let sessionEnd = endTime ?? startTime
        let firstDive = firstDiveStart
        let lastDive = lastDiveEnd

        // Clamp the start into [startTime, firstDiveStart ?? sessionEnd].
        let startCeiling = firstDive ?? sessionEnd
        var newStart = min(max(range.lowerBound, startTime), startCeiling)

        // Clamp the end into [lastDiveEnd ?? startTime, sessionEnd].
        let endFloor = lastDive ?? startTime
        var newEnd = max(min(range.upperBound, sessionEnd), endFloor)

        // Guard against an inverted result (e.g. a wild/empty input range). Prefer
        // the dive span; otherwise fall back to the original session bounds.
        if newStart > newEnd {
            if let firstDive, let lastDive, firstDive <= lastDive {
                newStart = firstDive
                newEnd = lastDive
            } else {
                newStart = startTime
                newEnd = sessionEnd
            }
        }

        let keptRange = newStart...newEnd

        let keptTrack = track.filter { keptRange.contains($0.timestamp) }
        let keptHeartRate = heartRateSamples.filter { keptRange.contains($0.timestamp) }
        let keptTemperature = temperatureSamples.filter { keptRange.contains($0.timestamp) }
        let keptMarkers = markers.filter { keptRange.contains($0.timestamp) }
        let droppedMarkers = markers.filter { !keptRange.contains($0.timestamp) }

        var cropped = self
        cropped.startTime = newStart
        cropped.endTime = newEnd
        cropped.track = keptTrack
        cropped.heartRateSamples = keptHeartRate
        cropped.temperatureSamples = keptTemperature
        cropped.markers = keptMarkers

        return SessionCropResult(
            session: cropped,
            droppedTrackPoints: track.count - keptTrack.count,
            droppedHeartRateSamples: heartRateSamples.count - keptHeartRate.count,
            droppedTemperatureSamples: temperatureSamples.count - keptTemperature.count,
            droppedMarkers: droppedMarkers
        )
    }
}
