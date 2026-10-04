import Foundation
import Testing
import Domain

@MainActor struct ReviewMilestoneAttemptTests {
    private var ready: ReviewMilestone.Context {
        .init(completedDiveCount: 10, attempted: false, completedSession: true,
              activeRecording: false, foreground: true, presentingModal: false,
              restoring: false, demo: false)
    }

    @Test func suppressedSystemDialogStillConsumesOneAttemptAcrossInstances() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let gate = ReviewMilestoneAttempt(defaults: defaults)
        #expect(try await gate.request(after: .zero, context: { ready }, action: { calls += 1 }))
        // The action returns no review outcome, just like StoreKit suppression.
        let nextLaunch = ReviewMilestoneAttempt(defaults: UserDefaults(suiteName: suite)!)
        #expect(try await !nextLaunch.request(after: .zero, context: { ready }, action: { calls += 1 }))
        #expect(calls == 1)
    }

    @Test func cancellationLeavesMilestoneEligible() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = ReviewMilestoneAttempt(defaults: defaults)
        let task = Task {
            try await gate.request(after: .seconds(60), context: { ready }, action: { Issue.record("Cancelled request fired") })
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(!defaults.bool(forKey: ReviewMilestoneAttempt.key))
        #expect(try await gate.request(after: .zero, context: { ready }, action: {}))
    }

    @Test func changedEligibilityDuringDelayDoesNotConsumeAttempt() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = ReviewMilestoneAttempt(defaults: defaults)
        var context = ready
        let task = Task {
            try await gate.request(after: .milliseconds(30), context: { context }, action: { Issue.record("Ineligible request fired") })
        }
        try await Task.sleep(for: .milliseconds(5))
        context.foreground = false
        #expect(try await !task.value)
        #expect(!defaults.bool(forKey: ReviewMilestoneAttempt.key))
    }
}
