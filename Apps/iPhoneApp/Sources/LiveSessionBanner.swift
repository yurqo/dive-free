import SwiftUI
import Domain

/// Prominent in-app indicator that a dive session is running on the paired Apple
/// Watch (#118) — the reliable, foreground counterpart to the Live Activity.
/// Renders nothing when no session is active. Ticks the elapsed time locally and,
/// once the Watch goes quiet (`staleThreshold`), grays the values and marks the
/// timer an estimate until a fresher snapshot arrives.
struct LiveSessionBanner: View {
    @Environment(LiveSessionMonitor.self) private var monitor

    var body: some View {
        if let snapshot = monitor.snapshot {
            // 1 s cadence drives both the elapsed tick and the stale/estimated toggle.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                banner(snapshot, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func banner(_ snapshot: LiveSessionSnapshot, now: Date) -> some View {
        let stale = snapshot.isStale(asOf: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9).opacity(stale ? 0.4 : 1)
                Text(stale ? "Reconnecting to Apple Watch…" : "Dive in progress on Apple Watch")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { monitor.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss session on iPhone")
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat("Elapsed", value: elapsed(from: snapshot.startTime, to: now))
                stat("Depth", value: DepthFormat.string(snapshot.depthMeters))
                stat("Dives", value: "\(snapshot.diveCount)")
                stat("Max", value: DepthFormat.string(snapshot.maxDepthMeters))
            }
            if stale {
                Text("Estimated time — updates when the Watch reconnects. Tap ✕ to stop showing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Graying the whole card past the stale threshold reads as "estimated".
        .foregroundStyle(stale ? .secondary : .primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.red.opacity(stale ? 0.15 : 0.35), lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 4)
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
