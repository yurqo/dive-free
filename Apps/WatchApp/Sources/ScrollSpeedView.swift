import SwiftUI
import WatchKit
import Persistence

/// Settings sub-screen for the Digital Crown scroll speed: pick a speed and feel
/// it live. Tapping a speed updates `crownStepsPerItem`; the same flat action bar
/// from the live session sits flush at the bottom and advances through the
/// diver's real carousel as the Crown turns — with the identical one-buzz-per-
/// item haptic — so "Slow" vs "Fast" is something you feel, not guess.
///
/// The speed chips are tap-driven on purpose so the Crown stays bound to the
/// preview (a Crown-driven Picker would fight it for rotation).
struct ScrollSpeedView: View {
    @Environment(SessionCoordinator.self) private var session
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 6

    @State private var crownPosition: Double = 0
    @State private var focusedIndex = 0
    /// Last item the Crown landed on, so we buzz once per item (not per detent).
    @State private var lastFocusedIndex = 0
    @FocusState private var crownFocused: Bool

    /// (label, detents-per-item) — the same scale offered in-session.
    static let speeds: [(label: String, steps: Int)] = [
        ("Fast", 3), ("Medium", 4), ("Slow", 6), ("Slowest", 9),
    ]

    /// Settings-row label for the current setting (also used by `WatchSettingsView`).
    static func label(forSteps steps: Int) -> String {
        speeds.first { $0.steps == steps }?.label ?? "Custom"
    }

    /// The diver's actual carousel, so the preview matches what they'll scroll.
    private var items: [SessionCoordinator.SessionAction] { session.menuItems }

    var body: some View {
        VStack(spacing: 8) {
            speedGrid
            Spacer(minLength: 4)
            Text("Turn the Crown to try it")
                .font(.caption2)
                .foregroundStyle(.secondary)
            progressBar
            previewBar
        }
        .padding(.horizontal, 8)
        // Let the preview bar sit flush on the bottom edge like the real one.
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("Scroll Speed")
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            $crownPosition,
            from: 0,
            through: Double(max(items.count - 1, 0) * crownStepsPerItem),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownPosition) { _, newValue in
            let index = Int((newValue / Double(crownStepsPerItem)).rounded())
            if index != lastFocusedIndex {
                lastFocusedIndex = index
                // Same cadence as the live session: tick per item, chime at the ends (#149).
                if index <= 0 || index >= max(items.count - 1, 0) {
                    CrownHaptics.end()
                } else {
                    CrownHaptics.tick()
                }
            }
            focusedIndex = max(0, min(index, max(items.count - 1, 0)))
        }
        .onChange(of: crownStepsPerItem) { _, newSteps in
            // Re-sync so the highlighted item stays put when the speed changes.
            crownPosition = Double(focusedIndex * newSteps)
            lastFocusedIndex = focusedIndex
        }
        .onAppear { crownFocused = true }
    }

    /// 2×2 grid of tappable speed chips; the active one is filled teal.
    private var speedGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.speeds, id: \.steps) { speed in
                let selected = crownStepsPerItem == speed.steps
                Button {
                    crownStepsPerItem = speed.steps
                    crownFocused = true
                    WKInterfaceDevice.current().play(.click)
                } label: {
                    Text(speed.label)
                        .font(.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? .black : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? Color.teal : Color.gray.opacity(0.3), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Thin bar that fills toward the carousel's end as the Crown scrolls, so the
    /// scroll position (and thus the speed) is visible as well as felt.
    private var progressBar: some View {
        let denominator = max(items.count - 1, 1)
        let fraction = items.count > 1 ? Double(focusedIndex) / Double(denominator) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3))
                Capsule().fill(Color.teal).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.15), value: focusedIndex)
    }

    @ViewBuilder
    private var previewBar: some View {
        if items.indices.contains(focusedIndex) {
            SessionActionBar(action: items[focusedIndex])
        }
    }
}

#Preview {
    NavigationStack {
        ScrollSpeedView()
    }
    .environment(
        SessionCoordinator(
            modelContext: try! DiveStore(inMemory: true).container.mainContext
        )
    )
}
