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

    /// Finds and taps whichever element with `identifier` exists and is
    /// hittable, trying each element type SwiftUI may use for a tab across the
    /// bottom-tab-bar (iPhone) and sidebar (iPad) layouts:
    ///   - `app.buttons` — plain button (covers both layouts in most cases),
    ///   - `app.tabBars.buttons` — the iPhone bottom tab bar,
    ///   - `app.cells` — sidebar rows on iPad,
    ///   - `app.otherElements` — a final fallback.
    /// Waits (polling) until one is hittable, up to `timeout`.
    @discardableResult
    private func tap(tabID identifier: String, timeout: TimeInterval = 15) -> Bool {
        let candidates: [XCUIElement] = [
            app.buttons[identifier],
            app.tabBars.buttons[identifier],
            app.cells[identifier],
            app.otherElements[identifier],
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for element in candidates where element.exists && element.isHittable {
                element.tap()
                // Let the destination render before the screenshot.
                _ = app.windows.firstMatch.waitForExistence(timeout: 5)
                return true
            }
            // Cheap poll; XCUITest re-queries the tree each access.
            _ = candidates.first?.waitForExistence(timeout: 0.5)
        } while Date() < deadline

        XCTFail("No hittable element with identifier \"\(identifier)\" appeared")
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
