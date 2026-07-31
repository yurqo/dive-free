import Foundation
import SwiftData
import Photos
import UniformTypeIdentifiers
import Domain
import Persistence

/// The iPhone-side glue for full backup & restore. Wraps Persistence's pure
/// ``BackupRestore`` engine with the impure edges it defers to the app — voice-note
/// audio bytes (``VoiceNoteStore``), photo thumbnails/originals (PhotoKit), and the
/// ZIP container (``ZipContainer``) — plus the file-handling concerns of producing a
/// shareable temp file (export) and reading a security-scoped `fileImporter` URL
/// (restore).
///
/// ## Export
///
/// A backup is a `.zip` of a `manifest.json` plus discrete media files. Metadata and
/// thumbnails always travel; heavy originals are opt-in per ``BackupExportOptions``.
/// Photo/video originals are resolved from the Photos library **before** staging (an
/// async pass that streams each original to a temp file via
/// `PHAssetResourceManager`, so a large video never loads into memory), then the
/// synchronous ``BackupRestore/stageArchive`` just moves those files into place and
/// ``ZipContainer/zip(directory:to:)`` packs the tree.
///
/// ## Restore — sync relink, async re-import
///
/// ``BackupRestore/restore(fromStagingDirectory:isTombstoned:materializeAudio:reimportPhoto:)``
/// runs on the main actor (SwiftData), so its `reimportPhoto` closure must be
/// synchronous. We do the cheap part there — **relink** a photo to the still-present
/// original by resolving its cloud identifier — and *defer* the expensive part: when
/// an original is missing but its bytes were bundled, we queue it and, in a second
/// async pass after `restore` returns, save it back to Photos (which is async) and
/// point the record at the new asset. That keeps the main thread free of PhotoKit
/// saves.
///
/// `@MainActor` because ``BackupRestore`` and the SwiftData `ModelContext` are
/// main-actor isolated.
@MainActor
enum BackupService {
    // MARK: - Result

    /// The outcome of a restore: Persistence's own counts plus the app-layer async
    /// photo re-import count and a flag for when re-import needed Photos access it
    /// didn't get.
    struct RestoreResult {
        var summary: BackupRestore.RestoreSummary
        /// Photos whose missing originals were re-imported into the Photos library in
        /// the async pass (distinct from relinks, which reuse an existing asset).
        var photosReimported: Int
        /// True when originals were bundled for missing photos but Photos add access
        /// was denied, so they could not be re-imported (metadata + thumbnail still
        /// restored).
        var photoAccessDenied: Bool
    }

    // MARK: - Export

