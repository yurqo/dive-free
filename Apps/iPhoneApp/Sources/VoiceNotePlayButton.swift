import SwiftUI
import AVFoundation

/// Plays a marker's voice note from the phone's `VoiceNoteStore`. Disabled until
/// the file has arrived from the watch; re-enables itself when a clip lands while
/// the view is open (it observes `.voiceNoteReceived`).
struct VoiceNotePlayButton: View {
    let fileName: String

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var available = false

    var body: some View {
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
        .onAppear { available = VoiceNoteStore.exists(fileName) }
        .onReceive(NotificationCenter.default.publisher(for: .voiceNoteReceived)) { _ in
            available = VoiceNoteStore.exists(fileName)
        }
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
        // Release the session so other apps' audio (e.g. music) can resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
