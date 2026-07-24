import ProjectDescription
import Foundation

// MARK: - Constants

let bundlePrefix = "org.yurko.divefree"
// Read from the `TUIST_DEVELOPMENT_TEAM` env var. Tuist sandboxes manifest
// evaluation and only forwards `TUIST_`-prefixed variables (via `Environment`),
// so a bare `DEVELOPMENT_TEAM` from the shell never reaches `ProcessInfo` here.
// Empty by default → unsigned builds in CI/tests (which pass signing flags to
// xcodebuild directly).
let developmentTeam = Environment.developmentTeam.getString(default: "")
let iOSVersion = "18.0"
let watchVersion = "11.0"

/// Frameworks shared by both the iPhone and Watch apps build for both platforms.
let sharedDestinations: Destinations = [.iPhone, .appleWatch]
let sharedDeployment: DeploymentTargets = .multiplatform(iOS: iOSVersion, watchOS: watchVersion)

// MARK: - Module helper

/// Builds a framework target plus its matching unit-test target.
/// Sources live in `Packages/<name>/Sources`, tests in `Packages/<name>/Tests`.
func module(
    _ name: String,
    dependencies: [TargetDependency] = [],
    destinations: Destinations = sharedDestinations,
    deployment: DeploymentTargets = sharedDeployment,
    resources: ResourceFileElements? = nil
) -> [Target] {
    [
        .target(
            name: name,
            destinations: destinations,
            product: .framework,
            bundleId: "\(bundlePrefix).\(name.lowercased())",
            deploymentTargets: deployment,
            sources: ["Packages/\(name)/Sources/**"],
            resources: resources,
            dependencies: dependencies
        ),
        .target(
            name: "\(name)Tests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "\(bundlePrefix).\(name.lowercased()).tests",
            deploymentTargets: .iOS(iOSVersion),
            sources: ["Packages/\(name)/Tests/**"],
            dependencies: [.target(name: name)]
        ),
    ]
}

// MARK: - Apps

let watchApp = Target.target(
    name: "DiveFreeWatch",
    destinations: [.appleWatch],
    product: .app,
    bundleId: "\(bundlePrefix).watchkitapp",
    deploymentTargets: .watchOS(watchVersion),
    infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Dive Free",
        // Bind the bundle version to the build settings so MARKETING_VERSION /
        // CURRENT_PROJECT_VERSION actually take effect (the extendingDefault
        // template otherwise pins CFBundleShortVersionString to a literal "1.0").
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "WKApplication": true,
        "WKCompanionAppBundleIdentifier": "\(bundlePrefix)",
        "NSMotionUsageDescription": "Used to measure depth and movement while diving.",
        "NSHealthShareUsageDescription": "Used to read workout and health data for your dive sessions.",
        "NSHealthUpdateUsageDescription": "Used to save your dive sessions as workouts.",
        "NSLocationWhenInUseUsageDescription": "Used to record where your dives happen.",
        "NSMicrophoneUsageDescription": "Used to record voice notes about a dive while you're at the surface.",
        // Keep the app alive in the background for the HKWorkoutSession, and
        // receive water-submersion depth (the latter also registers the app
        // under Settings → General → Auto-Launch → When Submerged so it can
        // launch automatically on a dive). Depth itself requires the
        // submerged-shallow-depth-and-pressure entitlement (see entitlements).
        "WKBackgroundModes": ["workout-processing", "underwater-depth"],
    ]),
    sources: ["Apps/WatchApp/Sources/**"],
    resources: ["Apps/WatchApp/Resources/**"],
    entitlements: .file(path: "Apps/WatchApp/DiveFreeWatch.entitlements"),
    dependencies: [
        // Explicitly link AppIntents so the metadata processor extracts our
        // App Intents (the Action-button workout + marker intents). Without it
        // extraction is skipped and the intents never register with the system.
        .sdk(name: "AppIntents", type: .framework),
        // The session summary/list maps use MapKit's SwiftUI Map on watchOS.
        .sdk(name: "MapKit", type: .framework),
        .target(name: "Domain"),
        .target(name: "Persistence"),
        .target(name: "Sensors"),
        .target(name: "Session"),
        .target(name: "Sync"),
    ]
)

