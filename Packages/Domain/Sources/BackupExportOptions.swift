import Foundation

/// What heavy media a backup export should bundle, on top of the always-included
/// manifest, spot/trip/session metadata, photo metadata, and thumbnails.
///
/// A backup *always* carries every session, spot, trip, and photo's metadata plus a
/// small thumbnail per photo — that's cheap and makes an offline gallery work after a
/// restore. The heavy originals are opt-in per kind, because a full library of photos
/// and (especially) videos can be gigabytes: the user chooses what's worth the size.
///
/// Everything defaults to `false` — a metadata-only backup — so a caller that says
/// nothing produces the smallest, safest archive.
///
/// Pure value type (no SwiftData/PhotoKit), shared by the Persistence engine and the
/// app's UI so both agree on the toggles.
public struct BackupExportOptions: Codable, Sendable, Equatable {
    /// Bundle each marker's voice-note audio file (`voice/<name>`).
    public var includeVoiceNotes: Bool
    /// Bundle full-resolution originals for *photo* (non-video) attachments.
    public var includePhotos: Bool
    /// Bundle full-resolution originals for *video* attachments (typically the largest
    /// payload — kept separate from photos so the user can include stills but not clips).
    public var includeVideos: Bool

    public init(
        includeVoiceNotes: Bool = false,
        includePhotos: Bool = false,
        includeVideos: Bool = false
    ) {
        self.includeVoiceNotes = includeVoiceNotes
        self.includePhotos = includePhotos
        self.includeVideos = includeVideos
    }
}
