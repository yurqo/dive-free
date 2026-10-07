import XCTest

@MainActor
final class SessionMediaHeaderTests: XCTestCase {
    func testHeaderAdaptsAsPhotosAreDeleted() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-extra-photo", "--screenshot-screen", "02-detail",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(app.buttons["session.header.map"].waitForExistence(timeout: 20))
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.header.photo."))
        for remaining in stride(from: 5, through: 1, by: -1) {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "session.media.header.ready").firstMatch.waitForExistence(timeout: 15))
            XCTAssertEqual(photos.count, min(remaining, 4))
            for index in 0..<photos.count {
                XCTAssertEqual(photos.element(boundBy: index).value as? String, "Ready")
            }
            photos.element(boundBy: 0).tap()
            let delete = app.buttons["photo.delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10))
            delete.tap()
            XCTAssertTrue(app.buttons["session.header.map"].waitForExistence(timeout: 10))
            XCTAssertEqual(photos.count, min(remaining - 1, 4))
        }
        XCTAssertTrue(app.buttons["session.header.map"].isHittable)
        XCTAssertTrue(app.staticTexts["session.header.title"].exists)
    }

    func testHeaderOpensMapAndPhotosAndReflectsEditedTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        let title = app.staticTexts["session.header.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "Reef encounters")
        let map = app.buttons["session.header.map"]
        let mapReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: map)
        XCTAssertEqual(XCTWaiter.wait(for: [mapReady], timeout: 15), .completed)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.header.photo."))
        XCTAssertEqual(photos.count, 4)
        XCTAssertTrue(photos.element(boundBy: 0).isHittable)

        map.tap()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(map.waitForExistence(timeout: 10))

        photos.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 10))
        // A SwiftData update must not dismiss a first-open photo pager.
        let lostViewer = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars.buttons["Done"]
        )
        lostViewer.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [lostViewer], timeout: 3), .completed)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        openEditDetails(in: app)
        let editor = app.textFields["session.edit.title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(" with friends")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Reef encounters with friends")
    }

    private func openEditDetails(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        // A freshly booted simulator can announce Apple Intelligence while
        // XCTest waits for animations. Its banner covers the navigation button.
        if springboard.staticTexts["Ready for Apple Intelligence"].exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                .press(forDuration: 0.1, thenDragTo:
                    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)))
        }
        app.navigationBars.buttons["Edit"].tap()
        let editDetails = app.buttons["Edit Details"]
        if !editDetails.waitForExistence(timeout: 5), settings.state == .runningForeground {
            // Recover only from that external system interruption; an absent
            // menu in Dive Free still fails the assertion below.
            app.activate()
            app.navigationBars.buttons["Edit"].tap()
        }
        XCTAssertTrue(editDetails.waitForExistence(timeout: 10))
        editDetails.tap()
    }
}
