import Testing
@testable import Domain

struct ReviewMilestoneTests {
    private var ready: ReviewMilestone.Context {
        .init(completedDiveCount: 10, attempted: false, completedSession: true,
              activeRecording: false, foreground: true, presentingModal: false,
              restoring: false, demo: false)
    }

    @Test(arguments: [9, 10, 11, 50])
    func countsDives(_ count: Int) {
        var context = ready
        context.completedDiveCount = count
        #expect(context.eligible == (count >= 10))
    }

    @Test func suppressesInappropriateRequests() {
        for keyPath in [\ReviewMilestone.Context.attempted, \.activeRecording,
                        \.presentingModal, \.restoring, \.demo] {
            var context = ready
            context[keyPath: keyPath] = true
            #expect(!context.eligible)
        }
        for keyPath in [\ReviewMilestone.Context.completedSession, \.foreground] {
            var context = ready
            context[keyPath: keyPath] = false
            #expect(!context.eligible)
        }
    }

    @Test func cancelledContextCanBecomeEligibleAgain() {
        var context = ready
        context.presentingModal = true
        #expect(!context.eligible)
        context.presentingModal = false
        #expect(context.eligible)
        context.attempted = true
        context.completedDiveCount = 100
        #expect(!context.eligible)
    }
}
