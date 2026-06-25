import Foundation
import os
import AVFoundation
import Photos
import UIKit

/// Reads originals from — and writes captures to — the user's Photos library for
/// the reference-based media model (#141). Media is referenced by
/// `PHAsset.localIdentifier`; the full image is fetched on demand rather than
/// copied into the app container.
@MainActor
enum PhotoLibrary {
    /// Requests read/write access; true when we can read (full or limited).
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// The asset for a stored identifier, or nil if it's no longer in the library.
    static func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// Full-resolution image for a stored identifier, or nil if missing/denied.
    static func fullImage(forIdentifier identifier: String) async -> UIImage? {
        guard let asset = asset(for: identifier) else { return nil }
        return await image(for: asset)
    }

    /// A thumbnail-sized image for caching at import time.
    static func thumbnail(for asset: PHAsset) async -> UIImage? {
        await image(for: asset, targetSize: CGSize(width: 800, height: 800))
    }

    /// Saves an image to the Photos library and returns the new asset's
    /// `localIdentifier` so it can be referenced. Requires add/read-write access.
    /// `nonisolated`: `performChanges` runs the block off the main actor, so it
    /// must not be actor-isolated (see `PhotoAlbum`).
    nonisolated static func save(_ image: UIImage) async -> String? {
        guard await requestAccess() else { return nil }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return nil
        }
        return identifier
    }

    /// Saves a captured video file to the Photos library; returns the new asset's
    /// `localIdentifier` so it can be referenced (#139). Requires add/write access.
    /// `nonisolated` for the same reason as `save`.
    nonisolated static func saveVideo(_ url: URL) async -> String? {
        guard await requestAccess() else { return nil }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                identifier = request?.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return nil
        }
        return identifier
    }

    /// An `AVPlayerItem` for a referenced video (#139), or nil if missing/denied.
    static func playerItem(forIdentifier identifier: String) async -> AVPlayerItem? {
        guard let asset = asset(for: identifier) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            let resumed = OSAllocatedUnfairLock(initialState: false)
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                let isFirst = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { continuation.resume(returning: item) }
            }
        }
    }

    /// Loads an image for `asset`. `requestImage` can deliver more than once
    /// (degraded then full); a lock ensures the continuation resumes exactly once.
    static func image(for asset: PHAsset, targetSize: CGSize = PHImageManagerMaximumSize) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            let resumed = OSAllocatedUnfairLock(initialState: false)
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, _ in
                let isFirst = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { continuation.resume(returning: image) }
            }
        }
    }
}
