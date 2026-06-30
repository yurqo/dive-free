import Foundation
import UIKit

/// On-disk cache of small photo **thumbnails** in the app container. Full images
/// are never copied here — they're referenced in the Photos library and loaded on
/// demand (`PhotoLibrary`); this cache just backs a fast, offline gallery (#141).
/// Only the thumbnail file name is persisted (`PhotoRecord.thumbnailFileName`).
enum PhotoStore {
    /// Longest edge of a cached thumbnail, in points.
    static let maxThumbnailDimension: CGFloat = 400

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    /// Downscales `image` to a thumbnail and writes it; returns the file name, or
    /// `nil` if encoding/writing fails.
    /// Downscales `image` to a thumbnail, writes it, and returns the file name plus
    /// the JPEG bytes. The bytes are also stored on the `PhotoRecord` so the
    /// thumbnail syncs across devices via CloudKit (#169). Nil if encoding fails.
    static func saveThumbnail(_ image: UIImage) -> (fileName: String, data: Data)? {
        let fileName = "\(UUID().uuidString).jpg"
        guard let data = downscaled(image).jpegData(compressionQuality: 0.8) else { return nil }
        do {
            try data.write(to: url(for: fileName))
        } catch {
            return nil
        }
        return (fileName, data)
    }

    static func delete(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Reads and decodes a cached thumbnail off the main thread (keeps gallery
    /// scrolling smooth — the decode would otherwise run on the main actor).
    static func thumbnailPrepared(for fileName: String?, fallbackData: Data? = nil) async -> UIImage? {
        // Prefer the cached file. On a device that doesn't have it yet (synced from
        // elsewhere), fall back to the CloudKit-mirrored bytes and materialize the
        // file for next time (#169).
        if let fileName, FileManager.default.fileExists(atPath: url(for: fileName).path) {
            let path = url(for: fileName).path
            if let image = await Task.detached(priority: .userInitiated, operation: {
                UIImage(contentsOfFile: path)
            }).value {
                return await image.byPreparingForDisplay()
            }
        }
        guard let fallbackData else { return nil }
        if let fileName { try? fallbackData.write(to: url(for: fileName)) }
        guard let image = await Task.detached(priority: .userInitiated, operation: {
            UIImage(data: fallbackData)
        }).value else { return nil }
        return await image.byPreparingForDisplay()
    }

    /// A downscaled copy bounded by `maxThumbnailDimension`. Never returns the
    /// original at full size — that would bloat the cache, defeating the
    /// reference-based storage model (#141).
    private static func downscaled(_ image: UIImage) -> UIImage {
        let targetSize = thumbnailSize(for: image.size)
        if let prepared = image.preparingThumbnail(of: targetSize) { return prepared }
        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func thumbnailSize(for size: CGSize) -> CGSize {
        let scale = min(maxThumbnailDimension / max(size.width, 1), maxThumbnailDimension / max(size.height, 1), 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
