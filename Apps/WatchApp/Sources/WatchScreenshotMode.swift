#if DEBUG
import Foundation
import SwiftUI
import SwiftData
import Domain
import Persistence
import Sensors
import Session

/// DEBUG-only screenshot mode for the watch app.
///
/// WHY IT EXISTS AT ALL: `XCTest.framework` does not ship in the watchOS
/// simulator SDK, so there is no `XCUIApplication` and no UI automation on this
/// platform — the iPhone/iPad trick of driving the app from a UI test cannot be
/// reproduced here. Instead the app itself takes both roles: a launch argument
/// picks ONE screen, the app boots straight into it, and `Scripts/screenshots.sh`
/// photographs it with `xcrun simctl io … screenshot`. One process per screen,
/// no navigation, nothing to tap.
///
/// Two launch arguments, both required for anything below to run:
///   --screenshot-demo            seed a throwaway in-memory store (`DemoData`)
///   --screenshot-screen <slug>   which screen to render (see `Screen`)
///
/// Safety: the whole file is `#if DEBUG`, so it is absent from the App Store
/// binary; and even in DEBUG nothing here runs unless BOTH arguments are passed,
/// so an ordinary debug launch behaves exactly as before — same store, same root
/// view, same real sensors.
enum WatchScreenshotMode {
    /// Same flag the iPhone app uses (`DiveFreeApp.makeContainer`) — one
    /// vocabulary across both screenshot pipelines.
    static let demoFlag = "--screenshot-demo"
    static let screenFlag = "--screenshot-screen"

    /// A capturable screen. The raw values are the `NN-slug` filenames the
    /// script writes, so the app and the script share ONE list of screens and a
    /// typo cannot silently produce a differently-named PNG. Ordering is the App
    /// Store display order: the live dive first (the product's core moment), then
    /// what it leaves behind, then how little it takes to start.
    enum Screen: String, CaseIterable {
        /// Live session, mid-dive: the big dive clock, current depth, water
        /// temperature, heart rate and the Crown action selector.
        case live = "01-live"
        /// The just-completed session's summary: stats table + depth chart.
        case summary = "02-summary"
        /// One dive's depth profile, with the markers placed during it.
        case profile = "03-profile"
        /// The dive log kept on the watch.
        case sessions = "04-sessions"
        /// The home screen: one button to start a session.
        case start = "05-start"
    }

