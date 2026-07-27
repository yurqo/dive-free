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

    /// Current read authorization **without prompting** — for background work that
    /// must not trigger the permission dialog outside a user-initiated flow (e.g.
    /// the launch-time backfill). True only once the user has already granted access.
    static func hasReadAccess() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// The asset for a stored identifier, or nil if it's no longer in the library.
    static func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// Full-resolution image for a stored identifier, or nil if missing/denied.
    static func fullImage(forIdentifier identifier: String?, orCloudIdentifier cloudID: String? = nil) async -> UIImage? {
        if let identifier, let asset = asset(for: identifier) { return await image(for: asset) }
        // The local id is device-specific; on another device, resolve via the
        // stable CloudKit-synced cloud identifier (#169).
        if let cloudID, let localID = localIdentifier(forCloudIdentifier: cloudID),
           let asset = asset(for: localID) {
            return await image(for: asset)
        }
        return nil
    }

    /// `PHCloudIdentifier.stringValue` for a local asset id, for cross-device
    /// reference (#169). Best-effort: nil if unavailable or not in iCloud Photos.
    static func cloudIdentifier(for localIdentifier: String?) -> String? {
        guard let localIdentifier else { return nil }
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localIdentifier])
        guard case let .success(cloudID)? = mapping[localIdentifier] else { return nil }
        return cloudID.stringValue
    }

    /// Batched `cloudIdentifier(for:)` — maps each resolvable local id to its
    /// `PHCloudIdentifier.stringValue` in a single lookup (the per-id call is
    /// expensive, so the backfill resolves the whole set at once). Local ids with
    /// no cloud counterpart (not yet in iCloud Photos) are omitted (#169).
    static func cloudIdentifiers(forLocalIdentifiers localIdentifiers: [String]) -> [String: String] {
        guard !localIdentifiers.isEmpty else { return [:] }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        var result: [String: String] = [:]
        for (local, outcome) in mappings {
            if case let .success(cloudID) = outcome { result[local] = cloudID.stringValue }
        }
        return result
    }

    /// The local asset id for a stored cloud identifier on this device, or nil (#169).
    static func localIdentifier(forCloudIdentifier cloudID: String) -> String? {
        let cloud = PHCloudIdentifier(stringValue: cloudID)
        let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [cloud])
        guard case let .success(localID)? = mapping[cloud] else { return nil }
        return localID
    }

    /// Batched ``localIdentifier(forCloudIdentifier:)`` — resolves a whole set of cloud
    /// identifiers to this device's local asset ids in a single lookup. Same rationale as
    /// ``cloudIdentifiers(forLocalIdentifiers:)``: the per-id call is an XPC round trip,
    /// so a restore resolves the archive's entire photo set at once instead of once per
    /// photo on the main thread. Cloud ids with no counterpart here are omitted.
    static func localIdentifiers(forCloudIdentifiers cloudIDs: [String]) -> [String: String] {
        guard !cloudIDs.isEmpty else { return [:] }
        let clouds = cloudIDs.map { PHCloudIdentifier(stringValue: $0) }
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: clouds)
        var result: [String: String] = [:]
        for (cloud, outcome) in mappings {
            if case let .success(localID) = outcome { result[cloud.stringValue] = localID }
        }
        return result
    }

    /// Which of `localIdentifiers` still resolve to an asset in the library, in one fetch
    /// rather than one per id. Comparison ignores the `/L0/001` suffix PhotoKit appends,
    /// so a canonicalized id still matches the one that was asked about.
    static func existingLocalIdentifiers(_ localIdentifiers: [String]) -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var found: Set<Substring> = []
        assets.enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier.prefix { $0 != "/" })
        }
        return Set(localIdentifiers.filter { found.contains($0.prefix { $0 != "/" }) })
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

    /// Saves a media *file* (a captured clip, or a full-resolution original bundled in a
    /// backup) to the Photos library and returns the new asset's `localIdentifier`.
    /// Unlike ``save(_:)`` this ingests the file bytes directly rather than re-encoding a
    /// `UIImage`, preserving the original. Requires add/write access. `nonisolated` for
    /// the same reason as ``save(_:)``.
    ///
    /// Uses `PHAssetCreationRequest.addResource(with:fileURL:options:)` rather than the
    /// `creationRequestForAssetFrom{Image,Video}(atFileURL:)` pair, which has been
    /// deprecated since iOS 9 and returns `nil` — losing the asset silently — when it
    /// can't make sense of the file. `addResource` takes the bytes as the resource kind
    /// we name and reads the format from the data itself, so a HEIC/DNG/PNG still or an
    /// `.mp4` clip ingests exactly as it left the library.
    nonisolated static func saveMedia(_ url: URL, isVideo: Bool) async -> String? {
        guard await requestAccess() else { return nil }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return nil
        }
        return identifier
    }

    /// Saves a captured video file to the Photos library (#139).
    nonisolated static func saveVideo(_ url: URL) async -> String? {
        await saveMedia(url, isVideo: true)
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
