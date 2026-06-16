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
    deployment: DeploymentTargets = sharedDeployment
) -> [Target] {
    [
        .target(
            name: name,
            destinations: destinations,
            product: .framework,
            bundleId: "\(bundlePrefix).\(name.lowercased())",
            deploymentTargets: deployment,
            sources: ["Packages/\(name)/Sources/**"],
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
    destinations: .iOS,
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
        // Strava client secret, substituted from the STRAVA_CLIENT_SECRET build
        // setting at archive time (empty in local/CI test builds). Read via
        // StravaConfig.clientSecret.
        "STRAVA_CLIENT_SECRET": "$(STRAVA_CLIENT_SECRET)",
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
        // Embeds the watchOS app inside the iPhone app (companion pairing).
        .target(name: "DiveFreeWatch"),
    ]
)

// MARK: - Project

let project = Project(
    name: "DiveFree",
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        // Marketing version is the single source of truth for the app version —
        // the TestFlight workflow reads it from here and sets the build number to
        // the patch component, so TestFlight shows e.g. 1.0.11 (11). Bump the
        // patch to ship a new release. Both targets bind their Info.plist to
        // these (below) so the values actually reach the bundle (a literal
        // Info.plist default would silently win and pin the version at "1.0").
        "MARKETING_VERSION": "1.0.12",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_STYLE": "Automatic",
        // Default empty; the TestFlight workflow overrides this at archive time
        // with the STRAVA_CLIENT_SECRET repo secret. Keeps the secret out of git.
        "STRAVA_CLIENT_SECRET": "",
    ]),
    targets: [iphoneApp, watchApp]
        + module("Domain")
        + module("Persistence", dependencies: [.target(name: "Domain")])
        + module("Sensors", dependencies: [.target(name: "Domain")])
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
            deployment: .iOS(iOSVersion)
        )
)
