import Foundation
import SwiftData

/// Metadata for a photo attached to a session (and, later, directly to a spot).
/// The image bytes live as files in the app container (see the app's `PhotoStore`);
/// only the `fileName` + links are persisted — no blobs in SwiftData.
@Model
public final class PhotoRecord {
    public var id: UUID
    /// Base file name of the stored image (the thumbnail is derived from it).
    public var fileName: String
    public var createdAt: Date
    /// `PHAsset.localIdentifier` when imported from the photo library, so the
    /// timestamp auto-suggest (#126) can skip assets that are already attached.
    public var assetIdentifier: String?
    /// The session this photo belongs to, if attached via a session.
    public var session: SessionRecord?
    /// The spot this photo is attached to directly (forward-compatible with #107).
    public var spot: Spot?

    public init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        assetIdentifier: String? = nil,
        session: SessionRecord? = nil,
        spot: Spot? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.assetIdentifier = assetIdentifier
        self.session = session
        self.spot = spot
    }
}
