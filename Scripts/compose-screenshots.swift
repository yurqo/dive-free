import AppKit
import CryptoKit

// Deterministic compositor. Input screenshots are real simulator captures.
let args = Array(CommandLine.arguments.dropFirst())
let verify = args.contains("--verify")
let root = URL(fileURLWithPath: args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "screenshots")
let selectedLocale = args.firstIndex(of: "--locale").map { index -> String in
    guard args.indices.contains(index + 1) else { fail("--locale requires a language") }
    return args[index + 1]
}
let captions: [String: [String]] = [
    "en": ["Record freedives on Apple Watch.", "Relive every dive on your iPhone and iPad."],
    "en-GB": ["Record freedives on Apple Watch.", "Relive every dive on your iPhone and iPad."],
    "es": ["Registra apneas con Apple Watch.", "Revive cada inmersión en tu iPhone y iPad."],
    "fr": ["Plongées en apnée sur Apple Watch.", "Revivez chaque plongée sur votre iPhone et iPad."],
    "it": ["Registra apnee con Apple Watch.", "Rivivi ogni immersione sul tuo iPhone e iPad."],
    "de": ["Freitauchgänge auf der Apple Watch.", "Erlebe jeden Tauchgang auf deinem iPhone und iPad neu."],
    "pt-BR": ["Registre apneias com Apple Watch.", "Reviva cada mergulho no seu iPhone e iPad."],
    "ja": ["Apple Watchでフリーダイブを記録。", "すべてのダイビングをiPhoneとiPadでもう一度。"],
    "uk": ["Записуйте занурення на Apple Watch.", "Переживіть кожне занурення знову на вашому iPhone та iPad."]
]
func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    var fontSize = size
    while fontSize > 24 {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .paragraphStyle: paragraph]
        let bounds = (text as NSString).size(withAttributes: attrs)
        if bounds.width <= rect.width && bounds.height <= rect.height { break }; fontSize -= 1
    }
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color, .paragraphStyle: paragraph])
}
// Apple does not publish a numeric iPhone 18 display corner radius in its tech
// specs. Match the actual iPhone 17 Pro Max capture instead: its Xcode display
// mask uses a continuous curve, with a 255.49 px corner extent at 1320 px wide.
// This extent is not a circular radius. Keep the profile deterministic here.
func phoneOutline(_ rect: NSRect, extent: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let corner: [[CGFloat]] = [
        [0, 239.029, 0.05214832, 223.0626, 0.6450521, 207.0927],
        [1.329782, 188.6379, 2.729851, 170.3905, 6.124027, 152.1771],
        [12.97926, 115.3831, 27.86308, 81.91631, 54.88838, 54.89101],
        [81.91141, 27.86798, 115.3736, 12.98416, 152.1643, 6.12666],
        [170.3912, 2.730217, 188.6511, 1.329014, 207.1184, 0.6454173],
        [223.2426, 0.0482623, 239.3633, 0, 255.4889, 0]
    ]
    for turn in 0..<4 {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let x = x / 255.4889 * extent, y = y / 255 * extent
            switch turn {
            case 0: return NSPoint(x: rect.minX + x, y: rect.minY + y)
            case 1: return NSPoint(x: rect.maxX - y, y: rect.minY + x)
            case 2: return NSPoint(x: rect.maxX - x, y: rect.maxY - y)
            default: return NSPoint(x: rect.minX + y, y: rect.maxY - x)
            }
        }
        let start = point(0, 255)
        if turn == 0 { path.move(to: start) } else { path.line(to: start) }
        for c in corner {
            path.curve(to: point(c[4], c[5]), controlPoint1: point(c[0], c[1]), controlPoint2: point(c[2], c[3]))
        }
    }
    path.close()
    return path
}
// Apple Watch Ultra 3 (49mm) framebuffer mask from Xcode's device profile:
// 0CC6C6F9-426F-454C-B501-BD71F13AF4B5.pdf, native 422 × 514 px.
// The complete continuous outline has no single circular corner radius.
func watchOutline(_ rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + x / 422 * rect.width, y: rect.minY + y / 514 * rect.height)
    }
    path.move(to: point(421.7509, 366.0628))
    let curves: [[CGFloat]] = [
        [421.4388, 388.111, 420.6699, 403.2213, 418.6618, 416.5724],
        [416.6583, 429.9189, 413.3567, 441.5377, 408.3002, 452.2158],
        [403.2755, 462.8351, 396.5863, 472.3147, 388.4499, 480.4511],
        [380.318, 488.5829, 370.8338, 495.272, 360.2144, 500.3012],
        [349.5136, 505.3667, 337.9263, 508.6456, 324.6159, 510.6627],
        [311.3461, 512.6754, 296.4754, 513.4306, 278.4522, 513.7472],
        [262.1568, 514.0322, 237.1505, 514, 211, 514],
        [184.845, 514, 159.8432, 514.0322, 143.5478, 513.7472],
        [125.5201, 513.4306, 110.6539, 512.6754, 97.3796, 510.6627],
        [84.07368, 508.6456, 72.48641, 505.3667, 61.78107, 500.3012],
        [51.16166, 495.272, 41.68199, 488.5829, 33.55009, 480.4511],
        [25.41367, 472.3147, 18.72453, 462.8351, 13.69976, 452.2158],
        [8.643335, 441.5377, 5.341731, 429.9189, 3.333632, 416.5724],
        [1.325534, 403.2213, 0.5611896, 388.111, 0.2491202, 366.0628],
        [0.09082411, 354.946, 0.04107391, 341.3417, 0.01846018, 324.1328],
        [0, 306.752, 0, 285.3687, 0, 257.0023],
        [0, 228.6358, 0, 207.2525, 0.01846018, 189.8672],
        [0.04107391, 172.6583, 0.09082411, 159.0585, 0.2491202, 147.9372],
        [0.5611896, 125.889, 1.325534, 110.7832, 3.333632, 97.42763],
        [5.341731, 84.08564, 8.643335, 72.46229, 13.69976, 61.78418],
        [18.72453, 51.16487, 25.41367, 41.68527, 33.55009, 33.55345],
        [41.68199, 25.4171, 51.16166, 18.72802, 61.78107, 13.70329],
        [72.48641, 8.63334, 84.07368, 5.3589, 97.3796, 3.337251],
        [110.6539, 1.324647, 125.5201, 0.5693548, 143.5478, 0.2527654],
        [159.8432, -0.03216505, 184.845, 0, 211, 0],
        [237.1505, 0, 262.1568, -0.03216505, 278.4522, 0.2527654],
        [296.4754, 0.5693548, 311.3461, 1.324647, 324.6159, 3.337251],
        [337.9263, 5.3589, 349.5136, 8.63334, 360.2144, 13.70329],
        [370.8338, 18.72802, 380.318, 25.4171, 388.4499, 33.55345],
        [396.5863, 41.68527, 403.2755, 51.16487, 408.3002, 61.78418],
        [413.3567, 72.46229, 416.6583, 84.08564, 418.6618, 97.42763],
        [420.6699, 110.7832, 421.4388, 125.889, 421.7509, 147.9372],
        [421.9047, 159.0585, 421.9589, 172.6583, 421.9815, 189.8672],
        [422, 207.2525, 422, 228.6358, 422, 257.0023],
        [422, 285.3687, 422, 306.752, 421.9815, 324.1328],
        [421.9589, 341.3417, 421.9047, 354.946, 421.7509, 366.0628],
    ]
    for c in curves {
        path.curve(to: point(c[4], c[5]), controlPoint1: point(c[0], c[1]), controlPoint2: point(c[2], c[3]))
    }
    path.close()
    return path
}
func device(_ image: NSImage, rect: NSRect, phone: Bool = false, tablet: Bool = false, shadow: Bool = false) {
    func outline(_ bounds: NSRect) -> NSBezierPath {
        if tablet {
            return NSBezierPath(roundedRect: bounds, xRadius: bounds.width * 0.055, yRadius: bounds.width * 0.055)
        }
        return phone ? phoneOutline(bounds, extent: bounds.width * 255.4889 / 1320) : watchOutline(bounds)
    }
    let screen = outline(rect)
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: -10, height: -14); shadow.set()
    }
    NSColor(white: 0.08, alpha: 1).set()
    // A uniform 14 px border follows the actual display curve.
    screen.fill(); screen.lineWidth = 28; screen.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}
