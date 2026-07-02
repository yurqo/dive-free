import AppIntents
import Foundation

/// Holds a weak reference to the currently running `SessionCoordinator` so the
/// Action-button intent can route into the already-running live session instead
/// of spinning up a separate app context. The coordinator registers itself on
/// init; the app keeps it alive for the process lifetime.
@MainActor
final class LiveSessionRegistry {
    static let shared = LiveSessionRegistry()
    weak var coordinator: SessionCoordinator?
    /// Set by `BeginDiveWorkoutIntent` when the Action button fires before the
    /// coordinator exists (cold launch). `SessionRootView` consumes it once the
    /// scene is active and starts the session.
    var pendingStart = false
    private init() {}
}

/// App Intent backing the Apple Watch Ultra Action button. The diver assigns it
/// once in **Settings → Action Button**. A press is context-sensitive:
/// underwater it drops the selected marker (the touchscreen is water-locked); on
/// the surface it confirms the selected Crown-menu item.
struct AddMarkerIntent: AppIntent {
    static let title: LocalizedStringResource = "Confirm Selection"
    static let description = IntentDescription(
        "Drops the selected marker while underwater, or confirms the selected menu item on the surface."
    )

    /// Route the press into the running session in the background — do not
    /// foreground a separate intent UI over the live workout screen.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionButton()
        return .result()
    }
}

/// Surfaces `AddMarkerIntent` to the system so it can be assigned to the Action
/// button and invoked by voice.
struct DiveFreeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMarkerIntent(),
            phrases: ["Mark a moment in \(.applicationName)"],
            shortTitle: "Mark Moment",
            systemImageName: "mappin"
        )
    }
}
