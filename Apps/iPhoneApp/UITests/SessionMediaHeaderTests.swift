import XCTest

@MainActor
final class SessionMediaHeaderTests: XCTestCase {
    func testHeaderAdaptsAsPhotosAreDeleted() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(app.buttons["session.header.map"].waitForExistence(timeout: 20))
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.header.photo."))
        for remaining in stride(from: 4, through: 1, by: -1) {
            XCTAssertEqual(photos.count, remaining)
            photos.element(boundBy: 0).tap()
            let delete = app.buttons["photo.delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10))
            delete.tap()
            XCTAssertTrue(app.buttons["session.header.map"].waitForExistence(timeout: 10))
            XCTAssertEqual(photos.count, remaining - 1)
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
        XCTAssertTrue(map.isHittable)
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

        app.navigationBars.buttons["Edit"].tap()
        app.buttons["Edit Details"].tap()
        let editor = app.textFields["session.edit.title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(" with friends")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Reef encounters with friends")
    }
}
