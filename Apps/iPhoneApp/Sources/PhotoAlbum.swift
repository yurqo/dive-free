import Foundation
import Photos

/// Mirrors referenced dive media into a single **Dive Free** album in the user's
/// Photos library (#145) — so adding a dive's photos to a Strava activity means
/// picking from the Dive Free album instead of the whole library. The album holds
/// references (zero byte copy).
///
/// One flat album by design: PhotoKit folders / sub-albums (`PHCollectionList`
/// nesting) raised an uncatchable Obj-C exception on-device, so we keep to the
/// rock-solid create-album / add-assets calls. Best-effort — any failure is a
/// silent no-op and never blocks an import; `PhotoRecord` links remain the source
/// of truth.
// Deliberately NOT @MainActor: `PHPhotoLibrary.performChanges` runs its change
// block on a background queue, so the block must not be actor-isolated — a
// @MainActor block traps with a Swift executor-isolation assertion when Photos
// invokes it off the main actor (the v1.0.27/28 crash).
enum PhotoAlbum {
    static let albumTitle = "Dive Free"

    /// Adds `assetIdentifiers` to the Dive Free album, creating it as needed.
    static func mirror(assetIdentifiers: [String]) async {
        guard !assetIdentifiers.isEmpty else { return }
        // Album management needs full Photos access; prompt once (import itself is
        // permission-free, so otherwise the user is never asked and no album appears).
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized,
              let album = await findOrCreateAlbum(title: albumTitle) else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        // PhotoKit ignores assets already in the album, so no dedupe needed here.
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
        }
    }

    private static func findOrCreateAlbum(title: String) async -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", title)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            return existing
        }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                identifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            return nil
        }
        guard let identifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}
