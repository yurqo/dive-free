import Foundation
import SwiftData

/// Deletes voice-note files left orphaned on disk. A session deleted on another
/// device disappears here via CloudKit without either local delete path running,
/// so its materialized clip files (written by the detail view's reconcile, #169)
/// orphan. This sweep — run at launch — reads the still-referenced file names on
/// the main actor (`ModelContext` is main-actor isolated), then does the directory
/// listing and deletion off the main actor: it keeps only files still referenced
/// by a stored `MarkerRecord` and removes the rest. It also retroactively cleans
/// anything already leaked in the wild (e.g. deletes that predate the local
/// file-cleanup fix).
///
/// A minimum-age guard (`minimumSweepAge`) protects clips that are still in
/// flight from the watch: voice-note audio arrives over `transferFile`
/// independently of the `transferUserInfo` session payload that creates the
/// referencing marker, so a freshly delivered clip can legitimately have no
/// marker yet (this is why `SessionImporter` backfills). The age guard keeps any
/// file younger than the window; true orphans are older and still get cleaned on
/// a later launch.
///
/// `@MainActor` because it fetches through the container's main `ModelContext`.
@MainActor
public struct VoiceNoteSweeper {
    private let context: ModelContext

    /// Minimum age a file must reach before the sweep may delete it as an orphan.
    ///
    /// Watch voice-note audio (`transferFile`) can land before its session
    /// payload (`transferUserInfo`), so a just-arrived clip briefly has no marker
    /// referencing it. Deleting it then would lose the recording permanently (the
    /// watch treats the file as delivered and won't resend). Any legitimately
    /// in-flight payload resolves well within 7 days, so only files older than
    /// this are safe to treat as true orphans.
    // `nonisolated` so the nonisolated `deleteOrphans` can use it as a default.
    nonisolated public static let minimumSweepAge: TimeInterval = 7 * 86_400

    public init(context: ModelContext) {
        self.context = context
    }

    /// Removes every file in `directory` not referenced by a stored marker and
    /// older than `minimumAge`. Returns the file names deleted. The marker fetch
    /// runs here on the main actor; the file I/O runs off it.
    @discardableResult
    public func sweep(directory: URL, minimumAge: TimeInterval = minimumSweepAge) async throws -> [String] {
        let referenced = try referencedFileNames()
        return await Task.detached {
            Self.deleteOrphans(in: directory, referenced: referenced, minimumAge: minimumAge)
        }.value
    }

    /// The set of voice-note file names any stored marker still points at.
    func referencedFileNames() throws -> Set<String> {
        let markers = try context.fetch(FetchDescriptor<MarkerRecord>())
        // Guard against a row deleted mid-fetch (#148) before reading its property.
        return Set(markers.compactMap { $0.modelContext != nil ? $0.audioFileName : nil })
    }

    /// Pure helper: deletes files in `directory` whose names aren't in `referenced`
    /// and whose modification date is older than `minimumAge` before `now`. A file
    /// whose modification date can't be read is skipped (never deleted on unknown
    /// age). Separated out so it's unit-testable without a model container.
    /// `nonisolated` — pure file I/O, so `sweep` can run it off the main actor.
    @discardableResult
    nonisolated static func deleteOrphans(
        in directory: URL,
        referenced: Set<String>,
        minimumAge: TimeInterval = minimumSweepAge,
        now: Date = Date()
    ) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let cutoff = now.addingTimeInterval(-minimumAge)
        var removed: [String] = []
        for name in names where !referenced.contains(name) {
            let url = directory.appendingPathComponent(name)
            // Skip (don't delete) if the modification date is unreadable.
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { continue }
            guard modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed
    }
}
