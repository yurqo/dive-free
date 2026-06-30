import Foundation

/// Where voice-note files received from the watch are kept on the phone, keyed by
/// the same filename the session's markers reference (`EventMarker.audioFileName`).
enum VoiceNoteStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// The bytes of a stored clip, for mirroring via CloudKit (#169).
    static func data(for fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    /// Writes CloudKit-synced bytes to the local file if it isn't already present,
    /// so a clip synced from another device becomes playable here (#169). Returns
    /// true when a file was written.
    @discardableResult
    static func materialize(_ data: Data, as fileName: String) -> Bool {
        let target = url(for: fileName)
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        do { try data.write(to: target); return true } catch { return false }
    }
}

extension Notification.Name {
    /// Posted (on the main actor) after a voice-note file is received and stored,
    /// so an open detail view can re-enable its play button.
    static let voiceNoteReceived = Notification.Name("DiveFree.voiceNoteReceived")
}
