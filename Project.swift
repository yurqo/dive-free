import ProjectDescription

// MARK: - Constants

let bundlePrefix = "net.perekupko.divefree"
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
        "WKApplication": true,
        "WKCompanionAppBundleIdentifier": "\(bundlePrefix)",
        "NSMotionUsageDescription": "Used to measure depth and movement while diving.",
        "NSHealthShareUsageDescription": "Used to read workout and health data for your dive sessions.",
        "NSHealthUpdateUsageDescription": "Used to save your dive sessions as workouts.",
        "NSLocationWhenInUseUsageDescription": "Used to record where your dives happen.",
        // Keeps the app alive in the background for the duration of the HKWorkoutSession.
        "WKBackgroundModes": ["workout-processing"],
    ]),
    sources: ["Apps/WatchApp/Sources/**"],
    resources: ["Apps/WatchApp/Resources/**"],
    entitlements: .file(path: "Apps/WatchApp/DiveFreeWatch.entitlements"),
    dependencies: [
        .target(name: "Domain"),
        .target(name: "Persistence"),
        .target(name: "Sensors"),
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
        "UILaunchScreen": [:],
        "NSHealthShareUsageDescription": "Used to read your dive workouts.",
        "NSHealthUpdateUsageDescription": "Used to store your dive sessions.",
        "NSLocationWhenInUseUsageDescription": "Used to show where your dives happen on the map.",
    ]),
    sources: ["Apps/iPhoneApp/Sources/**"],
    resources: ["Apps/iPhoneApp/Resources/**"],
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
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
    ]),
    targets: [iphoneApp, watchApp]
        + module("Domain")
        + module("Persistence", dependencies: [.target(name: "Domain")])
        + module("Sensors", dependencies: [.target(name: "Domain")])
        + module("Sync", dependencies: [.target(name: "Domain")])
        + module(
            "Strava",
            dependencies: [.target(name: "Domain")],
            destinations: .iOS,
            deployment: .iOS(iOSVersion)
        )
)
