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
    public var id: UUID
    /// `PHAsset.localIdentifier` of the referenced library photo — the source of
    /// truth for the full image. `nil` only if a reference couldn't be obtained.
    public var assetIdentifier: String?
    /// File name of the cached thumbnail in the app container (see `PhotoStore`),
    /// shown in the gallery without needing Photos access. `nil` if not cached.
    public var thumbnailFileName: String?
    public var createdAt: Date
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
        createdAt: Date = Date(),
        session: SessionRecord? = nil,
        spot: Spot? = nil,
        marker: MarkerRecord? = nil
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.thumbnailFileName = thumbnailFileName
        self.createdAt = createdAt
        self.session = session
        self.spot = spot
        self.marker = marker
    }
}
