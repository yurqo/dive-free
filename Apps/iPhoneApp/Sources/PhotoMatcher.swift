import Foundation
import Photos

/// Finds camera-roll photos whose capture time falls within a dive's window, for
/// the timestamp auto-suggest (#126). Read access only; it suggests — the user
/// confirms before anything is imported.
@MainActor
enum PhotoMatcher {
    /// Buffer around the dive for surface shots taken just before/after it.
    static let defaultBuffer: TimeInterval = 15 * 60

    /// The capture-time window to search: the dive ± a buffer.
    static func window(start: Date, end: Date, buffer: TimeInterval = defaultBuffer) -> DateInterval {
        let from = start.addingTimeInterval(-buffer)
        let to = max(from, end.addingTimeInterval(buffer))
        return DateInterval(start: from, end: to)
    }

    /// Requests read access; returns true when we can read (full or limited).
    static func requestReadAccess() async -> Bool {
        await PhotoLibrary.requestAccess()
    }

    /// Image assets created within `window`, excluding `excludedIdentifiers`
    /// (already-attached assets), oldest first.
    static func mediaAssets(in window: DateInterval, excluding excludedIdentifiers: Set<String>) -> [PHAsset] {
        assets(withIdentifiers: matchingIdentifiers(in: window, excluding: excludedIdentifiers))
    }

    /// Local identifiers of in-window image/video assets, oldest first, minus the
    /// excluded ones. `nonisolated` + returns `Sendable` ids so the (slow, on a big
    /// library) `PHAsset.fetchAssets` can run **off the main thread** — the caller
    /// then materializes the assets on the main actor.
    nonisolated static func matchingIdentifiers(in window: DateInterval, excluding excludedIdentifiers: Set<String>) -> [String] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue,
            window.start as NSDate, window.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        result.enumerateObjects { asset, _, _ in
            if !excludedIdentifiers.contains(asset.localIdentifier) { ids.append(asset.localIdentifier) }
        }
        return ids
    }

    /// Materializes assets for `identifiers`, preserving order.
    static func assets(withIdentifiers identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return identifiers.compactMap { byID[$0] }
    }

    /// Whether the current read access is limited (only selected photos visible),
    /// which makes the scan miss un-selected shots — the likely cause of a "0
    /// matches" when a photo really was taken during the dive.
    static var accessIsLimited: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }
}
