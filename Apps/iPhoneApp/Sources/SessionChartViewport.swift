import Foundation

/// Shared horizontal time window for the session's depth, heart-rate, and
/// temperature charts. Keeping this arithmetic separate makes zooming, linked
/// panning, and pinch anchoring deterministic and testable.
struct SessionChartViewport: Equatable {
    static let maximumZoomDuration: TimeInterval = 5 * 60
    static let minimumZoomDuration: TimeInterval = 60

    let start: Date
    let end: Date

    var fullRange: ClosedRange<Date> { start...end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var canZoom: Bool { duration > Self.minimumZoomDuration }

    func visibleRange(zoomed: Bool, startingAt requestedStart: Date?) -> ClosedRange<Date> {
        visibleRange(duration: zoomed ? Self.maximumZoomDuration : nil, startingAt: requestedStart)
    }

    func visibleRange(duration requestedDuration: TimeInterval?, startingAt requestedStart: Date?) -> ClosedRange<Date> {
        guard let requestedDuration, canZoom else { return fullRange }
        let windowDuration = min(max(requestedDuration, Self.minimumZoomDuration), duration)
        let latestStart = end.addingTimeInterval(-windowDuration)
        let lowerBound = min(max(requestedStart ?? start, start), latestStart)
        return lowerBound...lowerBound.addingTimeInterval(windowDuration)
    }

    /// Changes the window width while preserving the time below a pinch anchor.
    func startKeepingAnchor(
        currentRange: ClosedRange<Date>,
        anchorFraction: Double,
        windowDuration: TimeInterval
    ) -> Date {
        let fraction = min(max(anchorFraction, 0), 1)
        let anchorDate = currentRange.lowerBound.addingTimeInterval(
            currentRange.upperBound.timeIntervalSince(currentRange.lowerBound) * fraction
        )
        let boundedDuration = min(max(windowDuration, Self.minimumZoomDuration), duration)
        let latestStart = end.addingTimeInterval(-boundedDuration)
        let requestedStart = anchorDate.addingTimeInterval(-boundedDuration * fraction)
        return min(max(requestedStart, start), latestStart)
    }

    /// Maps a horizontal drag to time and clamps it so the visible window never
    /// leaves the recorded session. Dragging left advances the timeline.
    func pannedStart(
        anchor: Date,
        horizontalTranslation: Double,
        viewportWidth: Double,
        visibleDuration: TimeInterval
    ) -> Date {
        let boundedDuration = min(max(visibleDuration, 0), duration)
        guard viewportWidth > 0, boundedDuration > 0 else {
            return min(max(anchor, start), end.addingTimeInterval(-boundedDuration))
        }
        let latestStart = end.addingTimeInterval(-boundedDuration)
        let shift = -horizontalTranslation / viewportWidth * boundedDuration
        return min(max(anchor.addingTimeInterval(shift), start), latestStart)
    }
}

/// Maps samples into a continuous chart timeline by removing only the gaps
/// between dives. Samples during those gaps are omitted, and later samples are
/// shifted left by the time removed. The original session data is never changed.
struct SessionChartTimeline: Equatable {
    private struct Interval: Equatable {
        let start: Date
        let end: Date

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    let start: Date
    let end: Date
    let hidesSurfaceIntervals: Bool
    private let surfaceIntervals: [Interval]

    init(start: Date, end: Date, diveIntervals: [ClosedRange<Date>], hidesSurfaceIntervals: Bool) {
        self.start = start
        self.end = max(end, start.addingTimeInterval(1))
        self.hidesSurfaceIntervals = hidesSurfaceIntervals

        let dives = diveIntervals.sorted { $0.lowerBound < $1.lowerBound }
        var gaps: [Interval] = []
        var previousEnd: Date?
        for dive in dives {
            if let previousEnd, dive.lowerBound > previousEnd {
                gaps.append(Interval(start: previousEnd, end: dive.lowerBound))
            }
            previousEnd = max(previousEnd ?? dive.upperBound, dive.upperBound)
        }
        self.surfaceIntervals = gaps
    }

    var hasSurfaceIntervals: Bool { !surfaceIntervals.isEmpty }

    var chartStart: Date { start }

    var chartEnd: Date {
        chartTime(for: end) ?? end
    }

    func chartTime(for date: Date) -> Date? {
        guard hidesSurfaceIntervals else { return date }
        var removedDuration: TimeInterval = 0
        for interval in surfaceIntervals {
            if date > interval.start && date < interval.end { return nil }
            if date >= interval.end { removedDuration += interval.duration }
        }
        return date.addingTimeInterval(-removedDuration)
    }

    /// A new series after each removed gap prevents metric lines from drawing
    /// across a surface interval that the user chose to hide.
    func seriesIndex(for date: Date) -> Int {
        guard hidesSurfaceIntervals else { return 0 }
        return surfaceIntervals.filter { date >= $0.end }.count
    }
}
