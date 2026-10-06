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

    @Test func shortSessionsDoNotExposeZoom() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(4 * 60)
        let viewport = SessionChartViewport(start: start, end: end)

        #expect(!viewport.canZoom)
        #expect(viewport.visibleRange(zoomed: true, startingAt: start) == start...end)
    }
}
