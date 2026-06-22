import SwiftUI
import CoreGraphics

/// Renders emoji to images cropped to their visible ink, cached per emoji.
///
/// A raw `Text(emoji)` carries the font's line-box padding (mostly empty space
/// beneath the glyph), so centring it leaves the glyph floating above its point.
/// Cropping to the non-transparent pixels yields a tight image whose geometric
/// centre *is* the glyph's visual centre — so callers (the map annotations, the
/// depth-profile chart) can centre it exactly on a point without an empirical
/// offset.
@MainActor
enum EmojiInk {
    /// Cached results (including misses, stored as `nil`) keyed by emoji + size.
    private static var cache: [String: Image?] = [:]
    /// Apple Watch displays are @2x; render at that scale for crisp glyphs.
    private static let scale: CGFloat = 2

    static func image(_ emoji: String, fontSize: CGFloat) -> Image? {
        let key = "\(emoji)#\(fontSize)"
        if let cached = cache[key] { return cached }
        let rendered = render(emoji, fontSize: fontSize)
        cache[key] = rendered
        return rendered
    }

    private static func render(_ emoji: String, fontSize: CGFloat) -> Image? {
        let renderer = ImageRenderer(content: Text(emoji).font(.system(size: fontSize)))
        renderer.scale = scale
        guard let full = renderer.cgImage,
              let bounds = opaqueBounds(of: full),
              let cropped = full.cropping(to: bounds) else { return nil }
        return Image(decorative: cropped, scale: scale)
    }

    /// Pixel bounding box of the non-transparent pixels in `image`, or `nil` if
    /// it's fully transparent.
    private static func opaqueBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        return pixels.withUnsafeMutableBytes { raw -> CGRect? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                let row = y * bytesPerRow
                for x in 0..<w where raw[row + x * 4 + 3] > 10 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
}
