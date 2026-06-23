import Foundation
import WatchKit

/// Digital-crown scroll haptics (#149): a light tick as each item is crossed,
/// with a distinct chime at the ends of travel — the "r-r-r…Tinggg" feel.
///
/// watchOS exposes only preset `WKHapticType`s (no amplitude control; CoreHaptics
/// custom patterns are iOS-only), so a true intensity *ramp* isn't possible — we
/// approximate with a light per-item `.click` and a `.success` chime at the ends.
/// Ticks are throttled so a fast spin doesn't machine-gun the Taptic engine.
@MainActor
enum CrownHaptics {
    private static var lastTick = Date.distantPast
    /// Minimum gap between ticks (fast spins otherwise buzz continuously).
    private static let minTickInterval: TimeInterval = 0.04

    /// Crossing into a new item mid-scroll.
    static func tick() {
        let now = Date()
        guard now.timeIntervalSince(lastTick) >= minTickInterval else { return }
        lastTick = now
        WKInterfaceDevice.current().play(.click)
    }

    /// Reaching an end of travel (first/last item) — a distinct confirmation.
    static func end() {
        lastTick = Date()
        WKInterfaceDevice.current().play(.success)
    }
}
