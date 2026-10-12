import SwiftUI
import SwiftData
import StoreKit
import Domain
import Persistence

/// Shared with restore so changes to the logbook never prompt during an import.
@MainActor @Observable final class LogbookActivity {
    var restoring = false
}

private struct ReviewMilestoneModifier: ViewModifier {
    let completedSession: Bool
    let presentingModal: Bool
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LiveSessionMonitor.self) private var liveSession
    @Environment(LogbookActivity.self) private var activity
    @Query private var sessions: [SessionRecord]
    @AppStorage(ReviewMilestoneAttempt.key) private var attempted = false
    @State private var dismissed = false
    @State private var interaction = 0

    private var context: ReviewMilestone.Context {
        // IDs also guard against duplicate CloudKit records during reconciliation.
        let diveIDs = Set(sessions.filter { $0.endTime != nil }.flatMap { ($0.dives ?? []).map(\.id) })
        return .init(completedDiveCount: diveIDs.count, attempted: attempted,
                     completedSession: completedSession, activeRecording: liveSession.snapshot != nil,
                     foreground: scenePhase == .active, presentingModal: presentingModal || dismissed,
                     restoring: activity.restoring,
                     demo: ProcessInfo.processInfo.arguments.contains("--screenshot-demo"))
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if context.eligible {
                    HStack {
                        Text("Congratulations on your 10th dive!")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { dismissed = true } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss")
                    }
                    .padding()
                    .background(.regularMaterial)
                    .accessibilityElement(children: .contain)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in interaction += 1 })
            .task(id: Schedule(context: context, interaction: interaction)) {
                guard context.eligible else { return }
                do {
                    if try await ReviewMilestoneAttempt().request(context: { context }, action: { requestReview() }) {
                        attempted = true
                    }
                } catch { /* A disappearing/inactive/occupied view cancels safely. */ }
            }
    }

    private struct Schedule: Equatable {
        let context: ReviewMilestone.Context
        let interaction: Int
    }
}

extension View {
    func tenDiveReviewMilestone(completedSession: Bool, presentingModal: Bool) -> some View {
        modifier(ReviewMilestoneModifier(completedSession: completedSession, presentingModal: presentingModal))
    }
}
