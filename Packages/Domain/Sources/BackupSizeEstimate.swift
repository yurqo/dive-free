import Foundation

/// An approximate byte breakdown of what a backup export will produce, split by the
/// categories the user can toggle plus the always-included baseline (manifest +
/// thumbnails).
///
/// Pure value type (no PhotoKit/SwiftData) so the app can compute the raw sums from
/// the Photos library and hand a plain, `Sendable` result to the UI — which renders
/// the human-readable strings via ``formatted(_:)`` (a `ByteCountFormatter` wrapper).
///
/// Sizes are deliberately approximate: photo/video originals are measured from
/// `PHAssetResource` metadata without downloading iCloud-only bytes, so the figure is
/// a best-effort estimate, not a guarantee of the final `.zip` size.
public struct BackupSizeEstimate: Sendable, Equatable {
    /// Always-included bytes: the JSON manifest plus every photo's small thumbnail.
    public var base: Int64
    /// Voice-note audio originals (only counted when `includeVoiceNotes`).
    public var voiceNotes: Int64
    /// Full-resolution photo originals (only counted when `includePhotos`).
    public var photos: Int64
    /// Full-resolution video originals (only counted when `includeVideos`).
    public var videos: Int64

    public init(base: Int64 = 0, voiceNotes: Int64 = 0, photos: Int64 = 0, videos: Int64 = 0) {
        self.base = base
        self.voiceNotes = voiceNotes
        self.photos = photos
        self.videos = videos
    }

    /// The estimated size of the whole archive: baseline plus every enabled category.
    public var total: Int64 { base + voiceNotes + photos + videos }

    /// A localized, human-readable byte string (e.g. "1.2 MB") for an arbitrary count.
    public func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Convenience: the whole-archive estimate, formatted.
    public var totalFormatted: String { formatted(total) }
}
