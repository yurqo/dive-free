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
    /// the bottom selector.
    private var activeView: some View {
        @Bindable var session = session
        // A NavigationStack purely so the top bar lines the session time / GPS up
        // with the OS clock natively — no manual safe-area math. There's no
        // ScrollView inside, so it doesn't claim the Crown from the carousel.
        return NavigationStack {
            VStack(spacing: 3) {
                // The centerpiece fills everything between the top bar and the
                // bottom selector so they never move when the mode or content changes.
                centerpiece
                statsLine
                // The selector is a non-AOD affordance; the Crown drives it both at the
                // surface and underwater, and the Action button confirms it.
                if !isLuminanceReduced {
                    actionSelector
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            // Pull the content up under the nav bar a little so the big time isn't
            // pushed far below the clock — reduces the gap above it and gives the
            // number more height. (Stays clear of the toolbar row.)
            .padding(.top, -12)
            // Bottom margin for the selector — 0 = flush to the edge; bump up if the
            // display's rounded bottom corners clip the selector on any model.
            .padding(.bottom, 0)
            // Extend under the bottom safe area; the top is handled by the nav bar.
            .ignoresSafeArea(.container, edges: .bottom)
            // GPS (leading) + session time (trailing) flank the OS clock.
            .toolbar {
                // Nudge the top-bar items up to sit tighter against the OS clock row.
                ToolbarItem(placement: .topBarLeading) { gpsInfo.padding(.bottom, 20) }
                ToolbarItem(placement: .topBarTrailing) { sessionTimeLabel.padding(.bottom, 20) }
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
                // tapped — on Ultra map it to the hardware buttons; otherwise unlock
                // with the Crown, then tap.
                Text(session.hasActionButton
                     ? "Action + side to end · Action button to cancel."
                     : "Turn the Crown to unlock, then tap to end.")
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
                    // Light tick per item, a distinct chime at the ends of travel (#149).
                    if index <= 0 || index >= max(session.menuItems.count - 1, 0) {
                        CrownHaptics.end()
                    } else {
                        CrownHaptics.tick()
                    }
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
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
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
                // While acquiring the first fix, show a small spinner in place of
                // the accuracy label (which is nil until a fix lands); once fixed,
                // show the "±N m" / "GPS" accuracy beside the icon.
                if session.lastLocationFixAt == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                } else if let text = gpsAccuracyText {
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
    /// the spinner stands in for the missing label.
    private var gpsAccuracyText: String? {
        if let accuracy = session.lastLocationAccuracy {
            return "±\(DistanceFormat.compact(accuracy))"
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
                         : (session.surfaceInterval ?? session.elapsedTime),
                         color: heroTimeColor)
                secondLine
            }
        }
        // One greedy frame fills the space between the pinned top and bottom
        // blocks; the readout is a fixed-size block centered within it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recommended recovery scales with the dive just completed: red below 1× the
    /// dive time, orange below 2×, yellow below 3×, and white once well rested.
    private static let redIntervalMultiple = 1.0
    private static let orangeIntervalMultiple = 2.0
    private static let yellowIntervalMultiple = 3.0

    /// Tints the hero time to flag a short recovery break, relative to the last
    /// dive's duration — but only for the surface-recovery interval after a dive.
    /// Dive time and the pre-first-dive clock stay white.
    private var heroTimeColor: Color {
        guard !session.isSubmerged,
              let interval = session.surfaceInterval,
              let diveDuration = session.lastDiveDuration else { return .white }
        switch interval {
        case ..<(diveDuration * Self.redIntervalMultiple):    return .red
        case ..<(diveDuration * Self.orangeIntervalMultiple): return .orange
        case ..<(diveDuration * Self.yellowIntervalMultiple): return .yellow
        default:                                              return .white
        }
    }

    /// The big mm:ss time in DIN Condensed (tall, narrow, tabular figures), sized
    /// to fill the available space via `minimumScaleFactor`. Plain `Text` so the
    /// monospaced figures stay put as it ticks.
    private func heroTime(seconds: TimeInterval, color: Color = .white) -> some View {
        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
            .font(.custom("DINCondensed-Bold", fixedSize: 180))
            .foregroundStyle(color)
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
        ZStack {
            // Centerpiece: mode icon, plus the current depth while submerged.
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
            // Flanking live metrics: temperature (left), heart rate (right). The
            // temp slot stays blank on a watch without the submersion sensor.
            HStack {
                sideMetric(temperatureText, systemImage: "thermometer.medium", tint: Color(red: 0, green: 0.5, blue: 0), live: temperatureLive)
                Spacer()
                HeartRateMetric(bpm: session.currentHeartRate)
            }
        }
        .frame(height: 46)
    }

    private var temperatureText: String? {
        // Keep the last reading on screen for the rest of the session, even after
        // surfacing — the submersion sensor only reads underwater, so once we've
        // seen a value we retain it (shown dimmed when not live; see
        // temperatureLive). Stays nil — and the slot blank — on a watch without
        // the sensor, which never produces a reading.
        session.currentTemperatureCelsius.map { "\(TemperatureFormat.value($0))°" }
    }

    /// Whether the temperature readout is live (submerged, so the sensor is
    /// actively reading) vs a retained last value, which is shown dimmed.
    private var temperatureLive: Bool {
        session.isSubmerged
    }

    /// A small stacked icon-over-value used to flank the depth line — narrow, so a
    /// wide value doesn't crowd the centered depth. Rendered invisible (but
    /// keeping its place) when the value is absent, so the layout stays put.
    private func sideMetric(_ text: String?, systemImage: String, tint: Color, live: Bool = true) -> some View {
        // Leading-aligned so the icon stays pinned to the left edge regardless of
        // the value's width (it sits on the left flank).
        VStack(alignment: .leading, spacing: 1) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .opacity(live ? 1 : 0.5) // dim the icon when showing a retained (stale) value
            Text(text ?? "")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .monospacedDigit()
        .opacity(text == nil ? 0 : 1)
    }

    /// Heart-rate slot: a heart that beats with a lub-dub double thump at the live
    /// rate with the bpm below it, or a dim, static heart over "--" when there's no
    /// reading (HR is sparse or absent underwater). Matches `sideMetric`'s narrow
    /// stacked layout; the thump is a render-only `scaleEffect`, so it never nudges
    /// the centered depth.
    private struct HeartRateMetric: View {
        let bpm: Int?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var scale = 1.0
        @State private var beatOpacity = 1.0
        /// Latest rate mirrored into @State so the long-running beat task can pick
        /// up a new reading at a cycle boundary instead of restarting mid-thump.
        @State private var liveBPM: Int?

        private static let activeTint = Color(red: 0.7, green: 0, blue: 0)

        var body: some View {
            // Trailing-aligned so the heart stays pinned to the right edge and
            // doesn't jump when the bpm goes from two digits to three.
            VStack(alignment: .trailing, spacing: 1) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Self.activeTint)
                    .opacity((bpm == nil ? 0.35 : 1) * beatOpacity)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.14), value: scale)
                    .animation(.easeInOut(duration: 0.18), value: beatOpacity)
                Text(bpm.map { "\($0)" } ?? "--")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .monospacedDigit()
            // Keyed on reduceMotion (not bpm): restarts only on the rare
            // accessibility toggle so the beat-vs-pulse mode stays correct, while a
            // new bpm reading (via liveBPM) never cancels/restarts the beat mid-cycle.
            .task(id: reduceMotion) { await pump() }
            .onChange(of: bpm) { _, newValue in liveBPM = newValue }
        }

        /// Beats once per cardiac cycle at the live rate, for the view's lifetime.
        /// A new bpm is applied at the next cycle boundary (read from `liveBPM`),
        /// never interrupting the current thump. Reduce Motion swaps the scaling
        /// lub-dub for a gentle opacity pulse.
        private func pump() async {
            // Seed only if not already set (e.g. by an onChange that landed before
            // this task ran, or before a reduceMotion-triggered restart).
            if liveBPM == nil { liveBPM = bpm }
            scale = 1.0
            beatOpacity = 1.0
            // Let the screen-entry layout settle before the first beat, so the
            // animation doesn't drag the heart in from its pre-layout origin.
            try? await Task.sleep(for: .seconds(0.35))
            while !Task.isCancelled {
                guard let bpm = liveBPM, bpm > 0 else {
                    scale = 1.0
                    beatOpacity = 1.0
                    try? await Task.sleep(for: .seconds(0.5))
                    continue
                }
                let interval = 60.0 / Double(bpm)
                if reduceMotion {
                    // Non-moving liveness cue: fade down and back once per cycle.
                    await holdOpacity(0.5, for: 0.18)
                    await holdOpacity(1.0, for: 0.18)
                    try? await Task.sleep(for: .seconds(max(0.05, interval - 0.36)))
                } else {
                    let cycle = 0.41 // total of the four phases below
                    await hold(1.3, for: 0.10)  // lub — strong first beat
                    await hold(1.08, for: 0.09) // partial relaxation between the two
                    await hold(1.22, for: 0.10) // dub — softer second beat
                    await hold(1.0, for: 0.12)  // settle to rest
                    try? await Task.sleep(for: .seconds(max(0.05, interval - cycle)))
                }
            }
        }

        /// Sets the heart scale (animated via the view's scale animation) and holds
        /// it for the phase's duration before the next phase begins.
        private func hold(_ value: Double, for seconds: Double) async {
            scale = value
            try? await Task.sleep(for: .seconds(seconds))
        }

        /// Opacity-pulse equivalent of `hold`, for the Reduce Motion path.
        private func holdOpacity(_ value: Double, for seconds: Double) async {
            beatOpacity = value
            try? await Task.sleep(for: .seconds(seconds))
        }
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

    /// Counters stitched right above the selector: this-dive figures while submerged,
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
        // Max depth is meaningless at the 6 m ceiling, so it's dropped: the live
        // depth is on the second line while submerged, and the surfaced line
        // shows the last dive's time + depth as recovery context instead.
        if session.isSubmerged {
            return "📍\(session.currentDiveMarkerCount)"
        }
        var parts: [String] = []
        if session.hasDepthSensor {
            parts.append("↓\(session.diveCount)")
            if let duration = session.lastDiveDuration, let depth = session.lastDiveMaxDepth {
                parts.append("⏱\(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) · \(DepthFormat.string(depth))")
            }
        }
        parts.append("📍\(session.markerCount)")
        if session.surfaceDistanceMeters >= 1 {
            parts.append(DistanceFormat.string(session.surfaceDistanceMeters))
        }
        return parts.joined(separator: " · ")
    }

    /// Bottom action bar (marker kinds, then End), driven by the Crown — a flat,
    /// full-width rectangle flush to the screen's bottom edge, showing the focused
    /// option as a black label over the tinted fill. Shares `SessionActionBar`
    /// with the Settings scroll-speed preview.
    private var actionSelector: some View {
        let items = session.menuItems
        let current = items[min(session.focusedIndex, max(items.count - 1, 0))]
        return SessionActionBar(action: current, isRecordingVoiceNote: session.isRecordingVoiceNote)
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
