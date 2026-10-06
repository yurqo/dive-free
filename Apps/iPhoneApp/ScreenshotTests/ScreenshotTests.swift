import XCTest
import UIKit

/// Automated App Store / marketing screenshot capture.
///
/// Launches the iPhone app with `--screenshot-demo` so it boots a fresh
/// in-memory store seeded with deterministic demo content (3 spots / 4 sessions
/// / 1 trip — see `DemoData`), then opens each top-level tab and session
/// summary. Separate dive-profile captures supply the heroes without
/// replacing a published screenshot. `Scripts/screenshots.sh` drives this test
/// across every supported locale × device and exports the attachments.
///
/// Direct launch destinations retain the real app's navigation and tab layout.
/// A debug-only selection probe verifies the destination across every locale.
@MainActor
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    /// Fails the test unless the app *resolved* the language we requested.
    ///
    /// This is the check that guards the expensive silent failure: `-testLanguage`
    /// is ignored on the `test-without-building -xctestrun` path, so a broken
    /// override produces a full set of perfectly valid-looking screenshots in the
    /// wrong language. Nothing about the images themselves reveals that — the
    /// script's cross-locale image diff was verified to *pass* on the exact data
    /// that shipped 80 Ukrainian screenshots to App Store Connect (a handful of
    /// jittering map-thumbnail pixels was enough to make the sets differ).
    ///
    /// So we ask the app instead: under `--screenshot-demo` it publishes
    /// `Bundle.main.preferredLocalizations.first` as an accessibility identifier
    /// `screenshot.lang.<code>` (see `View.screenshotLanguageProbe()`), and we
    /// compare that against `SCREENSHOT_LANGUAGE`. Failing here makes this locale's
    /// `xcodebuild` invocation exit non-zero, which `Scripts/screenshots.sh` counts
    /// as a failed combination and turns into `exit 1` — nothing reaches fastlane.
    ///
    /// No `SCREENSHOT_LANGUAGE` (running straight from Xcode) means no requested
    /// language to compare against, so the check is skipped.
    private func assertRequestedLanguageApplied() {
        let requested = ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] ?? ""
        guard !requested.isEmpty else { return }

        // Match on the PREFIX, not on `screenshot.lang.<requested>`, so a mismatch
        // can name the language the app actually used — the single most useful fact
        // when this fires ("asked for uk, got en" = override not applied at all).
        //
        // Scoped to `staticTexts` because the probe IS a `Text`, and because this
        // runs on the critical path of every locale × device run: a
        // `descendants(matching: .any)` predicate forces a full accessibility-tree
        // snapshot on each poll, against a screen full of map thumbnails and list
        // rows. The typed query is roughly an order of magnitude cheaper.
        let probe = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.languageProbePrefix))
            .firstMatch
        guard probe.waitForExistence(timeout: 30) else {
            XCTFail("""
                The language probe (\(Self.languageProbePrefix)*) never appeared, so \
                the resolved language could not be verified (requested \
                "\(requested)"). NOTE: this is a missing/late probe, NOT a \
                wrong-language result — the app may simply have been too slow to \
                render, or the probe may be gone (View.screenshotLanguageProbe() \
                removed, app not launched with --screenshot-demo, or not a DEBUG \
                build). Refusing to capture unverified screenshots either way.
                """)
            return
        }

        let resolved = probe.identifier.replacingOccurrences(
            of: Self.languageProbePrefix, with: ""
        )
        // EXACT (case-insensitive) compare, deliberately. The probe reports
        // `Bundle.main.preferredLocalizations.first`, which is always one of the
        // bundle's own localization codes (en es fr it de pt ja uk) — exactly the
        // codes `Scripts/screenshots.sh` requests — so there is nothing to
        // normalize. Any loosening (e.g. comparing only the subtag before "-") would
        // be pure downside the day a script variant is added: it would accept
        // `zh-Hant` for a requested `zh-Hans` and ship wrong-script screenshots.
        guard resolved.caseInsensitiveCompare(requested) == .orderedSame else {
            XCTFail("""
                Language override NOT applied: requested "\(requested)" but the app \
                resolved "\(resolved)". These screenshots would be in the wrong \
                language. Check that Scripts/screenshots.sh still patches \
                SCREENSHOT_LANGUAGE / TestLanguage into the per-locale .xctestrun and \
                that the requested code exists in Localizable.xcstrings.
                """)
            return
        }
    }

    /// Identifier prefix the app's language probe uses (see `screenshotLanguageProbe`).
    private static let languageProbePrefix = "screenshot.lang."

    /// Forces the app under test into a specific language/region by launch
    /// argument, driven by `SCREENSHOT_LANGUAGE` / `SCREENSHOT_LOCALE` in the
    /// test runner's environment.
    ///
    /// WHY this exists instead of relying on `xcodebuild -testLanguage`
    /// / `-testRegion`: those flags are silently IGNORED on the
    /// `test-without-building -xctestrun …` path that `Scripts/screenshots.sh`
    /// uses to reuse one build across every locale. The symptom is nasty because
    /// it is invisible — every locale renders in the *simulator's* device
    /// language. (That shipped 80 wrong screenshots to App Store Connect once,
    /// which is why `assertRequestedLanguageApplied()` now verifies the *resolved*
    /// localization on every launch.) Overriding `-AppleLanguages` / `-AppleLocale`
    /// at launch is what fastlane's own `snapshot` does, and it works on every path.
    ///
    /// Without language/region overrides, use the device defaults. Screenshot
    /// units remain metric even when running this test straight from Xcode.
    private func applyLanguageOverridesFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        // `-AppleLanguages` takes a plist-style array *string*: "(uk)".
        if let language = environment["SCREENSHOT_LANGUAGE"], !language.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
        // `-AppleLocale` drives number/date/measurement formatting: "uk_UA".
        if let locale = environment["SCREENSHOT_LOCALE"], !locale.isEmpty {
            app.launchArguments += ["-AppleLocale", locale]
        }
        // Pin units as well as locale: a saved simulator preference otherwise
        // survives capture runs and can disagree with the companion Watch.
        app.launchArguments += ["-unitMode", "metric"]
    }

    func testCaptureScreenshots() throws {
        // Keep setup in this actor-isolated test. XCTest's nonisolated async
        // lifecycle cannot safely send its test-case instance to MainActor.
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-demo"]
        app.launchEnvironment["TZ"] = "Asia/Singapore"
        applyLanguageOverridesFromEnvironment()
        app.launch()
        assertRequestedLanguageApplied()
        defer { app = nil }

        // Launch the existing deterministic destinations directly. New SwiftUI
        // tab bars do not consistently expose Tab accessibility identifiers.
        for (order, name) in [(1, "dives"), (2, "detail"), (3, "trips"), (4, "spots"), (5, "passport")] {
            if launchScreenshotScreen(String(format: "%02d-%@", order, name)) {
                capture(order: order, name: name)
            }
        }

        // Input only: Fastlane excludes this raw image from the published set.
        // Each hero reuses these alongside the companion devices and Watch live.
        if launchScreenshotScreen("02-dive-profile") {
            capture(order: 90, name: "hero-dive-profile")
        }
    }

    // MARK: - Navigation

    private func launchScreenshotScreen(_ screen: String) -> Bool {
        app.terminate()
        if let flag = app.launchArguments.firstIndex(of: "--screenshot-screen") {
            app.launchArguments.removeSubrange(flag...flag + 1)
        }
        app.launchArguments += ["--screenshot-screen", screen]
        app.launch()
        assertRequestedLanguageApplied()
        let tabs = ["01-dives": "tab.dives", "03-trips": "tab.trips",
                    "04-spots": "tab.spots", "05-passport": "tab.passport"]
        let identifier = tabs[screen].map { "screenshot.selected.\($0)" } ?? "screenshot.\(screen)"
        let destination = app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
        guard destination.waitForExistence(timeout: 15) else {
            XCTFail("The screenshot screen \(screen) did not appear")
            return false
        }
        if screen == "02-detail" {
            let summary = app.descendants(matching: .any)
                .matching(identifier: "screenshot.session.total").firstMatch
            guard summary.waitForExistence(timeout: 15), summary.isHittable else {
                XCTFail("Session summary content did not render; refusing a blank capture")
                return false
            }
            let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.header.photo."))
            guard photos.count == 4 else {
                XCTFail("The Jemeluk session header must include all four fixture photos")
                return false
            }
            let ready = app.descendants(matching: .any)
                .matching(identifier: "session.media.header.ready").firstMatch
            guard ready.waitForExistence(timeout: 15) else {
                XCTFail("Session media did not render")
                return false
            }
        }
        return true
    }

    // MARK: - Capture

    /// Attaches a full-window screenshot named `NN-<screen>` (zero-padded order),
    /// kept always so `Scripts/screenshots.sh` can export it from the xcresult.
    private func capture(order: Int, name: String) {
        // Capture the rectangular app window. A whole-display capture can bake
        // the hardware corner mask into the five regular App Store images.
        let window = app.windows.firstMatch
        guard window.exists else { XCTFail("Missing app window for \(name)"); return }
        let image = window.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let opaque = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let png = opaque.pngData() else { XCTFail("PNG encoding failed for \(name)"); return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = String(format: "%02d-%@", order, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
