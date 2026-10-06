import AppKit

// simctl --mask=ignored preserves the rectangular framebuffer, but writes RGBA.
// Convert its opaque pixels to RGB for App Store Connect without masking corners.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/opaque-screenshot.swift capture.png\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = NSBitmapImageRep(data: try Data(contentsOf: url)),
      let image = source.cgImage,
      let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
          pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: canvas),
      let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
          pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 3,
          hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 24) else {
    fputs("Cannot read screenshot: \(url.path)\n", stderr); exit(1)
}
let rect = CGRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
context.cgContext.setFillColor(CGColor(gray: 1, alpha: 1))
context.cgContext.fill(rect)
context.cgContext.draw(image, in: rect)
let pixels = canvas.bitmapData!, rgb = output.bitmapData!
for y in 0..<source.pixelsHigh { for x in 0..<source.pixelsWide {
    let offset = y * canvas.bytesPerRow + x * 4
    guard pixels[offset + 3] == 255 else {
        fputs("Screenshot contains transparent pixels: \(url.path)\n", stderr); exit(1)
    }
    let destination = y * output.bytesPerRow + x * 3
    for channel in 0..<3 { rgb[destination + channel] = pixels[offset + channel] }
} }
guard let data = output.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: url, options: .atomic)
