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
    @State private var duration: TimeInterval?
    @State private var currentTime: TimeInterval = 0

    var body: some View {
        Button {
            isPlaying ? stop() : play()
        } label: {
            Label(title, systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill")
        }
        .disabled(!available)
        .foregroundStyle(available ? .teal : .secondary)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceNoteReceived)) { _ in
            refresh()
        }
    }

    /// Button text: a syncing notice until the clip arrives, otherwise Play/Stop
    /// with a time appended — the elapsed position while playing, the clip length
    /// when idle.
    private var title: String {
        guard available else { return "Voice note syncing…" }
        let base = isPlaying ? "Stop" : "Play voice note"
        guard let time = isPlaying ? currentTime : duration else { return base }
        return "\(base) · \(Duration.seconds(time.rounded()).formatted(.time(pattern: .minuteSecond)))"
    }

    /// Refreshes availability and reads the clip length once the file exists.
    private func refresh() {
        available = VoiceNoteStore.exists(fileName)
        if available, duration == nil {
            duration = try? AVAudioPlayer(contentsOf: VoiceNoteStore.url(for: fileName)).duration
        }
    }

    private func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: VoiceNoteStore.url(for: fileName))
            newPlayer.play()
            player = newPlayer
            currentTime = 0
            isPlaying = true
            // Tick the elapsed position for the clip's length, then reset. Bounded
            // by wall-clock rather than isPlaying (which can read false the instant
            // after play(), cutting playback off immediately).
            Task {
                let total = max(newPlayer.duration, 0.1)
                let start = Date()
                while player === newPlayer, Date().timeIntervalSince(start) < total {
                    currentTime = newPlayer.currentTime
                    try? await Task.sleep(for: .seconds(0.3))
                }
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
