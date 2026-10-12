import Foundation

/// Confirms a surface exit without mistaking an ongoing shallow ascent for rest.
/// A zero reading ends immediately. Otherwise the configured dwell starts again
/// whenever the diver gets appreciably closer to the surface.
public struct DiveSurfaceExit: Sendable {
    private var shallowDepth: Double?
    private var shallowSince: Date?
    private static let ascentToleranceMeters = 0.001

    public init() {}

    public mutating func reset() {
        shallowDepth = nil
        shallowSince = nil
    }

    /// Returns the start of the confirmed surface rest, or the actual zero
    /// timestamp. The shallow ascent before that instant belongs to the dive.
    public mutating func update(depthMeters: Double, at timestamp: Date,
                                threshold: Double, dwell: TimeInterval) -> Date? {
        if depthMeters > threshold {
            reset()
            return nil
        }
        if depthMeters <= DiveDetectionConfig.surfaceExitDepthMeters {
            reset()
            return timestamp
        }
        if shallowDepth.map({ depthMeters < $0 - Self.ascentToleranceMeters }) ?? true {
            shallowDepth = depthMeters
            shallowSince = timestamp
            return nil // Even zero dwell needs a steady reading, not an ongoing ascent.
        }
        guard let since = shallowSince, timestamp.timeIntervalSince(since) >= dwell else { return nil }
        return since
    }
}
