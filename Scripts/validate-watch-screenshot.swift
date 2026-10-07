// Reject captures of a dimmed Watch display or the system launch spinner.
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: validate-watch-screenshot.swift <PNG>…\n", stderr)
    exit(64)
}

for argument in CommandLine.arguments.dropFirst() {
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: argument))) else {
        throw NSError(domain: "WatchScreenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unreadable screenshot: \(argument)"])
    }
    var bright = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if max(colour.redComponent, colour.greenComponent, colour.blueComponent) > 0.8 { bright += 1 }
        }
    }
    // The captured app screens contain substantial bright text/controls. The
    // launch spinner and Always On display do not. This is a capture guard,
    // not a substitute for the locale/readiness probes or visual review.
    guard bright > bitmap.pixelsWide * bitmap.pixelsHigh / 200 else {
        fputs("Watch capture is dimmed or still loading: \(argument)\n", stderr)
        exit(2)
    }
}
