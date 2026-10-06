import Foundation

/// Shared horizontal time window for the session's depth, heart-rate, and
/// temperature charts. Keeping this arithmetic separate makes the five-minute
/// limit and linked panning deterministic and testable.
struct SessionChartViewport: Equatable {
    static let maximumZoomDuration: TimeInterval = 5 * 60

    let start: Date
    let end: Date

    var fullRange: ClosedRange<Date> { start...end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var canZoom: Bool { duration > Self.maximumZoomDuration }

    func visibleRange(zoomed: Bool, startingAt requestedStart: Date?) -> ClosedRange<Date> {
        guard zoomed, canZoom else { return fullRange }
        let windowDuration = min(Self.maximumZoomDuration, duration)
        let latestStart = end.addingTimeInterval(-windowDuration)
        let lowerBound = min(max(requestedStart ?? start, start), latestStart)
        return lowerBound...lowerBound.addingTimeInterval(windowDuration)
    }

    /// Maps a horizontal drag to time and clamps it so the visible window never
    /// leaves the recorded session. Dragging left advances the timeline.
    func pannedStart(
        anchor: Date,
        horizontalTranslation: Double,
        viewportWidth: Double,
        visibleDuration: TimeInterval
    ) -> Date {
        guard viewportWidth > 0, visibleDuration > 0 else {
            return min(max(anchor, start), end.addingTimeInterval(-visibleDuration))
        }
        let latestStart = end.addingTimeInterval(-visibleDuration)
        let shift = -horizontalTranslation / viewportWidth * visibleDuration
        return min(max(anchor.addingTimeInterval(shift), start), latestStart)
    }
}