    /// Whether this process was launched for screenshot capture.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(demoFlag)
    }

    /// The screen requested on the command line, or `nil` when this is not a
    /// screenshot launch.
    ///
    /// An unknown or missing slug is a HARD ERROR, not a fallback. The old fallback
    /// to `.start` meant a slug rename (or a `WATCH_SCREENS`/`Screen` drift) shipped
    /// a second Start-screen shot in place of the intended screen — silently, with
    /// exit code 0. Crashing here writes no "screen ready" marker, so
    /// `Scripts/screenshots.sh` fails the capture instead (fail closed). DEBUG-only,
    /// so no shipping build can reach it.
    static var screen: Screen? {
        guard isEnabled else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: screenFlag),
              arguments.index(after: flagIndex) < arguments.endIndex
        else {
            fatalError("\(demoFlag) requires \(screenFlag) <NN-slug>, but none was given")
        }
        let raw = arguments[arguments.index(after: flagIndex)]
        guard let screen = Screen(rawValue: raw) else {
            fatalError("""
                Unknown \(screenFlag) "\(raw)". Known slugs: \
                \(Screen.allCases.map(\.rawValue).joined(separator: ", ")). \
                Keep WATCH_SCREENS in Scripts/screenshots.sh in step with Screen.
                """)
        }
        return screen
    }

    // MARK: - Resolved-language probe

    /// File (in the app's Documents directory) the app writes its RESOLVED
    /// localization into, for `Scripts/screenshots.sh` to read back via
    /// `xcrun simctl get_app_container … data`.
    static let languageFileName = "screenshot-language.txt"

    /// Publishes `Bundle.main.preferredLocalizations.first` — the localization
    /// watchOS actually chose for this launch — so the capture script can compare
    /// it against the language it asked for and fail the run on a mismatch.
    ///
    /// WHY a file rather than trusting the launch argument: the watch path has no
    /// XCUITest, so the accessibility-identifier probe the iOS run uses
    /// (`View.screenshotLanguageProbe`) is unreachable here — and "the flag was on
    /// the command line" is exactly the assumption that once shipped 80
    /// wrong-language screenshots to App Store Connect. Only the app can say which
    /// localization it ended up with, so it writes it down where the script can
    /// read it.
    ///
    /// Best-effort by design: if the write fails no file appears, and the script
    /// treats a missing file as a FAILURE (fail closed), so a broken probe can
    /// never be mistaken for a passing check.
    static func publishResolvedLanguage() {
        guard isEnabled else { return }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let resolved = Bundle.main.preferredLocalizations.first ?? "unknown"
        try? resolved.write(
            to: documents.appendingPathComponent(languageFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Screen-ready handshake

    /// File the app writes ONCE the intended screen has actually rendered with its
    /// data, containing that screen's slug. `Scripts/screenshots.sh` polls for it
    /// (matching the requested slug) before it photographs, and fails the capture
    /// if it never appears.
    static let readyFileName = "screenshot-ready.txt"

    /// Announces that `screen` is on screen and populated. Called from the point in
    /// `WatchScreenshotRootView` where the screen's data is guaranteed present — for
    /// the live screen, only after the session is genuinely `.active`.
    ///
    /// WHY the handshake replaced a fixed `sleep`: a plain timed wait photographs
    /// whatever is up when the timer fires, so a cold-launch stall, a thrown
    /// `startSession()`, or a slug that rendered the wrong view all shipped a
    /// valid-looking-but-wrong PNG with exit code 0. With the marker, the script
    /// captures only what the app has confirmed is the right, populated screen, and
    /// a screen that never renders is a timeout → a failed capture, never a shipped
    /// one. Fail-closed: a failed write means no file, which the script treats as
    /// failure.
    static func publishScreenReady(_ screen: Screen) {
        guard isEnabled else { return }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? screen.rawValue.write(
            to: documents.appendingPathComponent(readyFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Demo store

    /// A fresh in-memory store seeded with the shared `DemoData` fixtures — the
    /// same content the iPhone screenshots use, so both sets show the same trip.
    /// In-memory means the real on-watch database is never opened, let alone
    /// written to, by a screenshot launch.
    @MainActor
    static func makeDemoContainer() -> ModelContainer {
        do {
            let store = try DiveStore(inMemory: true)
            DemoData.seed(into: store.container.mainContext)
            return store.container
        } catch {
            fatalError("Failed to create the in-memory demo container: \(error)")
        }
    }

    // MARK: - Scripted live session

    /// A `SessionManager` fed by a scripted depth profile and a fixed GPS point
    /// instead of the watch's sensors, so `Screen.live` can render a genuine live
    /// session in a simulator that has neither a submersion sensor nor a location
    /// fix (and would otherwise put a CoreLocation permission sheet over the shot).
    ///
    /// Everything downstream is the real thing: the samples run through the real
    /// `DiveDetector`, which decides when the dive starts and when it is confirmed,
    /// and `SessionRootView` renders whatever that produces.
    @MainActor
    static func makeDemoSessionManager(modelContext: ModelContext) -> SessionManager {
        SessionManager(
            sensors: SensorManager(
                provider: MockDepthProvider(
                    interval: 0.5,
                    profile: diveProfile,
                    // Fixed so the live screen's water-temp readout is the same in
                    // every capture (the default sine would vary pixel-to-pixel).
                    fixedTemperatureCelsius: demoTemperatureCelsius
                )
            ),
            location: FixedLocationProvider(),
            modelContext: modelContext
        )
    }

    /// Markers dropped once the demo session is live, so the live screen's counter
    /// and the Crown selector show a plausible dive rather than an empty one.
    static let demoMarkers: [MarkerKind] = [MarkerKind(.wildlife), MarkerKind(.photo)]

    /// Heart rate shown on the live screen. Fixed (not a random walk) so the shot
    /// is reproducible; ~78 bpm is a plausible working rate for a freediver.
    static let demoHeartRate = 78

    /// Water temperature shown on the live screen. Fixed for reproducibility; 24 °C
    /// is a plausible tropical dive temperature and matches the demo spot (Amed).
    static let demoTemperatureCelsius = 24.0

    /// Descend at ~0.4 m/s to 5.8 m, then hold there indefinitely.
    ///
    /// The hold matters: the script photographs the live screen after a fixed
    /// dwell, and a profile that ascended would put the shot at whatever depth the
    /// clock happened to land on — including 0 m, i.e. a surfaced screen. Holding
    /// makes the depth readout deterministic while the dive clock above it keeps
    /// running. 5.8 m sits just under the 6 m the shallow-depth entitlement can
    /// measure, so the number shown is one the app can genuinely produce.
    /// `MockDepthProvider` loops its profile, so the hold is long enough (2 h at
    /// 0.5 s per sample) that no capture ever sees it wrap.
    private static let diveProfile: [Double] = {
        let target = 5.8
        let descent = Array(stride(from: 0.2, through: target, by: 0.2))
        return descent + Array(repeating: target, count: 14_400)
    }()
}

/// A `LocationProviding` that reports one fixed, plausible dive-spot coordinate,
/// once a second. DEBUG/screenshot only.
///
/// Used instead of `CoreLocationProvider` for two reasons: the simulator would
/// raise a location-permission sheet over the screen being captured, and a real
/// fix drifts — the live screen's "±N m" GPS readout would differ shot to shot.
/// The coordinate is Amed, Bali — the same spot the seeded demo sessions use.
private struct FixedLocationProvider: LocationProviding {
    /// Matches `DemoData`'s Amed fixture.
    private static let point = GeoPoint(latitude: -8.3402, longitude: 115.6870, horizontalAccuracy: 4)

    func currentLocation() async -> GeoPoint? { Self.point }

    func locationUpdates() -> AsyncStream<GeoPoint> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(Self.point)
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Renders exactly one screen for capture, chosen by `--screenshot-screen`.
///
/// The screens are the app's real views with the app's real data — no
/// screenshot-only chrome, no stand-in copy (which would also mean new
/// untranslated strings rendering as English in seven locales). `.live` and
/// `.start` go through `WatchRootView` so the pager dots and layout are
/// pixel-identical to what a diver sees; the deeper screens are pushed straight
/// onto a `NavigationStack` because there is no UI automation on watchOS to tap
/// through the list for us.
struct WatchScreenshotRootView: View {
    let screen: WatchScreenshotMode.Screen

    @Environment(SessionCoordinator.self) private var session
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        content
            // Static screens are populated the instant they appear (their data is
            // seeded synchronously, and `.summary`/`.profile` fatalError rather than
            // render empty), so announce readiness on appear. `.live` is the
            // exception: while idle `WatchRootView` shows the Start page, so it must
            // announce readiness only after the session is actually active — done in
            // the task below, never here.
            .onAppear {
                if screen != .live { WatchScreenshotMode.publishScreenReady(screen) }
            }
            .task {
                guard screen == .live else { return }
                // Before the start, because `startScreenshotSession` only returns
                // once it has placed its markers a few seconds in.
                session.workout.setScreenshotHeartRate(WatchScreenshotMode.demoHeartRate)
                // The real start path minus HealthKit (see `startScreenshotSession`).
                // Announce ready ONLY on success: a thrown startSession() returns
                // false, no marker is written, and the script fails the capture
                // rather than photographing the idle Start screen.
                if await session.startScreenshotSession(markers: WatchScreenshotMode.demoMarkers) {
                    WatchScreenshotMode.publishScreenReady(.live)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .live, .start:
            // Idle → the Start page of the home pager; active → the live session.
            WatchRootView()
        case .sessions:
            WatchSessionListView()
        case .summary:
            // fatalError, not an empty branch: a seeding regression must fail the
            // capture, not emit a blank black PNG that passes every downstream check
            // and gets uploaded. DEBUG-only, so it costs users nothing.
            if let record = featured {
                NavigationStack {
                    // Same destination the session list pushes (title included), so
                    // this is the screen a diver actually reaches.
                    WatchSessionSummaryView(session: record.toDomain())
                        .navigationTitle(record.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                }
            } else {
                fatalError("Screenshot demo store has no featured session — DemoData.seed regressed")
            }
        case .profile:
            if let dive = featuredDive {
                NavigationStack {
                    WatchDiveProfileView(
                        dive: dive.dive,
                        number: dive.number,
                        markers: dive.session.markers,
                        heartRateSamples: dive.session.heartRateSamples,
                        temperatureSamples: dive.session.temperatureSamples
                    )
                }
            } else {
                fatalError("Screenshot demo store has no featured dive — DemoData.seed regressed")
            }
        }
    }

    /// The seeded session the summary/profile screens show.
    private var featured: SessionRecord? {
        DemoData.featuredSession(in: modelContext)
    }

    /// The featured session's first dive, with its 1-based number — what a diver
    /// would open from the summary's segment list.
    private var featuredDive: (session: DiveSession, dive: Dive, number: Int)? {
        guard let session = featured?.toDomain() else { return nil }
        let ordered = session.dives.sorted { $0.startTime < $1.startTime }
        guard let first = ordered.first else { return nil }
        return (session, first, 1)
    }
}
#endif
