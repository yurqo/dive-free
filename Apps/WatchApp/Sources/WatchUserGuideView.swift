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
                        "Ending",
                        "On the surface, scroll to End and confirm. Underwater, press the Action + side button together twice.",
                        systemImage: "stop.circle"
                    )
                    item(
                        "Depth",
                        "Depth needs an Ultra or Series 10/11. Other watches still log the GPS track and your markers.",
                        systemImage: "gauge.with.dots.needle.bottom.50percent"
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

    private func item(_ title: String, _ body: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
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
