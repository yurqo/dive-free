import Foundation
import os
import Photos
import SwiftData
import Persistence

/// Idempotent repair pass that fills in the cross-device media fields (#169) for
/// photos that are missing them: the stable `assetCloudIdentifier` and the
/// CloudKit-mirrored `thumbnailData`. Two kinds of records need it —
///
/// 1. photos attached **before** those fields existed (carry only a device-local
///    `assetIdentifier`, useless on another device), and
/// 2. recently added photos whose `PHCloudIdentifier` wasn't available yet at
///    import time (a freshly imported asset has none until iCloud Photos uploads
///    it), so the eager capture stored `nil`.
///
/// It only does work on the device that still holds the originals (the iPhone);
/// on a device without them the local ids don't resolve, so it's a safe no-op.
/// Once it saves, CloudKit pushes the filled-in fields and the other device can
/// show the thumbnail (always) and the full image (when iCloud Photos can
/// translate the cloud id). Mirrors the location/weather backfills.
@MainActor
enum PhotoBackfill {
    private static let log = Logger(subsystem: "org.yurko.divefree", category: "PhotoBackfill")

    static func run(in context: ModelContext) async {
        // Only when the user has ALREADY granted access — never prompt at launch
        // for this background repair (a permission dialog belongs in a photo flow).
        guard PhotoLibrary.hasReadAccess() else { return }

        let records: [PhotoRecord]
        do {
            records = try context.fetch(FetchDescriptor<PhotoRecord>())
        } catch {
            log.error("fetch failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Records we have a local reference for that still miss a cross-device field.
        // Guard modelContext != nil — a row deleted elsewhere traps on access (#148).
        let pending = records.filter {
            $0.modelContext != nil && $0.assetIdentifier != nil
                && ($0.assetCloudIdentifier == nil || $0.thumbnailData == nil)
        }
        guard !pending.isEmpty else { return }

        // One batched lookup for every missing cloud id (the per-id call is costly).
        let needCloudID = pending.filter { $0.assetCloudIdentifier == nil }.compactMap(\.assetIdentifier)
        let cloudByLocal = PhotoLibrary.cloudIdentifiers(forLocalIdentifiers: needCloudID)

        var changed = false
        for record in pending where record.modelContext != nil {
            guard let id = record.assetIdentifier else { continue }

            if record.assetCloudIdentifier == nil, let cloud = cloudByLocal[id] {
                record.assetCloudIdentifier = cloud
                changed = true
            }

            if record.thumbnailData == nil, await backfillThumbnail(record, localID: id) {
                changed = true
            }
        }

        guard changed else { return }
        do {
            try context.save()
            log.notice("backfilled cross-device fields for \(pending.count, privacy: .public) photo(s)")
        } catch {
            log.error("save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Populates `thumbnailData` so the preview syncs: prefer the bytes of an
    /// already-cached local thumbnail (cheap, survives a deleted original); else
    /// regenerate from the library asset. Returns whether anything changed.
    private static func backfillThumbnail(_ record: PhotoRecord, localID: String) async -> Bool {
        if let file = record.thumbnailFileName,
           let data = try? Data(contentsOf: PhotoStore.url(for: file)) {
            record.thumbnailData = data
            return true
        }
        guard let asset = PhotoLibrary.asset(for: localID),
              let thumb = await PhotoLibrary.thumbnail(for: asset),
              let saved = PhotoStore.saveThumbnail(thumb) else { return false }
        record.thumbnailFileName = saved.fileName
        record.thumbnailData = saved.data
        return true
    }
}
