import AppIntents
import Foundation

/// On Apple Watch Ultra, pressing the Action + side button together during a
/// workout fires the system pause/resume intents. DiveFree has no pause concept,
/// so both are repurposed as a **touch-free end gesture** (handy while
/// water-locked, when the screen is unresponsive): the first dual-click arms the
/// end-session confirmation, a second confirms and ends. Routing *both* intents
/// to the same handler makes it robust to the system's pause/resume alternation.

struct PauseDiveIntent: PauseWorkoutIntent {
    static let title: LocalizedStringResource = "Pause"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleEndGesture()
        return .result()
    }
}

struct ResumeDiveIntent: ResumeWorkoutIntent {
    static let title: LocalizedStringResource = "Resume"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSessionRegistry.shared.coordinator?.handleEndGesture()
        return .result()
    }
}
