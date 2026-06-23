import AppIntents
import Foundation

/// On Apple Watch Ultra, pressing the Action + side button together during a
/// workout fires the system pause/resume intents. DiveFree has no pause concept,
/// so both are repurposed as the **Action + side gesture** (handy while
/// water-locked): in a live session it toggles a manual dive (start/stop), or
/// confirms the end when the end dialog is armed; on the summary it's Done.
/// Routing *both* intents to the same handler makes it robust to the system's
/// pause/resume alternation.

struct PauseDiveIntent: PauseWorkoutIntent {
    static let title: LocalizedStringResource = "Pause"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}

struct ResumeDiveIntent: ResumeWorkoutIntent {
    static let title: LocalizedStringResource = "Resume"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}
