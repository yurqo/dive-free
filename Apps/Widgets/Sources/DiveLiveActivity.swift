import ActivityKit
import WidgetKit
import SwiftUI
import Domain

/// Live Activity for an in-progress dive session (#118): Lock Screen banner plus
/// Dynamic Island presentations. Driven by `DiveActivityAttributes.ContentState`
/// (a `LiveSessionSnapshot`) pushed from the phone. `context.isStale` (past the
/// snapshot's `staleDate`) grays the values and marks the timer an estimate while
/// the Watch is out of range; the elapsed timer keeps ticking locally regardless.
struct DiveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DiveActivityAttributes.self) { context in
            LockScreenView(snapshot: context.state.snapshot, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            let dim = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(DepthFormat.string(snapshot.depthMeters), systemImage: "water.waves")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(dim ? .secondary : .primary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(snapshot.startTime, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 68)
                        .foregroundStyle(dim ? .secondary : .primary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(snapshot.diveCount) dives · max \(DepthFormat.string(snapshot.maxDepthMeters))")
                        Spacer()
                        Text(dim ? "estimated" : "on Apple Watch")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "water.waves").foregroundStyle(.cyan)
            } compactTrailing: {
                Text(snapshot.startTime, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(dim ? .secondary : .primary)
            } minimal: {
                Image(systemName: "water.waves").foregroundStyle(.cyan)
            }
        }
    }
}

/// Lock Screen / notification-banner presentation of the live session.
private struct LockScreenView: View {
    let snapshot: LiveSessionSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8).opacity(isStale ? 0.4 : 1)
                Text(isStale ? "Reconnecting to Apple Watch…" : "Dive in progress on Apple Watch")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "applewatch").foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                metric("Elapsed") { Text(snapshot.startTime, style: .timer).monospacedDigit() }
                metric("Depth") { Text(DepthFormat.string(snapshot.depthMeters)) }
                metric("Dives") { Text("\(snapshot.diveCount)") }
                metric("Max") { Text(DepthFormat.string(snapshot.maxDepthMeters)) }
            }
        }
        .foregroundStyle(isStale ? .secondary : .primary)
    }

    private func metric(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            value().font(.callout.weight(.semibold))
        }
    }
}
