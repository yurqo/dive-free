import Foundation
import Domain

/// Reads the durable flag immediately before requesting, including across scenes.
@MainActor struct ReviewMilestoneAttempt {
    static let key = "tenDiveReviewAttempted"
    var defaults: UserDefaults = .standard

    @discardableResult
    func request(after delay: Duration = .seconds(2),
                 context: @MainActor () -> ReviewMilestone.Context,
                 action: @MainActor () -> Void) async throws -> Bool {
        guard context().eligible, !defaults.bool(forKey: Self.key) else { return false }
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        guard context().eligible, !defaults.bool(forKey: Self.key) else { return false }
        defaults.set(true, forKey: Self.key)
        action()
        return true
    }
}
