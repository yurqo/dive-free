import Foundation
import SwiftData

/// Metadata for a photo attached to a session (and/or a spot).
///
/// Media is **referenced**, not copied (#141): the original lives in the user's
/// Photos library, identified by `assetIdentifier` (`PHAsset.localIdentifier`).
/// We keep only a small `thumbnailFileName` in the app container for a fast,
/// offline gallery; the full image is loaded from Photos on demand. This keeps
/// the app's footprint flat regardless of how much media is attached.
@Model
public final class PhotoRecord {
    // Optional/defaulted for CloudKit compatibility (#168); additive migration.
    public var id: UUID = UUID()
    /// `PHAsset.localIdentifier` of the referenced library photo — the source of
    /// truth for the full image. `nil` only if a reference couldn't be obtained.
    public var assetIdentifier: String?
    /// File name of the cached thumbnail in the app container (see `PhotoStore`),
    /// shown in the gallery without needing Photos access. `nil` if not cached.
    public var thumbnailFileName: String?
    /// Thumbnail bytes, stored externally and mirrored via CloudKit so the gallery
    /// thumbnail shows on your other devices (#169). The cached file stays the fast
    /// path; this is the cross-device carrier.
    @Attribute(.externalStorage) public var thumbnailData: Data?
    /// `PHCloudIdentifier.stringValue` for the referenced asset (#169) — stable
    /// across devices (unlike `assetIdentifier`, a device-local id), so the full
    /// image can be resolved from iCloud Photos on another device.
    public var assetCloudIdentifier: String?
    public var createdAt: Date = Date()
    /// Whether the referenced asset is a video (#139) — drives the play badge and
    /// AVKit playback. Defaulted false for lightweight migration of photo rows.
    public var isVideo: Bool = false
    /// The session this photo belongs to, if attached via a session.
    public var session: SessionRecord?
    /// The spot this photo is attached to directly.
    public var spot: Spot?
    /// An optional marker this photo is linked to (#143). Deleting the marker
    /// nullifies this (the photo stays on its session/spot).
    public var marker: MarkerRecord?

    public init(
        id: UUID = UUID(),
        assetIdentifier: String? = nil,
        thumbnailFileName: String? = nil,
        thumbnailData: Data? = nil,
        assetCloudIdentifier: String? = nil,
        createdAt: Date = Date(),
        isVideo: Bool = false,
        session: SessionRecord? = nil,
        spot: Spot? = nil,
        marker: MarkerRecord? = nil
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.thumbnailFileName = thumbnailFileName
        self.thumbnailData = thumbnailData
        self.assetCloudIdentifier = assetCloudIdentifier
        self.createdAt = createdAt
        self.isVideo = isVideo
        self.session = session
        self.spot = spot
        self.marker = marker
    }
}
