import Foundation
import Photos
import UIKit

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
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue,
            window.start as NSDate, window.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if !excludedIdentifiers.contains(asset.localIdentifier) { assets.append(asset) }
        }
        return assets
    }

    /// Loads a thumbnail via a callback — `requestImage` may fire twice (a
    /// degraded image then the full one), which simply refreshes the cell.
    @discardableResult
    static func requestThumbnail(for asset: PHAsset, targetSize: CGSize, _ completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        return PHImageManager.default().requestImage(
            for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
        ) { image, _ in completion(image) }
    }
}
