import Foundation
import UIKit

/// On-disk storage for session/spot photos — full JPEGs plus generated thumbnails
/// in the app container. Only file names are persisted (`PhotoRecord`); the bytes
/// live here, so no image blobs go into SwiftData.
enum PhotoStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    static func thumbnailURL(for fileName: String) -> URL { directory.appendingPathComponent("thumb_" + fileName) }

    /// Writes the full image and a thumbnail; returns the base file name, or `nil`
    /// if encoding/writing fails.
    static func save(_ image: UIImage) -> String? {
        let fileName = "\(UUID().uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url(for: fileName))
        } catch {
            return nil
        }
        if let thumbnail = image.preparingThumbnail(of: thumbnailSize(for: image.size))?.jpegData(compressionQuality: 0.8) {
            try? thumbnail.write(to: thumbnailURL(for: fileName))
        }
        return fileName
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        try? FileManager.default.removeItem(at: thumbnailURL(for: fileName))
    }

    static func image(for fileName: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: fileName).path)
    }

    /// The thumbnail, falling back to the full image if no thumbnail was written.
    static func thumbnail(for fileName: String) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(for: fileName).path) ?? image(for: fileName)
    }

    private static func thumbnailSize(for size: CGSize) -> CGSize {
        let maxDimension: CGFloat = 400
        let scale = min(maxDimension / max(size.width, 1), maxDimension / max(size.height, 1), 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
