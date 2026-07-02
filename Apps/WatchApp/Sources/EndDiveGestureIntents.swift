import AppIntents
import Foundation

/// On Apple Watch Ultra, pressing the Action + side button together during a
/// workout fires the system pause/resume intents. DiveFree has no pause concept,
/// so both are repurposed as the **Action + side gesture** (handy while
/// water-locked): in a live session it toggles a manual dive (start/stop), or
/// confirms the end when the end dialog is armed; on the summary it's Done.
/// Routing *both* intents to the same handler makes it robust to the system's
/// pause/resume alternation.
///
/// Because DiveFree never actually pauses the workout, watchOS stays in the
/// "running" state and only ever fires the **pause** intent (never resume) — so
/// both carry the same caption, "Toggle Dive", to label the single gesture
/// consistently.

struct PauseDiveIntent: PauseWorkoutIntent {
    static let title: LocalizedStringResource = "Toggle Dive"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}

struct ResumeDiveIntent: ResumeWorkoutIntent {
    static let title: LocalizedStringResource = "Toggle Dive"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}
