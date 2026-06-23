import Foundation
import Photos

/// Mirrors referenced dive media into a virtual "DiveFree" album structure in the
/// user's Photos library (#145): a top-level **DiveFree** folder containing an
/// **All** album plus one album per session. Albums are references — zero byte
/// copy — so this is free storage-wise and makes adding a dive's photos to a
/// Strava activity painless (pick the dive's album instead of the whole library).
///
/// Everything here is **best-effort**: any failure (no/Limited access, PhotoKit
/// error) is a silent no-op so it never blocks an import. The app's own
/// `PhotoRecord` links remain the source of truth; the album is a one-way mirror.
@MainActor
enum PhotoAlbum {
    static let folderTitle = "DiveFree"
    static let allAlbumTitle = "All"

    /// Adds `assetIdentifiers` to the All album and, when given, the session's
    /// album, creating the folder/albums as needed (resolved once for the batch).
    static func mirror(assetIdentifiers: [String], sessionAlbumTitle: String?) async {
        // Only mirror when full access is *already* granted — never prompt from this
        // background pass (the import itself is permission-free). Album management
        // also needs full (not Limited) access; it activates once the user grants
        // access through a foreground flow (e.g. viewing a photo full-screen).
        guard !assetIdentifiers.isEmpty,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let folder = await findOrCreateFolder() else { return }
        if let all = await findOrCreateAlbum(title: allAlbumTitle, inFolder: folder) {
            for id in assetIdentifiers { await add(id, toAlbum: all) }
        }
        if let sessionAlbumTitle, let album = await findOrCreateAlbum(title: sessionAlbumTitle, inFolder: folder) {
            for id in assetIdentifiers { await add(id, toAlbum: album) }
        }
    }

    // MARK: - Folder / albums

    private static func findOrCreateFolder() async -> PHCollectionList? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", folderTitle)
        if let existing = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: options).firstObject {
            return existing
        }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderTitle)
                identifier = request.placeholderForCreatedCollectionList.localIdentifier
            }
        } catch {
            return nil
        }
        guard let identifier else { return nil }
        return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private static func findOrCreateAlbum(title: String, inFolder folder: PHCollectionList) async -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", title)
        if let existing = PHCollectionList.fetchCollections(in: folder, options: options).firstObject as? PHAssetCollection {
            return existing
        }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                let placeholder = albumRequest.placeholderForCreatedAssetCollection
                identifier = placeholder.localIdentifier
                // Nest the new album under the DiveFree folder.
                PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray)
            }
        } catch {
            return nil
        }
        guard let identifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private static func add(_ assetIdentifier: String, toAlbum album: PHAssetCollection) async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return }
        // Skip if the asset is already in the album (avoid duplicate entries).
        let membership = PHFetchOptions()
        membership.predicate = NSPredicate(format: "localIdentifier == %@", assetIdentifier)
        guard PHAsset.fetchAssets(in: album, options: membership).count == 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
    }
}
