import SwiftUI
import WatchKit
import Domain
import Persistence
import Session

/// Watch live-session screen: a big depth readout that fills the display while
/// you dive, driven touch-free by the Digital Crown + Action button (the
/// touchscreen is water-locked underwater). When the session ends it shows the
/// summary with a Done / Dive-again toolbar.
struct SessionRootView: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var crownPosition: Double = 0
    @FocusState private var menuFocused: Bool
    /// Last item the Crown landed on, so we buzz once per item change rather
    /// than once per detent (there are several detents per item).
    @State private var lastFocusedIndex = 0
    /// Digital Crown detents required to move one carousel item. Higher = slower,
    /// finer scrolling. Tunable in Settings.
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 6

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                // The idle pager (Start · Sessions · Settings) lives in
                // WatchRootView; this view only renders an active session and
                // its summary.
                EmptyView()

            case .active:
                activeView

            case .summary(let completed):
                summaryView(completed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Re-sync the Crown's value with the coordinator's focus (so the first
    /// nudge doesn't jump) and focus it so rotation drives the carousel.
    private func focusCrown() {
        crownPosition = Double(session.focusedIndex * crownStepsPerItem)
        lastFocusedIndex = session.focusedIndex
        menuFocused = true
    }

    // MARK: - Active session

    /// Layout: the session time and GPS ride in the top bar beside the OS clock
    /// (via the navigation toolbar, the same way the summary's ↻ / ✓ buttons do);
    /// the big depth readout fills the middle; the session counters sit right above
    /// the bottom pill.
    private var activeView: some View {
        @Bindable var session = session
        // A NavigationStack purely so the top bar lines the session time / GPS up
        // with the OS clock natively — no manual safe-area math. There's no
        // ScrollView inside, so it doesn't claim the Crown from the carousel.
        return NavigationStack {
            VStack(spacing: 3) {
                // The centerpiece fills everything between the top bar and the
                // bottom pill so they never move when the mode or content changes.
                centerpiece
                statsLine
                // The pill is a non-AOD affordance; the Crown drives it both at the
                // surface and underwater, and the Action button confirms it.
                if !isLuminanceReduced {
                    actionPill
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            // Pull the content up under the nav bar a little so the big time isn't
            // pushed far below the clock — reduces the gap above it and gives the
            // number more height. (Stays clear of the toolbar row.)
            .padding(.top, -12)
            // A bit more bottom margin than the sides so the pill clears the
            // display's rounded bottom corners, which otherwise clip it.
            .padding(.bottom, 16)
            // Extend under the bottom safe area; the top is handled by the nav bar.
            .ignoresSafeArea(.container, edges: .bottom)
            // GPS (leading) + session time (trailing) flank the OS clock.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { gpsInfo }
                ToolbarItem(placement: .topBarTrailing) { sessionTimeLabel }
            }
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
            .focusable()
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
            .onChange(of: session.focusedIndex) { _, newIndex in
                // Re-sync the Crown when focus changes externally (e.g. after a
                // voice note ends) — but not when the Crown itself drove it.
                let crownIndex = Int((crownPosition / Double(crownStepsPerItem)).rounded())
                if crownIndex != newIndex {
                    crownPosition = Double(newIndex * crownStepsPerItem)
                    lastFocusedIndex = newIndex
                }
            }
            // A tap confirms the focused item — the touch fallback when no Action
            // button is assigned, and how the simulator drives the session (it has
            // no Action button or Water Lock). On-device underwater this is usually
            // inert because Water Lock disables the touchscreen; where it isn't, a
            // tap on End only *arms* the confirmation, so it can't cut a dive short
            // by accident.
            .onTapGesture {
                session.confirmFocused()
            }
            // WatchRootView mounts this view already-active, so focus the Crown when
            // it appears or it won't drive the carousel at the start of a session.
            .onAppear { focusCrown() }
        }
    }

    /// Session elapsed time for the top-bar leading slot, beside the OS clock and
    /// styled to echo it. Shown only with a depth sensor, where depth is the hero;
    /// on a sensorless watch the hero is the time itself, so we don't repeat it. A
    /// red mic dot rides alongside while a voice note records (kept visible even on
    /// a sensorless watch).
    @ViewBuilder
    private var sessionTimeLabel: some View {
        HStack(spacing: 4) {
            if session.hasDepthSensor {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            if session.isRecordingVoiceNote {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    /// GPS icon + accuracy for the top-bar trailing slot, beside the OS clock.
    /// Location is the app's core signal, so its quality lives up top.
    private var gpsInfo: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let (symbol, color) = gpsIconState(now: context.date)
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(color)
                    // While acquiring the first fix, spin a small indicator over
                    // the icon instead of spelling out an "Acquiring…" label.
                    .overlay {
                        if session.lastLocationFixAt == nil {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(color)
                        }
                    }
                if let text = gpsAccuracyText {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Accuracy label beside the GPS icon: "±N m" once a fix carries an accuracy,
    /// "GPS" if fixed without one, or `nil` while still acquiring — in which case
    /// the spinner overlay stands in for the missing label.
    private var gpsAccuracyText: String? {
        if let accuracy = session.lastLocationAccuracy {
            return "±\(Int(accuracy.rounded())) m"
        }
        return session.lastLocationFixAt == nil ? nil : "GPS"
    }

    /// The hero readout filling the middle: a big mm:ss time (minutes unpadded,
    /// 9:05 … 999:05) with the mode icon on a second line below it. Surfaced: the
    /// surface-recovery time (or total elapsed before the first dive) over the
    /// up-arrow wave icon. Submerged: the submersion time over the down-arrow wave
    /// icon followed by the current depth.
    private var centerpiece: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 4) {
                heroTime(seconds: session.isSubmerged
                         ? (session.currentDiveElapsed ?? 0)
                         : (session.surfaceInterval ?? session.elapsedTime))
                secondLine
            }
        }
        // One greedy frame fills the space between the pinned top and bottom
        // blocks; the readout is a fixed-size block centered within it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The big mm:ss time in DIN Condensed (tall, narrow, tabular figures), sized
    /// to fill the available space via `minimumScaleFactor`. Plain `Text` so the
    /// monospaced figures stay put as it ticks.
    private func heroTime(seconds: TimeInterval) -> some View {
        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
            .font(.custom("DINCondensed-Bold", fixedSize: 180))
            .minimumScaleFactor(0.2)
            .lineLimit(1)
            // Crop the empty descender band below the digits so the time sits
            // tighter to the line beneath it.
            .padding(.bottom, -30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mode icon on its own line under the time: the surface icon alone (centered)
    /// at the surface, or the dive icon in front of the current depth while
    /// submerged. A fixed line height reserves the depth's space so the time above
    /// doesn't resize between modes — and, by omitting the depth (rather than just
    /// hiding it) at the surface, the lone icon centers instead of being offset.
    private var secondLine: some View {
        HStack(spacing: 6) {
            if session.isSubmerged {
                submergedIcon
            } else {
                surfacedIcon
            }
            if session.isSubmerged && session.hasDepthSensor {
                Text(DepthFormat.string(session.currentDepthMeters))
                    .font(.custom("DINAlternate-Bold", fixedSize: 36))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(height: 46)
    }

    /// Wave with an up-arrow above it — at/returning to the surface.
    private var surfacedIcon: some View {
        VStack(spacing: -3) {
            Image(systemName: "arrow.up")
            Image(systemName: "water.waves")
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.teal)
    }

    /// Wave with a down-arrow below it — descending / submerged.
    private var submergedIcon: some View {
        VStack(spacing: -3) {
            Image(systemName: "water.waves")
            Image(systemName: "arrow.down")
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.teal)
    }

    /// Counters stitched right above the pill: this-dive figures while submerged,
    /// the session totals (+ surface recovery + distance) at the surface.
    private var statsLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(statsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var statsText: String {
        // The dive / surface time is the hero above, so the counters omit it.
        if session.isSubmerged {
            return session.hasDepthSensor
                ? "max \(DepthFormat.value(session.currentDiveMaxDepth)) m · 📍\(session.currentDiveMarkerCount)"
                : "📍\(session.currentDiveMarkerCount)"
        }
        var parts: [String] = []
        if session.hasDepthSensor {
            parts.append("\(session.diveCount) dives")
            parts.append("\(DepthFormat.value(session.maxDepthMeters)) m")
        }
        parts.append("📍\(session.markerCount)")
        if session.surfaceDistanceMeters >= 1 {
            parts.append(DistanceFormat.string(session.surfaceDistanceMeters))
        }
        return parts.joined(separator: " · ")
    }

    /// Bottom action pill (marker kinds, then End), driven by the Crown. Near-full
    /// width so its rounded ends nest into the watch's bottom corners.
    private var actionPill: some View {
        let item = session.menuItems[min(session.focusedIndex, max(session.menuItems.count - 1, 0))]
        // While a voice note is recording, the Voice Note item reads "Stop".
        let recording = item == .voiceNote && session.isRecordingVoiceNote
        // Voice Note is yellow when idle and red while recording; End is red;
        // markers are teal.
        let tint: Color
        if item == .end {
            tint = .red
        } else if item == .voiceNote {
            tint = recording ? .red : .yellow
        } else {
            tint = .teal
        }
        return HStack(spacing: 6) {
            if let emoji = item.emoji {
                Text(emoji).font(.title3)
            } else {
                Image(systemName: recording ? "stop.circle.fill" : item.systemImage).font(.title3)
            }
            Text(recording ? "Stop" : item.title).font(.caption).fontWeight(.medium).lineLimit(1)
        }
        .foregroundStyle(tint)
        // Fixed height so the pill doesn't shrink when End (an SF Symbol) is
        // focused vs the taller marker emoji.
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .padding(.vertical, 6)
        .background(Capsule().stroke(tint.opacity(0.7), lineWidth: 3))
    }

    /// Seconds without a fix before GPS reads "lost" — generous enough to
    /// tolerate brief stroke-by-stroke gaps.
    private static let gpsStaleAfter: TimeInterval = 12

    /// Icon-only GPS status: teal when a fix is recent, yellow while acquiring the
    /// first one, red crossed-out when it's gone stale (e.g. wrist underwater).
    private func gpsIconState(now: Date) -> (symbol: String, color: Color) {
        guard let lastFix = session.lastLocationFixAt else { return ("location", .yellow) }
        if now.timeIntervalSince(lastFix) <= Self.gpsStaleAfter { return ("location.fill", .teal) }
        return ("location.slash.fill", .red)
    }

    // MARK: - Post-session summary

    /// Just-finished session: the shared summary with a sync badge, plus a
    /// touch-free toolbar — teal ✓ to finish (top-left), grey ↻ to dive again
    /// (top-right). The Action button alone also starts a new session, and the
    /// Action + side dual-click maps to Done.
    private func summaryView(_ completed: DiveSession) -> some View {
        NavigationStack {
            WatchSessionSummaryView(session: completed, showSync: true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await session.start() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .tint(.gray)
                        .accessibilityLabel("Dive again")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session.dismissSummary()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .tint(.teal)
                        .accessibilityLabel("Done")
                    }
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
