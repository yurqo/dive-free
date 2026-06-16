import SwiftUI
import AVFoundation

/// Plays a marker's voice note from the phone's `VoiceNoteStore`. Disabled until
/// the file has arrived from the watch.
struct VoiceNotePlayButton: View {
    let fileName: String

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        let available = VoiceNoteStore.exists(fileName)
        Button {
            isPlaying ? stop() : play()
        } label: {
            Label(
                isPlaying ? "Stop" : (available ? "Play voice note" : "Voice note syncing…"),
                systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill"
            )
        }
        .disabled(!available)
        .foregroundStyle(available ? .teal : .secondary)
    }

    private func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: VoiceNoteStore.url(for: fileName))
            newPlayer.play()
            player = newPlayer
            isPlaying = true
            // Reset when the clip finishes (unless stopped or replaced first).
            Task {
                try? await Task.sleep(for: .seconds(max(newPlayer.duration, 0.1)))
                if player === newPlayer { stop() }
            }
        } catch {
            isPlaying = false
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
