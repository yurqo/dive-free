import XCTest

@MainActor
final class NoteEditorTests: XCTestCase {
    func testFirstOpeningStaysPresentedAndDraftSurvivesSaveAndCancel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo", "--screenshot-screen", "02-detail",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.row.")).firstMatch
        for _ in 0..<12 {
            if row.exists && row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "The note row should be reachable")
        row.tap()
        let title = app.textFields["note.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The first tap must open the editor")
        title.tap()
        title.typeText("First opening regression")

        // Catch dismissal during initial SwiftData/query and speech-language
        // loading, including losing the user's draft after it has been entered.
        let lostEditor = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        lostEditor.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [lostEditor], timeout: 6), .completed)
        XCTAssertEqual(title.value as? String, "First opening regression")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["First opening regression"].waitForExistence(timeout: 10))

        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "First opening regression")
        title.tap()
        title.typeText(" cancelled")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["First opening regression"].waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "First opening regression")
    }
}
