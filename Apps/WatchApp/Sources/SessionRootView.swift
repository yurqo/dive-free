import SwiftUI
import Domain
import Persistence
import Session

/// Watch home: start a session, then watch live depth until you end it.
///
/// During an active session the diver navigates a single-action carousel with
/// the Digital Crown — fully touch-free, since Water Lock disables the
/// touchscreen. The Action button (see `AddMarkerIntent`) confirms: it drops a
/// `.note` while submerged and confirms the focused action on the surface.
struct SessionRootView: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var crownPosition: Double = 0
    @FocusState private var menuFocused: Bool
    @State private var showingSettings = false
    /// Digital Crown detents required to move one carousel item. Higher = slower,
    /// finer scrolling. Tunable in Settings; defaults slow since one-detent-per-
    /// item felt far too fast.
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 3

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 10) {
            switch session.state {
            case .idle:
                ScrollView {
                    VStack(spacing: 10) {
                        Image(systemName: "water.waves")
                            .font(.largeTitle)
                            .foregroundStyle(.teal)
                        Text("Freedive")
                            .font(.headline)
                        Button(session.startError == nil ? "Start Session" : "Try Again") {
                            Task { await session.start() }
                        }
                        .buttonStyle(.borderedProminent)
                        if let startError = session.startError {
                            Text(startError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

            case .active:
                stats
                // Crown navigation is inert in Always On Display, so hide the
                // carousel to cut burn-in (mirrors the old inline controls).
                if !isLuminanceReduced {
                    actionCarousel
                    hint
                }

            case .summary(let completed):
                summaryView(completed)
            }
        }
        .padding()
        .confirmationDialog(
            "End session?",
            isPresented: $session.pendingEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive) { session.confirmEnd() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettings) {
            WatchSettingsView()
        }
        .focusable(isActive)
        .focused($menuFocused)
        .digitalCrownRotation(
            $crownPosition,
            from: 0,
            // Span `crownStepsPerItem` detents per item so each item takes more
            // rotation — the bigger the multiplier, the finer/slower the scroll.
            through: Double(max(session.menuItems.count - 1, 0) * crownStepsPerItem),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownPosition) { _, newValue in
            session.focus(Int((newValue / Double(crownStepsPerItem)).rounded()))
        }
        // On the surface the touchscreen works, so a tap is an equivalent
        // confirm to the Action button — and the only fallback when no Action
        // button is assigned. Underwater (water-locked) stray touches are inert.
        .onTapGesture {
            if isActive, !session.isSubmerged { session.confirmFocused() }
        }
        .onChange(of: isActive) { _, active in
            if active {
                // Re-sync the Crown's value with the coordinator's reset focus
                // so the first nudge of a new session doesn't jump.
                crownPosition = Double(session.focusedIndex * crownStepsPerItem)
                menuFocused = true
            }
        }
    }

    private var isActive: Bool {
        if case .active = session.state { return true }
        return false
    }

    // MARK: - Active session pieces

    private var stats: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f m", session.currentDepthMeters))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            // Refresh once per second for the timer; while submerged show the
            // active-dive duration (highlighted), otherwise the session elapsed
            // time. TimelineView keeps redrawing in Always On Display at a
            // reduced cadence.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let diveElapsed = session.currentDiveElapsed {
                    Text(Duration.seconds(diveElapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.primary) : AnyShapeStyle(.teal))
                        .monospacedDigit()
                    // Measures time below the surface threshold, which begins
                    // before a descent qualifies as a counted dive — hence
                    // "Submerged" rather than "Dive Time".
                    Text("Submerged")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let surfaceInterval = session.surfaceInterval {
                    // Recovery timer between dives: counts up from the moment the
                    // diver surfaces and resets on the next descent.
                    Text(Duration.seconds(surfaceInterval).formatted(.time(pattern: .minuteSecond)))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            isLuminanceReduced
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(surfaceReadinessColor(surfaceInterval))
                        )
                        .monospacedDigit()
                    Text("Surface")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("\(session.diveCount) dives · \(String(format: "%.1f", session.maxDepthMeters)) m max · \(session.markerCount) markers")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var actionCarousel: some View {
        let item = session.menuItems[min(session.focusedIndex, max(session.menuItems.count - 1, 0))]
        let tint: Color = item == .end ? .red : .teal
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.6), lineWidth: 3)
            VStack(spacing: 2) {
                Image(systemName: item.systemImage)
                    .font(.title3)
                Text(item.title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(tint)
        }
        .frame(width: 84, height: 84)
    }

    /// Coarse pacing cue for the surface-interval timer: warm while recovery is
    /// fresh, cooling to green as the interval builds. A visual nudge only — not
    /// safety guidance.
    private func surfaceReadinessColor(_ interval: TimeInterval) -> Color {
        switch interval {
        case ..<30: .red
        case ..<60: .orange
        default: .green
        }
    }

    private var hint: some View {
        Text(session.isSubmerged ? "Action button → marker" : "Crown to choose · tap or button to confirm")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Post-session summary

    private func summaryView(_ completed: DiveSession) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                Text("Session Complete")
                    .font(.headline)

                VStack(spacing: 4) {
                    summaryRow("Total", Duration.seconds(completed.totalDuration).formatted(.time(pattern: .hourMinuteSecond)))
                    summaryRow("Dives", "\(completed.diveCount)")
                    summaryRow("Max depth", String(format: "%.1f m", completed.maxDepthMeters))
                    if let average = completed.averageSurfaceInterval {
                        summaryRow("Avg surface", Duration.seconds(average).formatted(.time(pattern: .minuteSecond)))
                    }
                }

                markerSummary(completed)

                syncStatus

                Button("Done") { session.dismissSummary() }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
            }
        }
    }

    /// Background-safe transfer status for the just-finished session: still in
    /// the WatchConnectivity queue, or confirmed delivered to the iPhone.
    private var syncStatus: some View {
        let pending = session.pendingSyncCount > 0
        return Label(
            pending ? "Syncing to iPhone…" : "Synced to iPhone",
            systemImage: pending ? "arrow.triangle.2.circlepath" : "checkmark.icloud"
        )
        .font(.caption2)
        .foregroundStyle(pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.teal))
        .symbolVariant(pending ? .none : .fill)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func markerSummary(_ completed: DiveSession) -> some View {
        let counts = completed.markerCountsByKind
        if counts.isEmpty {
            Text("No markers")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 2) {
                Text("\(completed.markers.count) markers")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(
                    counts
                        .sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.value) \($0.key.rawValue)" }
                        .joined(separator: " · ")
                )
                .font(.caption2)
                .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    SessionRootView()
        .environment(
            SessionCoordinator(
                modelContext: try! DiveStore(inMemory: true).container.mainContext
            )
        )
}
