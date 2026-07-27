import Foundation

/// A single progress report from a long-running backup export or restore.
///
/// Exporting or restoring a full library can take **minutes** (originals may even
/// download from iCloud), so the engine narrates what it is doing instead of leaving
/// the UI on an indeterminate spinner. Reports are emitted *per item*, so a 48-photo
/// export visibly advances rather than sitting still.
///
/// Pure value type (no SwiftData/PhotoKit/SwiftUI) shared by the Persistence engine,
/// the app's ``BackupService``, and the UI. It is `Sendable` because the phases that
/// matter — writing bytes, zipping — deliberately run **off** the main actor and report
/// from there.
///
/// ## Ordering
///
/// ``Phase`` is `Comparable` in pipeline order, and both pipelines only ever move
/// forward through it:
///
/// - export:  `preparing` → `voiceNotes` → `photos` → `compressing` → `finished`
/// - restore: `preparing` → `expanding` → `voiceNotes` → `sessions` → `photos` → `finished`
///
/// so a UI (or a test) can assert progress is monotonic by comparing
/// `(phase, completed)` pairs.
public struct BackupProgress: Sendable, Equatable {
    /// What the engine is working on. Each case is a stage a *user* can recognize; the
    /// app layer supplies the localized wording, since Domain carries no strings.
    public enum Phase: Int, Sendable, Comparable, CaseIterable, Codable {
        /// Reading the store and working out how much there is to do.
        case preparing = 0
        /// Unpacking the `.zip` (restore only).
        case expanding = 1
        /// Copying voice-note clips in or out.
        case voiceNotes = 2
        /// Importing sessions, spots, and trips (restore only).
        case sessions = 3
        /// Copying photo/video thumbnails and originals — normally the long pole.
        case photos = 4
        /// Packing the staging tree into the final `.zip` (export only).
        case compressing = 5
        /// All done.
        case finished = 6

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The stage being reported.
    public var phase: Phase
    /// How many items of this phase are done.
    public var completed: Int
    /// How many items this phase has in total; `0` means "not countable" (show an
    /// indeterminate bar for this phase).
    public var total: Int

    public init(phase: Phase, completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    /// `completed / total`, clamped to `0...1`; `nil` when the phase isn't countable, so
    /// the UI can fall back to an indeterminate bar.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// True once the pipeline has reported ``Phase/finished``.
    public var isFinished: Bool { phase == .finished }
}

/// How the backup engine reports ``BackupProgress``.
///
/// `@Sendable` because the heavy phases run off the main actor and report from there.
/// Callers that need main-actor delivery **in order** should funnel reports through an
/// `AsyncStream` (yielding is ordered and thread-safe) and consume it on the main actor —
/// what ``ExportBackupView`` does — rather than spawning a task per report, which would
/// not preserve order.
public typealias BackupProgressHandler = @Sendable (BackupProgress) -> Void