    /// Builds a `.zip` backup of every session, spot, trip, and photo — always
    /// including metadata + thumbnails, and the heavy originals selected by `options`
    /// — and returns the file URL for the share sheet.
    ///
    /// `async` because resolving full-resolution photo/video originals from the Photos
    /// library is asynchronous (and may download iCloud-only originals). The file goes
    /// into its own unique temp subdirectory so the human-readable, date-stamped name
    /// can't collide with a concurrent or same-day export still in flight — **the caller
    /// owns that directory** and must delete it once sharing is finished.
    static func exportBackup(
        options: BackupExportOptions,
        context: ModelContext,
        progress: BackupProgressHandler? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = work.appendingPathComponent("staging", isDirectory: true)
        // Drop the staged tree once it has been packed. On success `work` survives
        // because the returned `.zip` lives in it; the caller owns it from there and must
        // delete it once the share sheet is done (see ``ExportBackupView``), since iOS
        // only reclaims `tmp` opportunistically and each export is potentially gigabytes.
        // On a throw — including a cancellation — there's no file to hand back, so `work`
        // goes too and a cancelled export leaves nothing behind.
        var succeeded = false
        defer {
            if succeeded {
                try? fm.removeItem(at: staging)
            } else {
                try? fm.removeItem(at: work)
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // The one thing only the app layer can supply: the on-disk thumbnail path (a
        // PhotoStore concern Persistence can't reach). The thumbnail *blob* is deliberately
        // not prefetched — `stageArchive` reads `record.thumbnailData` per record as it
        // goes, so holding every thumbnail in memory at once would buy nothing on a large
        // gallery.
        var thumbFileByID: [UUID: String] = [:]
        for record in try context.fetch(FetchDescriptor<PhotoRecord>()) where record.modelContext != nil {
            if let name = record.thumbnailFileName { thumbFileByID[record.id] = name }
        }

        // Stage everything in one async pass. The heavy work — resolving each original
        // out of Photos (which may download it from iCloud) — happens inside
        // `writePhotoMedia`, writing straight to its final staging path. An earlier
        // revision resolved every original into a `pending` directory first and then
        // moved the files in, purely because the staging closures were synchronous; with
        // async closures that whole pre-pass, its temp tree, and its duplicated
        // "does this toggle include this record" logic all disappear.
        try await BackupRestore(context: context).stageArchive(
            into: staging,
            appVersion: appVersion,
            options: options,
            progress: progress,
            audioBytes: { VoiceNoteStore.data(for: $0) },
            // Prefer the cached file; `stageArchive` falls back to the record's mirrored
            // `thumbnailData` when this returns nil.
            thumbnailBytes: { ref in
                guard let name = thumbFileByID[ref.id] else { return nil }
                return try? Data(contentsOf: PhotoStore.url(for: name))
            },
            // Metadata-only lookup (no bytes transferred), so naming the file costs
            // nothing beyond a local PhotoKit fetch.
            mediaFileExtension: { ref in originalExtension(for: ref) },
            writePhotoMedia: { ref, dest in await writeOriginal(for: ref, to: dest) }
        )

        // Pack the staging tree into a shareable `.zip` alongside it (outside the
        // staging dir so it isn't zipped into itself).
        //
        // Off the main actor: zipping walks and copies the entire staging tree, which
        // with originals bundled can be gigabytes and take minutes. Running it here
        // (a `@MainActor` context) would wedge the main thread for the whole pack —
        // the progress spinner would freeze and the watchdog would kill the app
        // (`0x8badf00d`). Only `URL`s (Sendable) cross into the task; the
        // `ModelContext` deliberately does not.
        try Task.checkCancellation()
        progress?(BackupProgress(phase: .compressing))
        let zipURL = work.appendingPathComponent("\(fileName()).zip")
        try await Task.detached { try ZipContainer.zip(directory: staging, to: zipURL) }.value
        progress?(BackupProgress(phase: .finished))

        // `staging`/`pending` are cleaned by the `defer` above; only the finished `.zip`
        // remains in `work`, which the caller deletes after sharing.
        succeeded = true
        return zipURL
    }

    /// Streams a photo/video's full-resolution original out of the Photos library into
    /// `directory`, returning the file it wrote (`<photoID>.<realExtension>`) or `nil`.
    ///
    /// Resolves the asset device-locally first, then via the cross-device cloud
    /// identifier. Uses `PHAssetResourceManager.writeData` so bytes go straight to disk (a
    /// large video never loads into memory) and allows network access so iCloud-only
    /// originals download. Returns `nil` on any failure/denied/deleted asset — never
    /// throws, so one bad photo can't fail the whole export.
    ///
    /// The extension comes from the `PHAssetResource` itself, because `writeData` emits
    /// the **original** bytes: a modern iPhone still is HEIC (or DNG/PNG), and plenty of
    /// clips are `.mp4`, not `.mov`. Labelling those `.jpg`/`.mov` used to make the
    /// restore-side re-import fail, silently discarding gigabytes of bundled originals.
    /// The original's real file extension, from a metadata-only PhotoKit lookup.
    ///
    /// Separate from ``writeOriginal(for:to:)`` because the staging engine has to *name*
    /// the file before it can ask for the bytes. `assetResources(for:)` reads the local
    /// database only — no download — so this is cheap enough to call per photo.
    private static func originalExtension(for ref: BackupRestore.PhotoRef) -> String? {
        guard let asset = resolveAsset(local: ref.assetIdentifier, cloud: ref.assetCloudIdentifier),
              let resource = primaryResource(PHAssetResource.assetResources(for: asset), isVideo: ref.isVideo)
        else { return nil }
        return fileExtension(of: resource, isVideo: ref.isVideo)
    }

    /// Streams one original out of Photos to `destination`, returning whether it landed.
    ///
    /// `writeData(for:toFile:)` streams to disk, so even a multi-GB video never sits in
    /// memory, and `isNetworkAccessAllowed` lets an iCloud-only original download. Any
    /// failure (asset deleted, access denied, network gone) returns `false` rather than
    /// throwing, so one unresolvable photo can't abort the whole export — the staging
    /// engine simply leaves `mediaFileName` nil for it.
    private static func writeOriginal(for ref: BackupRestore.PhotoRef, to destination: URL) async -> Bool {
        guard let asset = resolveAsset(local: ref.assetIdentifier, cloud: ref.assetCloudIdentifier),
              let resource = primaryResource(PHAssetResource.assetResources(for: asset), isVideo: ref.isVideo)
        else { return false }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: opts) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// The real file extension for a resource's bytes: the original filename's extension
    /// first (most faithful), then the extension preferred for its UTI, then the
    /// conventional fallback.
    private nonisolated static func fileExtension(of resource: PHAssetResource, isVideo: Bool) -> String {
        let fromName = (resource.originalFilename as NSString).pathExtension
        if !fromName.isEmpty { return fromName.lowercased() }
        if let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension {
            return ext.lowercased()
        }
        return isVideo ? "mov" : "jpg"
    }

    // MARK: - Restore

    /// Copies `source` to `destination` through an `NSFileCoordinator` read.
    ///
    /// The coordinated read is what makes restore work for a file the user picked out of
    /// iCloud Drive / a Files provider: it forces a not-yet-downloaded item to
    /// materialize and gives a consistent local snapshot, where a direct `FileHandle`
    /// open would fail. Any coordination or copy error is thrown so the caller surfaces
    /// it instead of the generic "couldn't restore".
    private nonisolated static func readCoordinated(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    /// Restore failures the app raises itself (as opposed to `ZipContainer.ZipError` /
    /// `BackupArchiveError`), surfaced with a specific message so a device-only failure
    /// isn't misreported as a corrupt file.
    enum RestoreError: LocalizedError {
        /// The security-scoped copy of the picked file came back empty or short.
        case incompleteRead(copied: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case let .incompleteRead(copied, expected):
                return String(
                    localized: "Couldn't read the backup file completely (\(copied) of \(expected) bytes). Move it to \"On My iPhone\" in Files and try again."
                )
            }
        }
    }

    /// A photo whose original was missing on restore but whose bytes were bundled — to
    /// be re-imported into Photos in the async pass after `restore` returns.
    private struct PendingReimport {
        var photoID: UUID
        var url: URL
        var isVideo: Bool
    }

    /// Restores a `.zip` backup picked from Files. Unzips it, applies the manifest
    /// additively (existing items kept, duplicates deduped by id), relinks photos whose
    /// originals still exist, and re-imports (into Photos) any whose originals are
    /// missing but were bundled.
    static func restoreBackup(from url: URL, context: ModelContext) async throws -> RestoreResult {
        // A `fileImporter` URL is security-scoped; without begin/stop access the read
        // fails on-device.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Kept alive until after the async re-import reads the bundled originals below.
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        // Copy the picked file into our own sandbox before we touch it, then work only on
        // that local copy. A `fileImporter` URL is security-scoped and can be presented by
        // a file provider; reading it directly with `FileHandle` (as `ZipContainer` does)
        // is what failed on device with a valid archive.
        //
        // The copy is done HERE, on the main actor, inside the
        // `startAccessingSecurityScopedResource()` window — deliberately NOT on a detached
        // thread. A previous revision copied on a `Task.detached`, and reading the scoped
        // URL from another thread produced an incomplete copy on device (which then
        // unzipped as "malformed") even though it worked in the simulator. Doing the read
        // where the scope is unambiguous fixes that. A plain file copy is light next to the
        // unzip/CRC that stays off-main below; a large media backup adds at most a few
        // seconds here, which is acceptable versus getting a broken copy.
        let localZip = temp.appendingPathComponent("backup.zip")
        let extracted = temp.appendingPathComponent("extracted", isDirectory: true)
        try readCoordinated(from: url, to: localZip)

        // Verify the copy is whole: if the scoped read gave us nothing (or a truncated
        // stub), fail with a clear, specific message rather than letting `unzip` report a
        // confusing "malformed" on a file that was really just not fully read.
        let sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let copiedSize = (try? localZip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard copiedSize > 0, sourceSize <= 0 || copiedSize == sourceSize else {
            throw RestoreError.incompleteRead(copied: copiedSize, expected: sourceSize)
        }

        // The heavy work — expanding the archive — stays off the main actor: a
        // multi-gigabyte backup would otherwise freeze the UI and invite a watchdog kill.
        // It reads our own local copy, so no security scope is involved here.
        try await Task.detached { try ZipContainer.unzip(localZip, to: extracted) }.value

        // Request Photos access up front so the synchronous relink inside `restore` can
        // resolve still-present originals (and the async re-import below can save).
        let photoAccess = await PhotoLibrary.requestAccess()

        // Resolve *every* cloud identifier in the manifest to a still-present local asset
        // in ONE batched pass, before `restore` runs. `restore`'s `reimportPhoto` closure
        // is synchronous and main-actor bound, so a per-photo lookup there would put
        // hundreds of sequential PhotoKit XPC round trips (plus a `PHAsset.fetchAssets`
        // each) on the main thread, uninterruptibly — a 400-photo restore would hang the
        // UI. Two batched calls replace 2N: cloud→local, then "which of those still
        // exist". The closure is then just a dictionary hit.
        let relinkByCloudID = photoAccess ? resolveRelinks(in: extracted) : [:]

        // Phase A — restore metadata + thumbnails; relink synchronously, queue the
        // missing-original re-imports for the async pass.
        var pending: [PendingReimport] = []
        let summary = try BackupRestore(context: context).restore(
            fromStagingDirectory: extracted,
            materializeAudio: { name, bytes in VoiceNoteStore.materialize(bytes, as: name) },
            reimportPhoto: { backup, mediaURL in
                if let cloud = backup.assetCloudIdentifier, let localID = relinkByCloudID[cloud] {
                    return localID
                }
                if let mediaURL {
                    pending.append(PendingReimport(photoID: backup.id, url: mediaURL, isVideo: backup.isVideo))
                }
                return nil
            }
        )

        // Phase B — re-import missing originals into Photos (async), then point each
        // record at the new asset and refresh its thumbnail.
        var reimported = 0
        if !pending.isEmpty, photoAccess {
            for item in pending {
                let localID = await PhotoLibrary.saveMedia(item.url, isVideo: item.isVideo)
                guard let localID, let record = fetchPhoto(id: item.photoID, context: context) else { continue }
                record.assetIdentifier = localID
                if let cloud = PhotoLibrary.cloudIdentifier(for: localID) {
                    record.assetCloudIdentifier = cloud
                }
                if let asset = PhotoLibrary.asset(for: localID),
                   let image = await PhotoLibrary.thumbnail(for: asset),
                   let saved = PhotoStore.saveThumbnail(image) {
                    record.thumbnailFileName = saved.fileName
                    record.thumbnailData = saved.data
                }
                reimported += 1
            }
            try? context.save()
        }

        return RestoreResult(
            summary: summary,
            photosReimported: reimported,
            photoAccessDenied: !photoAccess && !pending.isEmpty
        )
    }

    /// Maps every cloud identifier in the unzipped backup's manifest to a **still-present**
    /// local asset id on this device, in two batched PhotoKit calls regardless of how many
    /// photos the archive holds. Cloud ids that don't resolve here, or resolve to an asset
    /// that's been deleted since, are simply absent — those photos fall through to the
    /// bundled-bytes re-import path.
    ///
    /// The manifest is decoded a second time here (``BackupRestore/restore`` decodes it
    /// again for the import itself); it's a small JSON read and it keeps Persistence free
    /// of any relink concern.
    private static func resolveRelinks(in stagingDir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: stagingDir.appendingPathComponent("manifest.json")),
              let archive = try? BackupArchive.decode(data)
        else { return [:] }
        let cloudIDs = Array(Set(archive.photos.compactMap(\.assetCloudIdentifier)))
        let mapped = PhotoLibrary.localIdentifiers(forCloudIdentifiers: cloudIDs)
        let present = PhotoLibrary.existingLocalIdentifiers(Array(Set(mapped.values)))
        return mapped.filter { present.contains($0.value) }
    }

    // MARK: - Size estimate

    /// Estimates the size of a backup **split by category**, so the export UI can show the
    /// user what each toggle would add before committing.
    ///
    /// Every category is measured, regardless of which toggles are on: the per-category
    /// numbers don't depend on them, so the caller flips switches and re-sums
    /// (``BackupSizeEstimate/total(with:)``) instead of paying for another sweep.
    ///
    /// Photo/video originals are measured from `PHAssetResource` metadata **without
    /// downloading** iCloud-only bytes (with a dimension-based heuristic fallback), so
    /// the figure is approximate. The PhotoKit sizing runs off the main actor to keep
    /// the UI responsive across dozens of assets.
    static func estimatedSizes(context: ModelContext) async -> BackupSizeEstimate {
        // Baseline: thumbnails (prefer the cheap on-disk file size; fall back to the
        // mirrored blob) + a small flat manifest allowance.
        var base: Int64 = 4096  // rough manifest overhead
        var media: [MediaItem] = []
        for record in ((try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []) where record.modelContext != nil {
            if let name = record.thumbnailFileName {
                base += fileSize(at: PhotoStore.url(for: name))
            } else if let data = record.thumbnailData {
                base += Int64(data.count)
            }
            media.append(MediaItem(
                local: record.assetIdentifier,
                cloud: record.assetCloudIdentifier,
                isVideo: record.isVideo
            ))
        }

        // Voice notes: sum each referenced clip's on-disk size once.
        var voiceNotes: Int64 = 0
        var counted: Set<String> = []
        for session in ((try? context.fetch(FetchDescriptor<SessionRecord>())) ?? []) where session.modelContext != nil {
            for marker in (session.markers ?? []) {
                guard let name = marker.audioFileName, !counted.contains(name) else { continue }
                counted.insert(name)
                voiceNotes += fileSize(at: VoiceNoteStore.url(for: name))
            }
        }

        // Photo/video originals: measured off the main actor.
        let (photos, videos) = await Task.detached { computeMediaSizes(media) }.value

        return BackupSizeEstimate(base: base, voiceNotes: voiceNotes, photos: photos, videos: videos)
    }

    /// A PhotoKit-free, `Sendable` handle to a media asset for off-main sizing.
    private struct MediaItem: Sendable {
        var local: String?
        var cloud: String?
        var isVideo: Bool
    }

    /// Sums photo and video original sizes from `PHAssetResource` metadata (no
    /// download). Safe to run off the main actor — PhotoKit lookups are thread-safe.
    private nonisolated static func computeMediaSizes(_ items: [MediaItem]) -> (photos: Int64, videos: Int64) {
        var photos: Int64 = 0
        var videos: Int64 = 0
        for item in items {
            let size = originalSize(local: item.local, cloud: item.cloud, isVideo: item.isVideo)
            if item.isVideo { videos += size } else { photos += size }
        }
        return (photos, videos)
    }

    /// The original byte size of an asset without downloading it: `PHAssetResource`'s
    /// `fileSize`, falling back to a dimension-based heuristic when unavailable.
    private nonisolated static func originalSize(local: String?, cloud: String?, isVideo: Bool) -> Int64 {
        guard let asset = resolveAsset(local: local, cloud: cloud) else {
            return heuristicSize(width: 0, height: 0, isVideo: isVideo)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = primaryResource(resources, isVideo: isVideo),
           let size = resourceFileSize(resource), size > 0 {
            return size
        }
        return heuristicSize(width: asset.pixelWidth, height: asset.pixelHeight, isVideo: isVideo)
    }

    /// `PHAssetResource`'s byte count. There is no public API for it — the value lives on
    /// an undocumented `fileSize` property — so we probe for the accessor first and return
    /// `nil` when it isn't there. Without that guard, a future iOS renaming or dropping
    /// the property would make `value(forKey:)` raise `NSUnknownKeyException`, which Swift
    /// cannot catch: the app would simply crash the moment the export sheet opened.
    /// Returning `nil` instead falls through to ``heuristicSize(width:height:isVideo:)``.
    private nonisolated static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        let key = "fileSize"
        guard resource.responds(to: NSSelectorFromString(key)) else { return nil }
        return (resource.value(forKey: key) as? NSNumber)?.int64Value
    }

    /// A coarse size guess for an asset we can't measure exactly. Photos: ~half a byte
    /// per pixel (typical JPEG/HEIC). Videos: a flat, deliberately large placeholder
    /// (originals vary wildly and dominate the total).
    private nonisolated static func heuristicSize(width: Int, height: Int, isVideo: Bool) -> Int64 {
        if isVideo { return 25 * 1_000_000 }  // ~25 MB placeholder per clip
        let pixels = Int64(max(width, 1)) * Int64(max(height, 1))
        return max(pixels / 2, 300_000)
    }

    // MARK: - PhotoKit helpers

    /// Resolves a `PHAsset` from a device-local id first (fast), then the cross-device
    /// cloud identifier. `nonisolated` so it's usable from the off-main sizing pass;
    /// `PHAsset`/`PHPhotoLibrary` lookups are thread-safe.
    private nonisolated static func resolveAsset(local: String?, cloud: String?) -> PHAsset? {
        if let local, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject {
            return asset
        }
        if let cloud {
            let cloudID = PHCloudIdentifier(stringValue: cloud)
            let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [cloudID])
            if case let .success(localID)? = mapping[cloudID],
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject {
                return asset
            }
        }
        return nil
    }

    /// Picks the asset's primary original resource: the unedited photo/video, falling
    /// back to the full-size (possibly edited) variant, then the first resource.
    private nonisolated static func primaryResource(_ resources: [PHAssetResource], isVideo: Bool) -> PHAssetResource? {
        let primary: PHAssetResourceType = isVideo ? .video : .photo
        let fullSize: PHAssetResourceType = isVideo ? .fullSizeVideo : .fullSizePhoto
        return resources.first { $0.type == primary }
            ?? resources.first { $0.type == fullSize }
            ?? resources.first
    }

    // MARK: - Fetch / filesystem helpers

    private static func fetchPhoto(id: UUID, context: ModelContext) -> PhotoRecord? {
        var descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private nonisolated static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The app's marketing version (`CFBundleShortVersionString`), stored in the
    /// archive purely for information.
    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// A human-readable, date-stamped base filename: `DiveFree Backup 2026-07-24`.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "DiveFree Backup \(formatter.string(from: Date()))"
    }
}
