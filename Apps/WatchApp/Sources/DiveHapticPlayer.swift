import WatchKit
import AVFoundation
import Domain

/// Maps `DiveHapticEvent` values to `WKHapticType` and plays them on the
/// current Watch device. Intentionally kept as a simple enum-namespace so it
/// is trivially injectable or stubbed if tests ever need it.
enum DiveHapticPlayer {
    static func play(_ event: DiveHapticEvent) {
        let type: WKHapticType
        switch event {
        case .diveStart:
            type = .start
        case .surface:
            type = .stop
        case .descendMilestone:
            type = .directionDown
        case .ascendMilestone:
            type = .directionUp
        case .markerPlaced:
            type = .success
        }
        WKInterfaceDevice.current().play(type)
    }
}

/// Synthesises and plays short audio tones for dive events, layered on top of the
/// haptics: a higher-pitched "beep" on the way down, a lower "boop" on the way
/// up — long for the dive start/stop and for crossing the depth ceiling, short
/// for each metre in between.
///
/// Below the 6 m ceiling depth is unmeasurable, so entering it (descending past
/// 6 m) gets a long beep and leaving it (ascending back under 6 m) a long boop.
///
/// Note: while submerged the workout holds Water Lock, which mutes the speaker —
/// so on a real watch these are mainly audible at the surface and on the
/// Simulator; the haptics stay the reliable underwater channel.
@MainActor
enum DiveTonePlayer {
    private static let descendFrequency = 1046.5 // C6 — "beep"
    private static let ascendFrequency = 523.25  // C5 — "boop"
    private static let shortDuration = 0.12
    private static let longDuration = 0.5

    /// Whether the diver is currently below the measurable ceiling (≥ 6 m), so the
    /// next ascend step that lifts them back into known depth gets a long boop.
    private static var inUnknownZone = false
    private static var players: [AVAudioPlayer] = []
    private static var toneCache: [String: Data] = [:]

    static func play(for event: DiveHapticEvent) {
        switch event {
        case .diveStart:
            inUnknownZone = false
            tone(frequency: descendFrequency, duration: longDuration)
        case .surface:
            inUnknownZone = false
            tone(frequency: ascendFrequency, duration: longDuration)
        case .descendMilestone(let depth):
            let ceiling = depth >= DepthFormat.maxMeasurableMeters
            if ceiling { inUnknownZone = true }
            tone(frequency: descendFrequency, duration: ceiling ? longDuration : shortDuration)
        case .ascendMilestone:
            let leftCeiling = inUnknownZone
            inUnknownZone = false
            tone(frequency: ascendFrequency, duration: leftCeiling ? longDuration : shortDuration)
        case .markerPlaced:
            break // markers stay haptic-only
        }
    }

    private static func tone(frequency: Double, duration: Double) {
        // Re-assert the audio session every time: a surface voice note may have
        // switched the shared session to .record and deactivated it, which would
        // otherwise leave dive tones silent for the rest of the session.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        guard let data = toneData(frequency: frequency, duration: duration),
              let player = try? AVAudioPlayer(data: data) else { return }
        // Drop finished players, then retain the new one until it finishes.
        players.removeAll { !$0.isPlaying }
        player.play()
        players.append(player)
    }

    /// The tones are a small fixed set, so cache each synthesised WAV the first
    /// time it's used rather than rebuilding it on every beep.
    private static func toneData(frequency: Double, duration: Double) -> Data? {
        let key = "\(frequency)|\(duration)"
        if let cached = toneCache[key] { return cached }
        guard let data = wav(frequency: frequency, duration: duration) else { return nil }
        toneCache[key] = data
        return data
    }

    /// Builds an in-memory 16-bit mono WAV of a fade-enveloped sine tone, so no
    /// audio assets need bundling.
    private static func wav(frequency: Double, duration: Double) -> Data? {
        let sampleRate = 44_100.0
        let frames = Int(duration * sampleRate)
        guard frames > 0 else { return nil }
        let amplitude = 0.6 * Double(Int16.max)
        let fade = min(frames / 4, Int(0.008 * sampleRate)) // de-click ramp
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            var value = sin(2 * .pi * frequency * Double(i) / sampleRate) * amplitude
            if fade > 0 {
                if i < fade { value *= Double(i) / Double(fade) }
                else if i >= frames - fade { value *= Double(frames - 1 - i) / Double(fade) }
            }
            samples[i] = Int16(max(-32_767, min(32_767, value)))
        }

        let channels = 1, bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = Int(sampleRate) * blockAlign
        let dataSize = samples.count * blockAlign
        var data = Data(capacity: 44 + dataSize)
        func str(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
