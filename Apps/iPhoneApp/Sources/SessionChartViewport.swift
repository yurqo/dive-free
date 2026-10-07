import Foundation

/// Shared horizontal time window for the session's depth, heart-rate, and
/// temperature charts. Keeping this arithmetic separate makes zooming, linked
/// panning, and pinch anchoring deterministic and testable.
struct SessionChartViewport: Equatable {
    static let maximumZoomDuration: TimeInterval = 5 * 60
    static let standardZoomDuration: TimeInterval = 60
    static let minimumZoomDuration: TimeInterval = 5

    let start: Date
    let end: Date

    var fullRange: ClosedRange<Date> { start...end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var canZoom: Bool { duration > Self.minimumZoomDuration }
    var canUseZoomPresets: Bool { duration > Self.standardZoomDuration }

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

/// Maps samples into a continuous dive timeline by removing surface time before,
/// between, and after dives. Samples in removed intervals are omitted, and later
/// samples shift left by the removed duration. The session data is unchanged.
struct SessionChartTimeline: Equatable {
    private struct Interval: Equatable {
        let start: Date
        let end: Date
        let removesStartBoundary: Bool
        let removesEndBoundary: Bool

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    let start: Date
    let end: Date
    let hidesSurfaceIntervals: Bool
    private let surfaceIntervals: [Interval]
    private let dives: [ClosedRange<Date>]

    init(start: Date, end: Date, diveIntervals: [ClosedRange<Date>], hidesSurfaceIntervals: Bool) {
        let sessionStart = start
        let sessionEnd = max(end, start.addingTimeInterval(1))
        self.start = sessionStart
        self.end = sessionEnd
        self.hidesSurfaceIntervals = hidesSurfaceIntervals

        self.dives = diveIntervals.compactMap { interval in
            let lowerBound = max(interval.lowerBound, sessionStart)
            let upperBound = min(interval.upperBound, sessionEnd)
            guard lowerBound <= upperBound else { return nil }
            return lowerBound...upperBound
        }.sorted { $0.lowerBound < $1.lowerBound }

        var gaps: [Interval] = []
        if let firstDive = self.dives.first {
            if firstDive.lowerBound > self.start {
                gaps.append(Interval(
                    start: self.start,
                    end: firstDive.lowerBound,
                    removesStartBoundary: true,
                    removesEndBoundary: false
                ))
            }

            var previousEnd = firstDive.upperBound
            for dive in self.dives.dropFirst() {
                if dive.lowerBound > previousEnd {
                    gaps.append(Interval(
                        start: previousEnd,
                        end: dive.lowerBound,
                        removesStartBoundary: false,
                        removesEndBoundary: false
                    ))
                }
                previousEnd = max(previousEnd, dive.upperBound)
            }

            if previousEnd < self.end {
                gaps.append(Interval(
                    start: previousEnd,
                    end: self.end,
                    removesStartBoundary: false,
                    removesEndBoundary: true
                ))
            }
        }
        self.surfaceIntervals = gaps
    }

    var hasSurfaceIntervals: Bool { !surfaceIntervals.isEmpty }

    var chartStart: Date {
        guard hidesSurfaceIntervals, let firstDive = dives.first else { return start }
        return chartTime(for: firstDive.lowerBound) ?? start
    }

    var chartEnd: Date {
        guard hidesSurfaceIntervals, let lastDive = dives.last else { return end }
        return chartTime(for: lastDive.upperBound) ?? end
    }

    func chartTime(for date: Date) -> Date? {
        guard hidesSurfaceIntervals else { return date }
        var removedDuration: TimeInterval = 0
        for interval in surfaceIntervals {
            let afterStart = date > interval.start || (interval.removesStartBoundary && date == interval.start)
            let beforeEnd = date < interval.end || (interval.removesEndBoundary && date == interval.end)
            if afterStart && beforeEnd { return nil }
            if date >= interval.end { removedDuration += interval.duration }
        }
        return date.addingTimeInterval(-removedDuration)
    }

    /// A new series after each removed gap prevents metric lines from drawing
    /// across a surface interval that the user chose to hide.
    func seriesIndex(for date: Date) -> Int {
        guard hidesSurfaceIntervals else { return 0 }
        return surfaceIntervals.filter { !$0.removesStartBoundary && date >= $0.end }.count
    }
}
