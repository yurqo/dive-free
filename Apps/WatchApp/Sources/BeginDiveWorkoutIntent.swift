import AppIntents
import Foundation

/// The single workout style DiveFree offers to the Action button's **Workout**
/// action. The underlying `HKWorkoutSession` is `.swimming`; this enum only
/// labels the picker entry (we intentionally support one style — freediving).
enum DiveWorkoutStyle: String, AppEnum, CustomStringConvertible {
    case freedive

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout"
    static let caseDisplayRepresentations: [DiveWorkoutStyle: DisplayRepresentation] = [
        .freedive: "Freedive"
    ]

    var description: String { rawValue.capitalized }
}

/// Registers DiveFree as a workout app so it appears under **Settings → Action
/// Button → Workout → App** on Apple Watch Ultra. The first press starts a
/// freedive session; the in-workout press is wired to `AddMarkerIntent` via
/// `actionButtonIntent`, so a press while submerged drops a marker.
///
/// Requires `workout-processing` in `WKBackgroundModes` (already set) and
/// `workoutStyle` to be an `@Parameter`.
struct BeginDiveWorkoutIntent: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Start a Freedive"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(workoutStyle)")
    }

    @Parameter(title: "Workout")
    var workoutStyle: DiveWorkoutStyle

    static var openAppWhenRun: Bool { true }

    static var suggestedWorkouts: [BeginDiveWorkoutIntent] {
        [BeginDiveWorkoutIntent(style: .freedive)]
    }

    init() {
        self.workoutStyle = .freedive
    }

    init(style: DiveWorkoutStyle) {
        self.workoutStyle = style
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let registry = LiveSessionRegistry.shared
        if let coordinator = registry.coordinator {
            // App already running: start now (a no-op if a session is active).
            await coordinator.start()
        } else {
            // Cold launch: the coordinator doesn't exist yet. Flag the start so
            // SessionRootView begins the session once the scene is active.
            registry.pendingStart = true
        }
        // Route the next, in-workout Action-button press to drop a marker.
        return .result(actionButtonIntent: AddMarkerIntent())
    }
}
