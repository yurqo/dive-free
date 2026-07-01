import SwiftUI
import Domain

/// The in-progress Watch session as the top row of the Dives list (#118): live
/// elapsed / depth / dives / max, with a connection dot — **green** while the
/// Watch is connected and updating, **gray** (+ grayed text, "Reconnecting…")
/// when it's out of range. Elapsed keeps ticking locally even while disconnected.
/// Dismissed via the row's swipe action (no inline button).
struct LiveSessionRow: View {
    @Environment(LiveSessionMonitor.self) private var monitor

    var body: some View {
        if let snapshot = monitor.snapshot {
            // 1 s cadence drives the elapsed tick; disconnect is real-time via reachability.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(snapshot, disconnected: monitor.isDisconnected(asOf: context.date), now: context.date)
            }
        }
    }

    @ViewBuilder
    private func row(_ snapshot: LiveSessionSnapshot, disconnected: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(disconnected ? Color.secondary : Color.green)
                    .frame(width: 9, height: 9)
                Text(disconnected ? "Reconnecting to Apple Watch…" : "Dive in progress on Apple Watch")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat("Elapsed", value: elapsed(from: snapshot.startTime, to: now))
                stat("Depth", value: DepthFormat.string(snapshot.depthMeters))
                stat("Dives", value: "\(snapshot.diveCount)")
                stat("Max", value: DepthFormat.string(snapshot.maxDepthMeters))
            }
        }
        // Gray the whole row past disconnect — reads as an estimate.
        .foregroundStyle(disconnected ? .secondary : .primary)
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(start))).formatted(.time(pattern: .hourMinuteSecond))
    }
}
