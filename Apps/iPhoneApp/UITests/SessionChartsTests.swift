import XCTest

@MainActor
final class SessionChartsTests: XCTestCase {
    func testSessionChartsShareZoomControlAndLinkedZoomLevels() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "--screenshot-chart-focus",
                               "--screenshot-chart-with-surface-intervals",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()

        let zoom = app.buttons["session.charts.zoom"]
        for _ in 0..<10 {
            if zoom.exists && zoom.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertTrue(zoom.isHittable)
        XCTAssertEqual(zoom.label, "Zoom to 5 minutes")

        let zoomedOut = XCTAttachment(screenshot: app.screenshot())
        zoomedOut.name = "Session profile — zoomed out"
        zoomedOut.lifetime = .keepAlways
        add(zoomedOut)

        zoom.tap()
        waitForZoomLabel("Zoom to 1 minute", on: zoom)
        let hint = app.descendants(matching: .any)
            .matching(identifier: "session.charts.zoom.hint").firstMatch
        XCTAssertTrue(hint.exists)

        let window = app.staticTexts["session.charts.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertFalse(window.label.isEmpty)

        XCTAssertTrue(hint.exists)

        let fiveMinuteScreenshot = XCTAttachment(screenshot: app.screenshot())
        fiveMinuteScreenshot.name = "Session profile — zoomed in (5 minutes)"
        fiveMinuteScreenshot.lifetime = .keepAlways
        add(fiveMinuteScreenshot)

        zoom.tap()
        waitForZoomLabel("Zoom to full session", on: zoom)
        let oneMinuteScreenshot = XCTAttachment(screenshot: app.screenshot())
        oneMinuteScreenshot.name = "Session profile — zoomed in (1 minute)"
        oneMinuteScreenshot.lifetime = .keepAlways
        add(oneMinuteScreenshot)

        zoom.tap()
        waitForZoomLabel("Zoom to 5 minutes", on: zoom)
        let hintHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hint)
        XCTAssertEqual(XCTWaiter.wait(for: [hintHidden], timeout: 3), .completed)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Session profile — zoomed out"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hideSurfaceIntervals = app.switches["session.charts.hideSurfaceIntervals"]
        XCTAssertTrue(hideSurfaceIntervals.waitForExistence(timeout: 5))
        XCTAssertTrue(hideSurfaceIntervals.isHittable)
        // The accessible Toggle includes its label. On iPad, 90% of the row's
        // width can still miss the switch; target the trailing control itself.
        hideSurfaceIntervals.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -25, dy: 0)).tap()
        let surfaceIntervalsHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: hideSurfaceIntervals
        )
        XCTAssertEqual(XCTWaiter.wait(for: [surfaceIntervalsHidden], timeout: 3), .completed)

        let compressedTimeline = XCTAttachment(screenshot: app.screenshot())
        compressedTimeline.name = "Session profile — surface intervals hidden"
        compressedTimeline.lifetime = .keepAlways
        add(compressedTimeline)
    }

    private func waitForZoomLabel(_ expected: String, on button: XCUIElement) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 3), .completed)
    }
}
