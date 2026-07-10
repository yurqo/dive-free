import Foundation
import Persistence

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

    /// Removes a stored voice-note file (mirror of `PhotoStore.delete`). Called
    /// when a session is deleted so its clips don't orphan in the container.
    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Mirrors a marker's on-disk clip bytes into its CloudKit-synced `audioData`
    /// so the recording reaches other devices even if this phone never opens the
    /// session's detail view. No-op (returns false) when `audioData` is already
    /// set, the marker has no file name, or the file isn't on disk. Returns whether
    /// it assigned anything; the caller saves. Shared by the sync-received,
    /// detail-reconcile, and import paths so the "check nil → load → assign" logic
    /// lives in one place.
    @MainActor
    @discardableResult
    static func mirrorAudioData(into marker: MarkerRecord) -> Bool {
        guard marker.audioData == nil,
              let fileName = marker.audioFileName,
              let data = data(for: fileName) else { return false }
        marker.audioData = data
        return true
    }
}

/// Removes a session's on-disk artifacts that SwiftData's cascade delete never
/// touches — photo thumbnails and voice-note files. Call before deleting the
/// record from both delete paths (list swipe + watch-deletion mirror), since the
/// stores keep files outside the model graph.
@MainActor
func deleteLocalArtifacts(of session: SessionRecord) {
    // Reading .photos/.markers on a deleted @Model traps (#148) — bail if the
    // record is already gone from its context (project-wide pattern).
    guard session.modelContext != nil else { return }
    for photo in (session.photos ?? []) { PhotoStore.delete(photo.thumbnailFileName) }
    for marker in (session.markers ?? []) { marker.audioFileName.map(VoiceNoteStore.delete) }
}

extension Notification.Name {
    /// Posted (on the main actor) after a voice-note file is received and stored,
    /// so an open detail view can re-enable its play button.
    static let voiceNoteReceived = Notification.Name("DiveFree.voiceNoteReceived")
}
