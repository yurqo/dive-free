import Foundation
import Testing

struct SessionChartViewportTests {
    @Test func zoomShowsAtMostFiveMinutesAndPanningClampsToSession() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(15 * 60)
        let viewport = SessionChartViewport(start: start, end: end)

        #expect(viewport.canZoom)
        #expect(viewport.visibleRange(zoomed: false, startingAt: nil) == start...end)

        let firstWindow = viewport.visibleRange(zoomed: true, startingAt: nil)
        #expect(firstWindow.lowerBound == start)
        #expect(firstWindow.upperBound.timeIntervalSince(firstWindow.lowerBound) == 5 * 60)

        let panned = viewport.pannedStart(
            anchor: start,
            horizontalTranslation: -100,
            viewportWidth: 200,
            visibleDuration: 5 * 60
        )
        #expect(panned == start.addingTimeInterval(150))

        let beforeStart = viewport.pannedStart(
            anchor: start,
            horizontalTranslation: 500,
            viewportWidth: 200,
            visibleDuration: 5 * 60
        )
        #expect(beforeStart == start)

        let afterEnd = viewport.pannedStart(
            anchor: end.addingTimeInterval(-5 * 60),
            horizontalTranslation: -200,
            viewportWidth: 200,
            visibleDuration: 5 * 60
        )
        #expect(afterEnd == end.addingTimeInterval(-5 * 60))
    }

    @Test func oneMinuteWindowAndPinchKeepTheAnchorInPlace() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(15 * 60)
        let viewport = SessionChartViewport(start: start, end: end)

        let oneMinute = viewport.visibleRange(duration: SessionChartViewport.minimumZoomDuration, startingAt: start)
        #expect(oneMinute.upperBound.timeIntervalSince(oneMinute.lowerBound) == 60)

        let currentRange = start.addingTimeInterval(120)...start.addingTimeInterval(420)
        let zoomedStart = viewport.startKeepingAnchor(
            currentRange: currentRange,
            anchorFraction: 0.5,
            windowDuration: 60
        )
        #expect(zoomedStart == start.addingTimeInterval(240))
        #expect(zoomedStart.addingTimeInterval(30) == start.addingTimeInterval(270))
    }

    @Test func hidingSurfaceIntervalsCompressesOnlyGapsBetweenDives() {
        let start = Date(timeIntervalSince1970: 0)
        let timeline = SessionChartTimeline(
            start: start,
            end: start.addingTimeInterval(600),
            diveIntervals: [
                start.addingTimeInterval(60)...start.addingTimeInterval(100),
                start.addingTimeInterval(300)...start.addingTimeInterval(340)
            ],
            hidesSurfaceIntervals: true
        )

        #expect(timeline.hasSurfaceIntervals)
        #expect(timeline.chartTime(for: start.addingTimeInterval(200)) == nil)
        #expect(timeline.chartTime(for: start.addingTimeInterval(300)) == start.addingTimeInterval(100))
        #expect(timeline.chartTime(for: start.addingTimeInterval(500)) == start.addingTimeInterval(300))
        #expect(timeline.chartEnd == start.addingTimeInterval(400))
        #expect(timeline.seriesIndex(for: start.addingTimeInterval(80)) == 0)
        #expect(timeline.seriesIndex(for: start.addingTimeInterval(320)) == 1)
    }

    @Test func visibleSurfaceIntervalsKeepOriginalTimes() {
        let start = Date(timeIntervalSince1970: 0)
        let timeline = SessionChartTimeline(
            start: start,
            end: start.addingTimeInterval(600),
            diveIntervals: [
                start.addingTimeInterval(60)...start.addingTimeInterval(100),
                start.addingTimeInterval(300)...start.addingTimeInterval(340)
            ],
            hidesSurfaceIntervals: false
        )

        #expect(timeline.hasSurfaceIntervals)
        #expect(timeline.chartTime(for: start.addingTimeInterval(200)) == start.addingTimeInterval(200))
        #expect(timeline.chartEnd == start.addingTimeInterval(600))
        #expect(timeline.seriesIndex(for: start.addingTimeInterval(320)) == 0)
    }

    @Test func shortSessionsDoNotExposeZoom() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(45)
        let viewport = SessionChartViewport(start: start, end: end)

        #expect(!viewport.canZoom)
        #expect(viewport.visibleRange(zoomed: true, startingAt: start) == start...end)
    }
}