func attachment(_ folder: URL, prefix: String) throws -> URL {
    let manifest = folder.appendingPathComponent("manifest.json")
    let groups = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]] ?? []
    let attachments = groups.flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
    guard let entry = attachments.first(where: { ($0["suggestedHumanReadableName"] as? String)?.hasPrefix(prefix + "_") == true }),
          let filename = entry["exportedFileName"] as? String,
          filename == URL(fileURLWithPath: filename).lastPathComponent else {
        fail("Missing \(prefix) capture in \(folder.path); recapture with --ios")
    }
    return folder.appendingPathComponent(filename)
}
func checkedImage(_ url: URL, width: Int, height: Int) throws -> NSImage {
    guard let pixels = NSBitmapImageRep(data: try Data(contentsOf: url)),
          pixels.pixelsWide == width, pixels.pixelsHigh == height,
          let image = NSImage(contentsOf: url) else { fail("Unexpected source dimensions: \(url.path)") }
    return image
}
func validateRegularCaptures(_ folder: URL, width: Int, height: Int) throws {
    for slug in ["01-dives", "02-detail", "03-trips", "04-spots", "05-passport"] {
        let url = try attachment(folder, prefix: slug)
        guard let pixels = NSBitmapImageRep(data: try Data(contentsOf: url)),
              pixels.pixelsWide == width, pixels.pixelsHigh == height, !pixels.hasAlpha else {
            fail("Invalid regular screenshot size/transparency: \(url.path)")
        }
        for point in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            guard let color = pixels.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB),
                  max(color.redComponent, color.greenComponent, color.blueComponent) > 0.05 else {
                fail("Black display mask baked into \(url.path). Recapture the rectangular framebuffer with --mask=ignored.")
            }
        }
    }
}
func compose(_ locale: String, tablet: Bool) throws {
    let folder = root.appendingPathComponent(locale)
    let phone = folder.appendingPathComponent("iPhone 17 Pro Max")
    let pad = folder.appendingPathComponent("iPad Pro 13-inch (M5)")
    if verify {
        try validateRegularCaptures(phone, width: 1320, height: 2868)
        if tablet { try validateRegularCaptures(pad, width: 2064, height: 2752) }
    }
    let inputPhone = try attachment(phone, prefix: "90-hero-dive-profile")
    let inputWatch = folder.appendingPathComponent("Apple Watch Ultra 3 (49mm)/01-live.png")
    let outputFolder = tablet ? pad : phone
    let output = outputFolder.appendingPathComponent(tablet ? "00-ipad-iphone-watch.png" : "00-watch-and-iphone.png")
    let receipt = outputFolder.appendingPathComponent("composite.json")
    let phoneImage = try checkedImage(inputPhone, width: 1320, height: 2868)
    let watchImage = try checkedImage(inputWatch, width: 422, height: 514)
    var fingerprints = ["locale": locale, "phone": try hash(inputPhone), "watch": try hash(inputWatch),
                        "manifest": try hash(phone.appendingPathComponent("manifest.json")),
                        "renderer": try hash(URL(fileURLWithPath: CommandLine.arguments[0]))]
    var padImage: NSImage?
    if tablet {
        let inputPad = try attachment(pad, prefix: "90-hero-dive-profile")
        padImage = try checkedImage(inputPad, width: 2064, height: 2752)
        fingerprints["ipad"] = try hash(inputPad)
        fingerprints["ipadManifest"] = try hash(pad.appendingPathComponent("manifest.json"))
    }
    let width = tablet ? 2064 : 1320
    let height = tablet ? 2752 : 2868
    if verify {
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipt))
        fingerprints["output"] = try hash(output)
        guard saved == fingerprints else { fail("Stale composite: \(output.path); run --compose-only") }
        guard let pixels = NSBitmapImageRep(data: try Data(contentsOf: output)),
              pixels.pixelsWide == width, pixels.pixelsHigh == height, !pixels.hasAlpha else {
            fail("Invalid composite dimensions or transparency: \(output.path)")
        }
        return
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("Cannot create composite") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor(red: 0.025, green: 0.12, blue: 0.18, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    if tablet, let padImage {
        drawText(captions[locale]![0], rect: NSRect(x: 80, y: 2625, width: 1904, height: 100), size: 106, color: .white)
        drawText(captions[locale]![1], rect: NSRect(x: 90, y: 2520, width: 1884, height: 75), size: 58, color: NSColor(white: 0.82, alpha: 1))
        let padWidth: CGFloat = 1764
        let phoneWidth = padWidth * (1320 / 460.0) / (2064 / 264.0)
        let phoneRect = NSRect(x: 2064 - 220 - phoneWidth, y: 230, width: phoneWidth, height: phoneWidth * 2868 / 1320)
        let watchWidth = phoneWidth * (422 / 326.0) / (1320 / 460.0)
        device(padImage, rect: NSRect(x: 150, y: 115, width: padWidth, height: padWidth * 2752 / 2064), tablet: true)
        device(phoneImage, rect: phoneRect, phone: true, shadow: true)
        device(watchImage, rect: NSRect(x: phoneRect.maxX - 55 - watchWidth, y: phoneRect.minY + 65, width: watchWidth, height: watchWidth * 514 / 422), shadow: true)
    } else {
        drawText(captions[locale]![0], rect: NSRect(x: 65, y: 2705, width: 1190, height: 120), size: 88, color: .white)
        drawText(captions[locale]![1], rect: NSRect(x: 95, y: 2600, width: 1130, height: 80), size: 48, color: NSColor(white: 0.82, alpha: 1))
        let phoneMargin: CGFloat = 92.5
        let phoneWidth: CGFloat = 1320 - 2 * phoneMargin
        let watchWidth = phoneWidth * (422 / 326.0) / (1320 / 460.0)
        let watchInset = 70 * phoneWidth / 850
        let watchMargin = phoneMargin + watchInset
        device(phoneImage, rect: NSRect(x: phoneMargin, y: phoneMargin, width: phoneWidth, height: phoneWidth * 2868 / 1320), phone: true)
        device(watchImage, rect: NSRect(x: 1320 - watchMargin - watchWidth, y: watchMargin, width: watchWidth, height: watchWidth * 514 / 422), shadow: true)
    }
    NSGraphicsContext.restoreGraphicsState()
    let rgb = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 24)!
    let sourcePixels = bitmap.bitmapData!, destinationPixels = rgb.bitmapData!
    let sourceStride = bitmap.bytesPerRow, destinationStride = rgb.bytesPerRow
    for y in 0..<height { for x in 0..<width {
        let source = y * sourceStride + x * 4
        let destination = y * destinationStride + x * 3
        for c in 0..<3 { destinationPixels[destination + c] = sourcePixels[source + c] }
    } }
    guard let png = rgb.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    try png.write(to: output, options: .atomic)
    fingerprints["output"] = try hash(output)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fingerprints).write(to: receipt, options: .atomic)
    print(output.path)
}
do {
    let locales = selectedLocale.map { [$0] } ?? captions.keys.sorted()
    for locale in locales {
        guard captions[locale] != nil else { fail("Unsupported locale: \(locale)") }
        try compose(locale, tablet: false)
        try compose(locale, tablet: true)
    }
} catch { fail("Composite failed: \(error)") }
