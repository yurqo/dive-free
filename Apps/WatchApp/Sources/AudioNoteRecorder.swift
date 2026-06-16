import AVFoundation
import Observation

/// Records a short surface voice note to an `.m4a` file. The coordinator drives
/// it: start on the carousel's Voice Note action, stop on the same action again,
/// on submersion, or at the hard cap. The recorded filename is attached to the
/// last marker.
@MainActor
@Observable
final class AudioNoteRecorder {
    private(set) var isRecording = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var capTask: Task<Void, Never>?

    /// Fired (on the main actor) when the hard cap stops a recording, so the
    /// coordinator can finalize and attach the file like a manual stop.
    @ObservationIgnored var onCap: (@MainActor () -> Void)?

    /// A forgotten recording can't run forever (battery + storage).
    static let maxDuration: TimeInterval = 120

    /// Directory holding voice-note files (created on demand).
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    /// Requests mic permission (once), configures the session, and starts
    /// recording. Returns `false` if permission was denied or setup failed.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording else { return false }
        guard await requestPermission() else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let fileName = "voice-\(UUID().uuidString).m4a"
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let newRecorder = try AVAudioRecorder(url: Self.url(for: fileName), settings: settings)
            guard newRecorder.record() else { return false }
            recorder = newRecorder
            isRecording = true

            // Hard cap: stop via the coordinator so the file is still attached.
            capTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.maxDuration))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                self.onCap?()
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops recording and returns the saved filename, or `nil` if idle.
    @discardableResult
    func stop() -> String? {
        guard isRecording, let recorder else { return nil }
        let fileName = recorder.url.lastPathComponent
        recorder.stop()
        self.recorder = nil
        isRecording = false
        capTask?.cancel()
        capTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        return fileName
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
