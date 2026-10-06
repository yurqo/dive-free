import XCTest

@MainActor
final class SessionChartsTests: XCTestCase {
    func testSessionChartsShareZoomControlAndFiveMinutePanHint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "--screenshot-chart-focus",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()

        let zoom = app.buttons["session.charts.zoom"]
        for _ in 0..<10 {
            if zoom.exists && zoom.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertTrue(zoom.isHittable)
        XCTAssertEqual(zoom.label, "Zoom in")

        let zoomedOut = XCTAttachment(screenshot: app.screenshot())
        zoomedOut.name = "Session profile — zoomed out"
        zoomedOut.lifetime = .keepAlways
        add(zoomedOut)

        zoom.tap()
        XCTAssertEqual(zoom.label, "Zoom out")
        let hint = app.descendants(matching: .any)
            .matching(identifier: "session.charts.zoom.hint").firstMatch
        XCTAssertTrue(hint.exists)

        let window = app.staticTexts["session.charts.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertFalse(window.label.isEmpty)

        XCTAssertTrue(hint.exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Session profile — zoomed in (5 minutes)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        zoom.tap()
        XCTAssertEqual(zoom.label, "Zoom in")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "session.charts.zoom.hint").firstMatch.exists)
    }
}
