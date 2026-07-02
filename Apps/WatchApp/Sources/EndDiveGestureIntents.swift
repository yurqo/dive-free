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
/// The system alternates pause → resume on successive presses, which tracks the
/// manual-dive start → stop toggle, so the captions read "Start Dive" (pause)
/// and "Stop Dive" (resume) to match what each press actually does.

struct PauseDiveIntent: PauseWorkoutIntent {
    static let title: LocalizedStringResource = "Start Dive"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}

struct ResumeDiveIntent: ResumeWorkoutIntent {
    static let title: LocalizedStringResource = "Stop Dive"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleActionSide()
        return .result()
    }
}
