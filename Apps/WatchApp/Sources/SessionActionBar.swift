import SwiftUI
import WatchKit

/// The flat, full-width action bar shown at the bottom of the live session — and
/// reused in Settings → Scroll Speed to preview it. Renders one `SessionAction`
/// as a black label over a screen-wide tinted fill: markers teal, Voice Note
/// yellow (red "Stop" while recording), End red.
struct SessionActionBar: View {
    let action: SessionCoordinator.SessionAction
    /// Voice Note shows "Stop" on a red fill while a note is recording.
    var isRecordingVoiceNote = false

    private var recording: Bool { action == .voiceNote && isRecordingVoiceNote }

    private var tint: Color {
        if action == .end { return .red }
        if action == .voiceNote { return recording ? .red : .yellow }
        return .teal
    }

    var body: some View {
        HStack(spacing: 6) {
            if let emoji = action.emoji {
                Text(emoji).font(.title3)
            } else {
                Image(systemName: recording ? "stop.circle.fill" : action.systemImage).font(.title3)
            }
            Text(recording ? "Stop" : action.title).font(.caption).fontWeight(.medium).lineLimit(1)
        }
        .foregroundStyle(.black)
        // Exact physical screen width so the bar reaches both edges regardless of
        // the surrounding content's safe-area / padding insets.
        .frame(width: WKInterfaceDevice.current().screenBounds.width, height: 36)
        .background(tint)
    }
}
