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
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    /// Concatenates two voice-note clips (existing first, then the new one) into a
    /// single `.m4a`, returning the merged file's name and deleting the two
    /// sources. Lets repeated recordings on the same marker accumulate instead of
    /// the newer one silently replacing the older.
    ///
    /// watchOS has no `AVAssetExportSession`, so we copy PCM frames through
    /// `AVAudioFile` (streamed in chunks to keep memory bounded), re-encoding to
    /// the same AAC/m4a format the clips were recorded in. `nonisolated async` so
    /// the decode/encode runs off the main actor.
    nonisolated static func merge(_ firstName: String, with secondName: String) async throws -> String {
        let mergedName = "voice-\(UUID().uuidString).m4a"
        let outputURL = url(for: mergedName)

        // Reuse the first clip's own format for the writer (same AAC/m4a settings).
        let template = try AVAudioFile(forReading: url(for: firstName))
        let output = try AVAudioFile(forWriting: outputURL, settings: template.fileFormat.settings)

        // The output file exists on disk from `forWriting:` onward, but no marker
        // references it until we return. A mid-stream throw would leave it orphaned
        // (the watch has no sweeper), so remove the partial file before rethrowing.
        do {
            for name in [firstName, secondName] {
                let input = try AVAudioFile(forReading: url(for: name))
                let format = input.processingFormat
                let chunk: AVAudioFrameCount = 32_768
                while true {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                    try input.read(into: buffer, frameCount: chunk)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        // The clips now live in the merged file — drop the sources.
        try? FileManager.default.removeItem(at: url(for: firstName))
        try? FileManager.default.removeItem(at: url(for: secondName))
        return mergedName
    }

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
            guard newRecorder.record() else {
                // Release the session we just activated, or it stays claimed against
                // the workout's audio routing (1f).
                deactivateSession()
                return false
            }
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
            // Setup threw after (possibly) activating the session — release it so it
            // doesn't stay claimed against the workout's audio routing (1f).
            deactivateSession()
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
        // Release the session so the workout's audio routing can resume.
        deactivateSession()
        return fileName
    }

    /// Releases the shared audio session so it doesn't stay claimed against the
    /// workout's audio routing (1f). Shared by `start()`'s failure exits and
    /// `stop()`.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
