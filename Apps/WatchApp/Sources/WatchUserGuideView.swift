import SwiftUI

/// Short in-app guide reached from the Start screen — the essentials of running
/// a dive touch-free, since the screen is water-locked underwater.
struct WatchUserGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    item(
                        "Start",
                        "Tap Start, or press the Action button if you've assigned Dive Free to it in Settings → Action Button.",
                        systemImage: "play.circle"
                    )
                    item(
                        "Underwater",
                        "The screen locks underwater. Turn the Digital Crown to pick a marker, then press the Action button to drop it.",
                        systemImage: "drop.fill"
                    )
                    item(
                        "Water Lock",
                        "Water Lock turns on for you when a session starts and each time you dive, so a wet screen won't register taps. Turn the Digital Crown to exit it and eject water; you can turn either off in Settings.",
                        systemImage: "drop.circle"
                    )
                    item(
                        "Default marker",
                        "Set your most-used marker as the default in Settings — it's pre-selected and what the Action button drops underwater.",
                        systemImage: "mappin"
                    )
                    item(
                        "Voice notes",
                        "At the surface, scroll up to Voice Note and confirm to record; confirm again to stop. It attaches to your last marker and auto-stops when you dive.",
                        systemImage: "mic.fill"
                    )
                    item(
                        "Manual dive",
                        "Press the Action + side button together to start a dive the instant you descend, and again to end it — before depth even registers. Auto-detection handles dives otherwise.",
                        systemImage: "hand.tap"
                    )
                    item(
                        "Ending",
                        "Scroll the Crown to End and press the Action button. In the confirm dialog, Action + side ends and the Action button cancels.",
                        systemImage: "stop.circle"
                    )
                    item(
                        "Discarding",
                        "Started a session by mistake? On the summary after it ends, tap Discard (and confirm) to throw it away — it's removed from the watch and won't appear on your iPhone.",
                        systemImage: "trash"
                    )
                    item(
                        "Depth",
                        "Depth needs an Ultra or Series 10/11. Other watches still log the GPS track and your markers.",
                        systemImage: "gauge.with.dots.needle.bottom.50percent"
                    )
                    item(
                        "Surface interval",
                        "After a dive the big timer is your surface recovery, tinted by how far through your recommended rest you are: red, then orange, then yellow, turning green the moment you reach it. The green clears shortly after, leaving the timer white.",
                        systemImage: "timer"
                    )
                    item(
                        "Heart rate & temp",
                        "Your live heart rate beats on the right (any watch). Water temperature shows on the left on an Ultra while underwater, dimming to the last reading at the surface. A dash means no reading yet.",
                        systemImage: "heart.fill"
                    )
                    item(
                        "Snug strap",
                        "Wear the watch snug — a finger-width above the wrist bone — and tighten the strap before diving. A firm fit keeps the optical sensor reading your heart rate, especially in cold water.",
                        systemImage: "applewatch"
                    )
                    item(
                        "GPS",
                        "The arrow top-left shows GPS: a spinner while acquiring, then accuracy. Let it fix before you dive to tag your spot — GPS can't track underwater.",
                        systemImage: "location.fill"
                    )
                    item(
                        "Units",
                        "Pick metric, imperial, or a custom mix in Settings — depth, distance, and temperature follow your choice here and on iPhone. Set it on the phone and it syncs to the watch.",
                        systemImage: "ruler"
                    )
                }
                .padding()
            }
            .navigationTitle("Guide")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Opaque sheet so the Start screen (and its blue button) doesn't bleed
        // through the default translucent presentation background.
        .presentationBackground(Color.black)
    }

    // Payloads are `LocalizedStringResource` so the English literals at each
    // `item("…", "…")` call site auto-extract into the Watch app's String Catalog
    // (via `SWIFT_EMIT_LOC_STRINGS`); a plain `String` reaches `Label`/`Text`
    // through their verbatim initializers and would not localize. English output
    // is unchanged.
    private func item(_ title: LocalizedStringResource, _ body: LocalizedStringResource, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // `Text(LocalizedStringResource)` parses inline markdown and treats
            // `%` as a format specifier — keep the title/body literals free of both.
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .font(.headline)
                .foregroundStyle(.teal)
            Text(body)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WatchUserGuideView()
}