let iphoneApp = Target.target(
    name: "DiveFree",
    // Universal (iPhone + iPad). Sessions are captured on Apple Watch and synced to
    // the iPhone over WatchConnectivity; the iPad gets the dive log via iCloud
    // (CloudKit) sync (#168), so it shows the same data without a paired watch (#170).
    destinations: [.iPhone, .iPad],
    product: .app,
    bundleId: "\(bundlePrefix)",
    deploymentTargets: .iOS(iOSVersion),
    infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Dive Free",
        // Bind the bundle version to the build settings (see the watch target).
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "UILaunchScreen": [:],
        "LSApplicationCategoryType": "public.app-category.travel",
        // App uses only standard (exempt) HTTPS encryption — auto-clears the
        // TestFlight/App Store export-compliance prompt.
        "ITSAppUsesNonExemptEncryption": false,
        // Receive CloudKit's silent pushes so SwiftData imports changes from the
        // user's other devices (#168). NSPersistentCloudKitContainer requires this;
        // without it CloudKit logs "requires the 'remote-notification' background
        // mode" and sync never completes.
        "UIBackgroundModes": ["remote-notification"],
        // Reflect an in-progress Watch session on the phone as a Live Activity (#118).
        "NSSupportsLiveActivities": true,
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "NSHealthShareUsageDescription": "Used to read your dive workouts.",
        "NSHealthUpdateUsageDescription": "Used to store your dive sessions.",
        "NSLocationWhenInUseUsageDescription": "Used to record the location of your dive spots.",
        "NSPhotoLibraryUsageDescription": "Used to attach photos to your dive spots, including shots imported from underwater cameras.",
        "NSPhotoLibraryAddUsageDescription": "Used to save dive spot photos to your library.",
        "NSCameraUsageDescription": "Used to take photos at your dive spots.",
        "LSApplicationQueriesSchemes": ["strava"],
        "CFBundleURLTypes": [
            [
                "CFBundleURLName": "org.yurko.divefree.strava-callback",
                "CFBundleURLSchemes": ["divefree"],
            ]
        ],
    ]),
    sources: ["Apps/iPhoneApp/Sources/**"],
    resources: ["Apps/iPhoneApp/Resources/**"],
    entitlements: .file(path: "Apps/iPhoneApp/DiveFree.entitlements"),
    dependencies: [
        .target(name: "Domain"),
        .target(name: "Persistence"),
        .target(name: "Sync"),
        .target(name: "Strava"),
        // For LocationName (reverse-geocoding) used to backfill session area names.
        .target(name: "Sensors"),
        // Embeds the watchOS app inside the iPhone app (companion pairing).
        .target(name: "DiveFreeWatch"),
        // Embeds the widget extension hosting the in-progress-dive Live Activity (#118).
        .target(name: "DiveFreeWidgets"),
    ]
)

// The widget extension: hosts the in-progress-dive Live Activity (#118). Shares
// the ActivityAttributes + LiveSessionSnapshot with the app via Domain, so the
// app's `Activity<DiveActivityAttributes>` and the widget's `ActivityConfiguration`
// resolve to the same type.
let widgetExtension = Target.target(
    name: "DiveFreeWidgets",
    destinations: [.iPhone, .iPad],
    product: .appExtension,
    bundleId: "\(bundlePrefix).widgets",
    deploymentTargets: .iOS(iOSVersion),
    infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Dive Free",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSExtension": [
            "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
        ],
    ]),
    sources: ["Apps/Widgets/Sources/**"],
    resources: ["Apps/Widgets/Resources/**"],
    dependencies: [
        .target(name: "Domain"),
    ]
)

// The screenshot-capture UI-test target (#screenshot-automation). Standalone —
// NOT part of the DiveFree app scheme's test action, so CI's `xcodebuild build
// -scheme DiveFree` never runs it; Tuist's auto-generated `ScreenshotTests`
// scheme drives it via `Scripts/screenshots.sh`. Hosts on the iPhone app and
// launches it with `--screenshot-demo` to boot the seeded in-memory store.
let screenshotTests = Target.target(
    name: "ScreenshotTests",
    destinations: .iOS,
    product: .uiTests,
    bundleId: "\(bundlePrefix).screenshottests",
    deploymentTargets: .iOS(iOSVersion),
    infoPlist: .default,
    sources: ["Apps/iPhoneApp/ScreenshotTests/**"],
    // The iPhone app target's `name` is "DiveFree" (the `iphoneApp` variable);
    // Tuist resolves target dependencies by that name string, so it hosts on
    // and launches the iPhone app.
    dependencies: [.target(name: "DiveFree")]
)

// MARK: - Project

let project = Project(
    name: "DiveFree",
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        // Auto-extract localizable strings from source (Text/Label literals,
        // String(localized:), LocalizedStringResource, App Intents) into each
        // target's Localizable.xcstrings at build time, so adding a translation
        // is a content edit — no code change. Emits *.stringsdata per module.
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        // The git release tag (vX.Y.Z) is the source of truth for the version: the
        // TestFlight workflow auto-increments the patch from the latest tag on each
        // dispatch. MARKETING_VERSION below is only a *floor / override* — set it
        // ABOVE the latest tag to force a version jump (e.g. a new minor) for one
        // release; otherwise keep it == the latest released version so the auto
        // patch-bump continues. The build number is DECOUPLED from the marketing
        // version — CI sets it to the git commit count, which stays monotonic
        // across minor bumps (a 1.0.x→1.1.0 jump would otherwise reset build=patch
        // backwards and TestFlight would reject it). Both targets bind their
        // Info.plist to these so the values reach the bundle.
        "MARKETING_VERSION": "1.3.0",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_STYLE": "Automatic",
    ]),
    targets: [iphoneApp, watchApp, widgetExtension, screenshotTests]
        + module("Domain", resources: ["Packages/Domain/Resources/**"])
        + module("Persistence", dependencies: [.target(name: "Domain")])
        + module(
            "Sensors",
            dependencies: [.target(name: "Domain")],
            resources: ["Packages/Sensors/Resources/**"]
        )
        + module("Sync", dependencies: [.target(name: "Domain")])
        + module(
            "Session",
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Sensors"),
                .target(name: "Persistence"),
            ]
        )
        + module(
            "Strava",
            dependencies: [.target(name: "Domain")],
            destinations: .iOS,
            deployment: .iOS(iOSVersion),
            resources: ["Packages/Strava/Resources/**"]
        )
)
