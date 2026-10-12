// Reject empty launch/navigation frames before screenshots can be staged.
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: validate-ios-screenshot.swift <PNG>…\n", stderr)
    exit(64)
}
var failed = false
for path in CommandLine.arguments.dropFirst() {
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else {
        fputs("Unreadable iOS screenshot: \(path)\n", stderr)
        failed = true
        continue
    }
    // Ignore status/navigation transitions at the edges. Sample a grid so the
    // check is cheap even for all localized 13-inch iPad captures. Real screens
    // have text or controls spread over the content, not just a status bar.
    var occupied = Set<Int>()
    var bright = 0
    let topInset = bitmap.pixelsHigh > bitmap.pixelsWide * 2 ? 0.1 : 0.04
    for row in 0..<320 {
        let y = Int(Double(bitmap.pixelsHigh) * (topInset + Double(row) / 320 * (0.9 - topInset)))
        for column in 0..<240 {
            let x = bitmap.pixelsWide * (column + 2) / 244
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let level = (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
            if level < 0.8 { occupied.insert((row / 20) * 12 + column / 20) }
            if level > 0.85 { bright += 1 }
        }
    }
    if occupied.count < 8 || bright < 768 {
        fputs("iOS capture is blank or still loading (\(occupied.count) content cells): \(path)\n", stderr)
        failed = true
    }
}
exit(failed ? 2 : 0)
