import Foundation
import Photos

/// Mirrors referenced dive media into a "Dive Free" folder hierarchy in the user's
/// Photos library (#145):
///
///     Dive Free ▸ All                          — every imported item
///     Dive Free ▸ Spots ▸ <spot> ▸ <session>   — that session's media
///
/// iOS Photos supports nested folders (`PHCollectionList` can contain albums and
/// sub-folders); only albums (`PHAssetCollection`) hold photos, so the leaf
/// session is an album. References — zero byte copy.
///
/// Deliberately **not `@MainActor`**: `PHPhotoLibrary.performChanges` runs its
/// block on a background queue, so the block must not be actor-isolated (a
/// `@MainActor` block traps with a Swift executor-isolation assertion when Photos
/// invokes it off the main actor — the v1.0.27/28 crash). All in/out is Sendable;
/// callers read names/ids from SwiftData on the main actor, pass them here, and
/// persist the returned ids back on the main actor. Everything is best-effort: a
/// failure (no/limited access, PhotoKit error) is a silent no-op.
enum PhotoAlbum {
    static let rootTitle = "Dive Free"
    static let allTitle = "All"
    static let spotsTitle = "Spots"

    /// The (possibly newly-created) collection ids to persist on the Spot/Session
    /// so they're reused — and rename-able — across imports.
    struct Placement: Sendable {
        var spotFolderID: String?
        var sessionAlbumID: String?
    }

    /// Adds `assetIdentifiers` to the All album and (when a spot + session are
    /// given) the session's album under Dive Free ▸ Spots ▸ <spot> ▸ <session>.
    static func mirror(
        assetIdentifiers: [String],
        spotName: String?,
        spotFolderID: String?,
        sessionName: String?,
        sessionAlbumID: String?
    ) async -> Placement {
        var result = Placement(spotFolderID: spotFolderID, sessionAlbumID: sessionAlbumID)
        guard !assetIdentifiers.isEmpty,
              await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized,
              let root = await findOrCreateFolder(title: rootTitle, parent: nil) else { return result }

        if let all = await findOrCreateAlbum(title: allTitle, parent: root) {
            await add(assetIdentifiers, to: all)
        }

        // Dive Free ▸ Spots ▸ <spot> ▸ <session>. Needs both a spot and a session.
        guard let spotName, let sessionName,
              let spots = await findOrCreateFolder(title: spotsTitle, parent: root) else { return result }

        // Reuse the stored folder/album (survives renames) before creating by name.
        var spotFolder = resolveList(result.spotFolderID)
        if spotFolder == nil { spotFolder = await findOrCreateFolder(title: spotName, parent: spots) }
        guard let spotFolder else { return result }
        result.spotFolderID = spotFolder.localIdentifier

        var sessionAlbum = resolveAlbum(result.sessionAlbumID)
        if sessionAlbum == nil { sessionAlbum = await findOrCreateAlbum(title: sessionName, parent: spotFolder) }
        guard let sessionAlbum else { return result }
        result.sessionAlbumID = sessionAlbum.localIdentifier
        await add(assetIdentifiers, to: sessionAlbum)
        return result
    }

    /// Renames a spot's folder to match an in-app rename (no-op if no folder yet).
    static func renameFolder(id: String, to title: String) async {
        guard let list = resolveList(id) else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest(for: list)?.title = title
        }
    }

    /// Renames a session's album to match an in-app title change (no-op if none).
    static func renameAlbum(id: String, to title: String) async {
        guard let album = resolveAlbum(id) else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    // MARK: - Lookups

    private static func resolveList(_ id: String?) -> PHCollectionList? {
        guard let id else { return nil }
        return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func resolveAlbum(_ id: String?) -> PHAssetCollection? {
        guard let id else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Children of `parent` — or the top-level user collections when nil. Filtered
    /// in Swift by title/type: `fetchTopLevelUserCollections` ignores a fetch
    /// predicate, so a predicate-based lookup would match an arbitrary collection.
    private static func children(of parent: PHCollectionList?) -> PHFetchResult<PHCollection> {
        if let parent { return PHCollectionList.fetchCollections(in: parent, options: nil) }
        return PHCollectionList.fetchTopLevelUserCollections(with: nil)
    }

    private static func existingFolder(titled title: String, in parent: PHCollectionList?) -> PHCollectionList? {
        var match: PHCollectionList?
        children(of: parent).enumerateObjects { collection, _, stop in
            if let list = collection as? PHCollectionList, list.localizedTitle == title {
                match = list
                stop.pointee = true
            }
        }
        return match
    }

    private static func existingAlbum(titled title: String, in parent: PHCollectionList) -> PHAssetCollection? {
        var match: PHAssetCollection?
        children(of: parent).enumerateObjects { collection, _, stop in
            if let album = collection as? PHAssetCollection, album.localizedTitle == title {
                match = album
                stop.pointee = true
            }
        }
        return match
    }

    /// Find-or-create a folder titled `title`; `parent` nil = top level, else nested.
    private static func findOrCreateFolder(title: String, parent: PHCollectionList?) async -> PHCollectionList? {
        if let existing = existingFolder(titled: title, in: parent) { return existing }
        var id: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
                let placeholder = request.placeholderForCreatedCollectionList
                id = placeholder.localIdentifier
                if let parent { PHCollectionListChangeRequest(for: parent)?.addChildCollections([placeholder] as NSArray) }
            }
        } catch {
            return nil
        }
        return resolveList(id)
    }

    /// Find-or-create an album titled `title` nested inside `parent`.
    private static func findOrCreateAlbum(title: String, parent: PHCollectionList) async -> PHAssetCollection? {
        if let existing = existingAlbum(titled: title, in: parent) { return existing }
        var id: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                let placeholder = request.placeholderForCreatedAssetCollection
                id = placeholder.localIdentifier
                PHCollectionListChangeRequest(for: parent)?.addChildCollections([placeholder] as NSArray)
            }
        } catch {
            return nil
        }
        return resolveAlbum(id)
    }

    private static func add(_ assetIdentifiers: [String], to album: PHAssetCollection) async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        // PhotoKit ignores assets already in the album, so no dedupe needed here.
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
        }
    }
}
