import Foundation

/// A review milestone counts completed dives, never recording sessions.
public enum ReviewMilestone {
    public static let requiredDiveCount = 10

    public struct Context: Sendable, Equatable {
        public var completedDiveCount: Int
        public var attempted: Bool
        public var completedSession: Bool
        public var activeRecording: Bool
        public var foreground: Bool
        public var presentingModal: Bool
        public var restoring: Bool
        public var demo: Bool

        public init(completedDiveCount: Int, attempted: Bool, completedSession: Bool,
                    activeRecording: Bool, foreground: Bool, presentingModal: Bool,
                    restoring: Bool, demo: Bool) {
            self.completedDiveCount = completedDiveCount
            self.attempted = attempted
            self.completedSession = completedSession
            self.activeRecording = activeRecording
            self.foreground = foreground
            self.presentingModal = presentingModal
            self.restoring = restoring
            self.demo = demo
        }

        public var eligible: Bool {
            completedDiveCount >= requiredDiveCount && !attempted && completedSession
                && !activeRecording && foreground && !presentingModal && !restoring && !demo
        }
    }
}
