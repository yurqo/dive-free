import SwiftUI
import WatchKit
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
    /// Last item the Crown landed on, so we buzz once per item change rather
    /// than once per detent (there are several detents per item).
    @State private var lastFocusedIndex = 0
    /// Digital Crown detents required to move one carousel item. Higher = slower,
    /// finer scrolling. Tunable in Settings; defaults slow since one-detent-per-
    /// item felt far too fast.
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 6

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 10) {
            switch session.state {
            case .idle:
                // The idle "Start" screen lives in StartView (a page of
                // WatchRootView's pager); this view only renders an active
                // session and its summary.
                EmptyView()

            case .active:
                activeView

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
        } message: {
            // Underwater the screen is water-locked, so the buttons can't be
            // tapped — on Ultra, press Action + side together again to confirm.
            Text("On Ultra, press the Action + side button together again to end.")
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
            // Per-detent haptic off; we buzz once per item change below instead.
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownPosition) { _, newValue in
            let index = Int((newValue / Double(crownStepsPerItem)).rounded())
            if index != lastFocusedIndex {
                lastFocusedIndex = index
                // Stronger than .click so item changes are felt underwater.
                WKInterfaceDevice.current().play(.notification)
            }
            session.focus(index)
        }
        // On the surface the touchscreen works, so a tap is an equivalent
        // confirm to the Action button — and the only fallback when no Action
        // button is assigned. Underwater (water-locked) stray touches are inert.
        .onTapGesture {
            if isActive, !session.isSubmerged { session.confirmFocused() }
        }
        .onChange(of: isActive) { _, active in
            if active { focusCrown() }
        }
        // WatchRootView mounts this view already-active, so onChange doesn't fire
        // on first appearance — focus the Crown here too, or it won't drive the
        // carousel at the start of a session.
        .onAppear {
            if isActive { focusCrown() }
        }
    }

    /// Re-sync the Crown's value with the coordinator's reset focus (so the first
    /// nudge doesn't jump) and focus it so rotation drives the carousel.
    private func focusCrown() {
        crownPosition = Double(session.focusedIndex * crownStepsPerItem)
        lastFocusedIndex = session.focusedIndex
        menuFocused = true
    }

    private var isActive: Bool {
        if case .active = session.state { return true }
        return false
    }

    // MARK: - Active session pieces

    private var activeView: some View {
        VStack(spacing: 3) {
            topBar
            Spacer(minLength: 2)
            centerpiece
            secondaryStats
            // Carousel + hint are a surface, non-AOD affordance (underwater the
            // screen is water-locked and the Action button drops a note).
            if !isLuminanceReduced && !session.isSubmerged {
                actionCarousel
                hint
            }
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Session elapsed time, top-left. The OS clock sits top-right, so we leave
    /// that corner clear and treat it as the "current time".
    private var topBar: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Label(
                    Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)),
                    systemImage: "stopwatch"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
        }
    }

    /// The focal readout: depth + dive time while submerged, the surface-recovery
    /// timer between dives, else current depth (or session time with no sensor).
    private var centerpiece: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if session.hasDepthSensor, let diveElapsed = session.currentDiveElapsed {
                VStack(spacing: 0) {
                    depthHeadline
                    Text(Duration.seconds(diveElapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.primary) : AnyShapeStyle(.teal))
                        .monospacedDigit()
                }
            } else if let surfaceInterval = session.surfaceInterval {
                VStack(spacing: 0) {
                    Text(Duration.seconds(surfaceInterval).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.primary) : AnyShapeStyle(surfaceReadinessColor(surfaceInterval)))
                        .monospacedDigit()
                    Text("Surface")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if session.hasDepthSensor {
                depthHeadline
            } else {
                Text(Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var depthHeadline: some View {
        Text(DepthFormat.string(session.currentDepthMeters))
            .font(.system(size: 46, weight: .bold, design: .rounded))
            .monospacedDigit()
    }

    /// Metrics around the focal readout: this-dive figures while submerged, the
    /// full set (with GPS + surface distance) at the surface.
    @ViewBuilder
    private var secondaryStats: some View {
        if session.isSubmerged {
            Text(submergedStatsText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            VStack(spacing: 1) {
                Text(surfaceStatsText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    gpsIcon
                    Text(distanceText(session.surfaceDistanceMeters))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var submergedStatsText: String {
        session.hasDepthSensor
            ? "max \(DepthFormat.value(session.currentDiveMaxDepth)) m · 📍\(session.currentDiveMarkerCount)"
            : "📍\(session.currentDiveMarkerCount)"
    }

    private var surfaceStatsText: String {
        session.hasDepthSensor
            ? "\(session.diveCount) dives · \(DepthFormat.value(session.maxDepthMeters)) m · 📍\(session.markerCount)"
            : "📍\(session.markerCount)"
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
    }

    /// Pill-shaped Crown action selector (marker kinds, then End).
    private var actionCarousel: some View {
        let item = session.menuItems[min(session.focusedIndex, max(session.menuItems.count - 1, 0))]
        let tint: Color = item == .end ? .red : .teal
        return HStack(spacing: 6) {
            if let emoji = item.emoji {
                Text(emoji).font(.title3)
            } else {
                Image(systemName: item.systemImage).font(.title3)
            }
            Text(item.title).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 8)
        .padding(.horizontal, 18)
        .background(Capsule().stroke(tint.opacity(0.7), lineWidth: 3))
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
        Text("Crown to choose · tap or button to confirm")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// Icon-only GPS status (location is core, so make signal loss obvious at a
    /// glance): teal when a fix is recent, yellow while acquiring the first one,
    /// red crossed-out when it's gone stale (e.g. wrist underwater). Re-evaluated
    /// each second so a lost signal shows even without a new value.
    private var gpsIcon: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let (symbol, color) = gpsIconState(now: context.date)
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }

    /// Seconds without a fix before GPS reads "lost" — generous enough to
    /// tolerate brief stroke-by-stroke gaps.
    private static let gpsStaleAfter: TimeInterval = 12

    private func gpsIconState(now: Date) -> (symbol: String, color: Color) {
        guard let lastFix = session.lastLocationFixAt else { return ("location", .yellow) }
        if now.timeIntervalSince(lastFix) <= Self.gpsStaleAfter { return ("location.fill", .teal) }
        return ("location.slash.fill", .red)
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
                    .multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    summaryRow("Total", Duration.seconds(completed.totalDuration).formatted(.time(pattern: .hourMinuteSecond)))
                    // Depth-derived rows only make sense on a watch with the sensor.
                    if session.hasDepthSensor {
                        summaryRow("Dives", "\(completed.diveCount)")
                        summaryRow("Max depth", DepthFormat.string(completed.maxDepthMeters))
                    }
                    if let average = completed.averageSurfaceInterval {
                        summaryRow("Avg surface", Duration.seconds(average).formatted(.time(pattern: .minuteSecond)))
                    }
                    if let location = completed.location {
                        summaryRow("Location", String(format: "%.4f, %.4f", location.latitude, location.longitude))
                    } else {
                        summaryRow("Location", "No GPS fix")
                    }
                }

                markerSummary(completed)

                syncStatus

                Button {
                    Task { await session.start() }
                } label: {
                    Label("Dive Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button("Done") { session.dismissSummary() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
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
                        .sorted { $0.key.id < $1.key.id }
                        .map { "\($0.key.emoji) \($0.value)" }
                        .joined(separator: "  ")
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
