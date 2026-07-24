import XCTest

/// Automated App Store / marketing screenshot capture.
///
/// Launches the iPhone app with `--screenshot-demo` so it boots a fresh
/// in-memory store seeded with deterministic demo content (3 spots / 4 sessions
/// / 1 trip — see `DemoData`), then walks each top-level tab and the session
/// detail, attaching a PNG for each. `Scripts/screenshots.sh` drives this test
/// across every supported locale × device and exports the attachments.
///
/// Tabs are addressed by a stable, locale-independent accessibility identifier
/// (`tab.dives` … `tab.passport`, set in `RootTabView`). This works in both
/// layouts the app renders: a bottom tab bar on iPhone (compact) and a sidebar
/// on iPad (regular width, `.sidebarAdaptable`), where SwiftUI renders the tabs
/// as cells/buttons rather than tab-bar buttons — so a fixed `boundBy:` index
/// against `tabBars` would silently find nothing on iPad.
final class ScreenshotTests: XCTestCase {

    /// A top-level tab, identified by the accessibility identifier its `Tab`
    /// carries in `RootTabView`. Order mirrors the UI: Dives · Trips · Spots ·
    /// Passport.
    private enum Tab: String {
        case dives = "tab.dives"
        case trips = "tab.trips"
        case spots = "tab.spots"
        case passport = "tab.passport"
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Resilient by design: one missing screen must not abort the rest, so a
        // failed assertion is recorded but the test keeps navigating.
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchArguments += ["--screenshot-demo"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testCaptureScreenshots() throws {
        // 01 — Dives list.
        if selectTab(.dives) {
            capture(order: 1, name: "dives")

            // 02 — Session detail (depth chart). Tap the first dive row, capture,
            // then pop back so the following tab switches start from the list.
            if openFirstDivesRow() {
                capture(order: 2, name: "detail")
                navigateBack()
            }
        }

        // 03 — Trips.
        if selectTab(.trips) {
            capture(order: 3, name: "trips")
        }

        // 04 — Spots.
        if selectTab(.spots) {
            capture(order: 4, name: "spots")
        }

        // 05 — Passport (stats).
        if selectTab(.passport) {
            capture(order: 5, name: "passport")
        }
    }

    // MARK: - Navigation

    /// Taps the tab carrying `tab.identifier`, robustly across layouts. Returns
    /// `false` (without failing hard) if no such element ever becomes hittable,
    /// so an unexpected layout can't abort the whole run.
    @discardableResult
    private func selectTab(_ tab: Tab) -> Bool {
        tap(tabID: tab.rawValue)
    }

    /// Finds and taps whichever element with `identifier` exists, trying each
    /// element type SwiftUI may use for a tab across the bottom-tab-bar (iPhone)
    /// and sidebar (iPad, `.sidebarAdaptable`) layouts. On iPad the tabs render
    /// as a sidebar collection/table, so the row may EXIST without being
    /// `isHittable` — in that case we tap a hittable descendant or the row's
    /// centre coordinate rather than giving up.
    ///
    /// Candidate queries, in order (the first few cover iPhone's bottom tab bar,
    /// the rest the iPad sidebar):
    ///   - `app.buttons`, `app.tabBars.buttons`,
    ///   - `app.cells`, `app.collectionViews.cells`, `app.collectionViews.buttons`,
    ///   - `app.tables.cells`, `app.staticTexts`,
    ///   - a catch-all `descendants(matching: .any)` match.
    ///
    /// If the first pass finds nothing, a collapsed sidebar is assumed and a
    /// sidebar-toggle button is tapped once before a second pass. If everything
    /// fails, the full accessibility tree is attached for diagnosis.
    @discardableResult
    private func tap(tabID identifier: String, timeout: TimeInterval = 10) -> Bool {
        func candidates() -> [XCUIElement] {
            [
                app.buttons[identifier],
                app.tabBars.buttons[identifier],
                app.cells[identifier],
                app.collectionViews.cells[identifier],
                app.collectionViews.buttons[identifier],
                app.tables.cells[identifier],
                app.staticTexts[identifier],
                app.descendants(matching: .any).matching(identifier: identifier).firstMatch,
            ]
        }

        // Attempt to interact with an element that exists. If it is hittable, tap
        // it directly; otherwise (a present-but-non-hittable sidebar row) tap its
        // first hittable descendant, falling back to the row's centre coordinate.
        func interact(_ element: XCUIElement) -> Bool {
            guard element.waitForExistence(timeout: 2) else { return false }

            if element.isHittable {
                element.tap()
            } else if let hittableChild = firstHittableDescendant(of: element) {
                hittableChild.tap()
            } else {
                // Non-hittable-but-present sidebar row: tap its geometric centre.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            // Let the destination render before the screenshot.
            _ = app.windows.firstMatch.waitForExistence(timeout: 5)
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        var toggledSidebar = false
        repeat {
            for element in candidates() where element.exists {
                if interact(element) { return true }
            }

            // Nothing found on this pass: a collapsed sidebar may be hiding the
            // tabs. Tap a sidebar toggle once, then retry.
            if !toggledSidebar {
                toggledSidebar = true
                if revealSidebar() { continue }
            }

            // Cheap poll; XCUITest re-queries the tree each access.
            _ = app.buttons[identifier].waitForExistence(timeout: 0.5)
        } while Date() < deadline

        // Give the manager the exact structure the robust taps still missed.
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "debug-hierarchy-\(identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTFail("No element with identifier \"\(identifier)\" could be tapped")
        return false
    }

    /// Returns the first hittable descendant of `element`, or `nil` if none.
    /// Used to reach the tappable content of a present-but-non-hittable sidebar
    /// row on iPad.
    private func firstHittableDescendant(of element: XCUIElement) -> XCUIElement? {
        for type in [XCUIElement.ElementType.button, .cell, .staticText, .other] {
            let child = element.descendants(matching: type).firstMatch
            if child.exists && child.isHittable { return child }
        }
        return nil
    }

    /// Expands a collapsed iPad sidebar so the tab rows become reachable. Tries
    /// the standard `ToggleSidebar` navigation button first, then the first
    /// navigation-bar button whose identifier or label hints at a sidebar
    /// toggle. Returns `true` if a toggle was tapped.
    @discardableResult
    private func revealSidebar() -> Bool {
        let toggle = app.navigationBars.buttons["ToggleSidebar"]
        if toggle.exists && toggle.isHittable {
            toggle.tap()
            return true
        }

        let navButtons = app.navigationBars.buttons
        for index in 0..<navButtons.count {
            let button = navButtons.element(boundBy: index)
            guard button.exists && button.isHittable else { continue }
            let hint = (button.identifier + " " + button.label).lowercased()
            if hint.contains("sidebar") || hint.contains("toggle") {
                button.tap()
                return true
            }
        }
        return false
    }

    /// Opens the first row in the Dives list. Returns `false` if no cell is
    /// present (e.g. seeding produced no sessions) rather than failing hard.
    @discardableResult
    private func openFirstDivesRow() -> Bool {
        let firstCell = app.cells.element(boundBy: 0)
        guard firstCell.waitForExistence(timeout: 10) else {
            XCTFail("No Dives row to open for the detail screenshot")
            return false
        }
        firstCell.tap()
        // The detail hosts the depth chart; give the NavigationStack push time
        // to complete before capturing.
        _ = app.windows.firstMatch.waitForExistence(timeout: 5)
        return true
    }

    /// Pops the current NavigationStack destination. Uses the leading nav-bar
    /// button (localized "Back") via `firstMatch` so it stays locale-independent.
    private func navigateBack() {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
            _ = app.windows.firstMatch.waitForExistence(timeout: 5)
        }
    }

    // MARK: - Capture

    /// Attaches a full-window screenshot named `NN-<screen>` (zero-padded order),
    /// kept always so `Scripts/screenshots.sh` can export it from the xcresult.
    private func capture(order: Int, name: String) {
        // Prefer the app window (excludes the simulator chrome); fall back to the
        // whole screen if no window is resolvable.
        let window = app.windows.firstMatch
        let screenshot = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%02d-%@", order, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
