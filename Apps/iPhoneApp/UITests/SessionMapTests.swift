import XCTest

@MainActor
final class SessionMapTests: XCTestCase {
    func testExpansionInTheFullScreenMapOpenedFromSessionDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        let map = app.buttons["session.header.map"]
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        map.tap()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 10))
        let annotation = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
            "session.map.point.", "session.map.dive-pair.", "session.map.aggregate.")).firstMatch
        XCTAssertTrue(annotation.waitForExistence(timeout: 15))
        annotation.tap()
        XCTAssertTrue(app.buttons["session.map.collapse"].waitForExistence(timeout: 5))
        capture("Map — full screen expansion", app)
        app.buttons["session.map.collapse"].tap()
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(map.waitForExistence(timeout: 10))
    }

    func testMatchingDivePairExpandsBothBoundariesAndStaysOpen() {
        let app = launch("pair")
        let pair = app.buttons["session.map.dive-pair.1"]
        XCTAssertTrue(pair.waitForExistence(timeout: 15))
        pair.tap()
        waitForExpandedCount(2, in: app)
        XCTAssertTrue(app.buttons["session.map.point-row.down-00000000-0000-0000-0000-000000000001"].exists)
        XCTAssertTrue(app.buttons["session.map.point-row.up-00000000-0000-0000-0000-000000000001"].exists)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["session.map.collapse"])
        closed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        capture("Map — matching dive boundaries expanded", app)
        app.buttons["session.map.collapse"].tap()
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
    }

    func testMixedDivePairKeepsPointCountAndExpandsBothNumbers() {
        let app = launch("mixed")
        let aggregate = aggregateButton(in: app)
        XCTAssertTrue(aggregate.waitForExistence(timeout: 15))
        XCTAssertEqual(aggregate.label, "Points: 2")
        aggregate.tap()
        waitForExpandedCount(2, in: app)
        XCTAssertTrue(app.buttons["session.map.point-row.up-00000000-0000-0000-0000-000000000001"].exists)
        XCTAssertTrue(app.buttons["session.map.point-row.down-00000000-0000-0000-0000-000000000002"].exists)
        capture("Map — mixed dive boundaries expanded", app)
    }

    func testLargeClusterExposesEveryPointAndListSelectionRevealsLastBoundary() {
        let app = launch("dense")
        let aggregate = aggregateButton(in: app)
        XCTAssertTrue(aggregate.waitForExistence(timeout: 15))
        XCTAssertEqual(aggregate.label, "Points: 24")
        aggregate.tap()
        XCTAssertTrue(app.buttons["session.map.collapse"].waitForExistence(timeout: 5))
        let lastID = "up-00000000-0000-0000-0000-000000000012"
        let last = app.buttons["session.map.point-row.\(lastID)"]
        let list = app.scrollViews["session.map.point-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if last.exists && last.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertTrue(app.buttons["session.map.expanded.point.\(lastID)"].waitForExistence(timeout: 5))
        capture("Map — dense group with last point selected", app)
    }

    func testFarApartStartAndEndStayAtDistinctLocations() {
        let app = launch("wide")
        let start = app.buttons["session.map.point.down-00000000-0000-0000-0000-000000000001"]
        let end = app.buttons["session.map.point.up-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(end.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["session.map.dive-pair.1"].exists)
        XCTAssertGreaterThan(hypot(start.frame.midX - end.frame.midX, start.frame.midY - end.frame.midY), 52)
        capture("Map — separated dive boundaries", app)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-map", "--screenshot-map-case", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 20))
        return app
    }

    private func aggregateButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.map.aggregate.")).firstMatch
    }

    private func waitForExpandedCount(_ count: Int, in app: XCUIApplication) {
        let points = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.map.expanded.point."))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: points)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
