import Foundation
import SwiftData
import Domain
import Persistence

/// The iPhone-side glue for full backup & restore. Wraps Persistence's pure
/// ``BackupRestore`` engine with the two impure edges it defers to the app —
/// reading and writing voice-note audio bytes via ``VoiceNoteStore`` — and the
/// file-handling concerns of producing a shareable temp file (export) and reading
/// a security-scoped `fileImporter` URL (restore).
///
/// `@MainActor` because ``BackupRestore`` reads/writes through a main-actor
/// `ModelContext`.
@MainActor
enum BackupService {
    /// Builds a full archive of every session, spot, trip, and voice note, writes it
    /// as deterministic JSON to a unique temp file, and returns the URL for the share
    /// sheet.
    ///
    /// The file goes into its own unique temp subdirectory (mirroring `ExportFormat`)
    /// so the human-readable, date-stamped filename can't collide with a concurrent
    /// or same-day export still in flight.
    static func exportBackup(context: ModelContext) throws -> URL {
        let archive = try BackupRestore(context: context).makeArchive(
            appVersion: appVersion,
            audioBytes: { VoiceNoteStore.data(for: $0) }
        )
        let data = try archive.encoded()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(fileName()).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Restores an archive picked from Files. Reads the security-scoped URL that
    /// `fileImporter` hands back, decodes it, and applies it additively — existing
    /// items are kept, duplicates dedupe by id. No tombstone check: an explicit
    /// restore is meant to bring the archived data back.
    static func restoreBackup(from url: URL, context: ModelContext) throws -> BackupRestore.RestoreSummary {
        // A `fileImporter` URL is security-scoped; without begin/stop access the read
        // fails on-device.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let archive = try BackupArchive.decode(data)
        return try BackupRestore(context: context).restore(
            from: archive,
            materializeAudio: { name, bytes in VoiceNoteStore.materialize(bytes, as: name) }
        )
    }

    // MARK: - Helpers

    /// The app's marketing version (`CFBundleShortVersionString`), stored in the
    /// archive purely for information.
    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// A human-readable, date-stamped base filename: `DiveFree Backup 2026-07-24`.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "DiveFree Backup \(formatter.string(from: Date()))"
    }
}
