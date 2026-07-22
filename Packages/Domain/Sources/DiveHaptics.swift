import Foundation

/// Haptic feedback events emitted when depth-crossing transitions occur.
public enum DiveHapticEvent: Sendable, Equatable {
    /// The diver crossed the surface threshold going down.
    case diveStart
    /// The diver returned to the surface.
    case surface
    /// The diver passed a depth milestone on the way down.
    case descendMilestone(depthMeters: Double)
    /// The diver passed a depth milestone on the way up.
    case ascendMilestone(depthMeters: Double)
    /// A user action was confirmed — an event marker was placed, or a
    /// Crown-menu action fired. Used as touch-free input acknowledgement.
    case markerPlaced
}

/// Thresholds that control when haptic events fire.
public struct DiveHapticConfig: Sendable, Equatable {
    /// Depth (m) the diver must pass going **down** to count as submerged (fires
    /// `diveStart`). Keep aligned with `DiveDetectionConfig.surfaceThresholdMeters`.
    public var surfaceThresholdMeters: Double
    /// How long (s) the diver may stay in the shallow band (between
    /// `DiveDetectionConfig.surfaceExitDepthMeters` and `surfaceThresholdMeters`) —
    /// without reaching 0 m — before the tracker counts them as surfaced and fires
    /// `surface`. This lets repeated dives whose wrist never fully clears the water
    /// still fire a per-dive `surface` (and a fresh `diveStart` on the next descent).
    /// Keep aligned with `DiveDetectionConfig.surfaceExitDwellSeconds`.
    ///
    /// The fully-surfaced depth (at or below which `surface` fires immediately going
    /// **up**) is not configurable here: the tracker reads the shared
    /// `DiveDetectionConfig.surfaceExitDepthMeters` directly, so it can never drift
    /// from the detector's 0 m dive-end rule.
    public var surfaceExitDwellSeconds: TimeInterval
    /// Fire a milestone haptic each time depth crosses a multiple of this
    /// interval (m). Set to 0 to disable milestone haptics.
    public var milestoneIntervalMeters: Double

    public init(
        surfaceThresholdMeters: Double = 1.0,
        surfaceExitDwellSeconds: TimeInterval = 3,
        milestoneIntervalMeters: Double = 5.0
    ) {
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.surfaceExitDwellSeconds = surfaceExitDwellSeconds
        self.milestoneIntervalMeters = milestoneIntervalMeters
    }

    public static let `default` = DiveHapticConfig()
}

/// Stateful edge detector. Feed one depth sample at a time; it returns the
/// haptic events (if any) produced by that sample. Typical return is `[]` or
/// a single event; two events can be returned only when a sample simultaneously
/// triggers a surface-crossing and a milestone crossing.
///
/// Reset to a fresh instance at the start of each session.
public struct DiveHapticTracker: Sendable {
    public let config: DiveHapticConfig

    private var isSubmerged: Bool = false
    /// Current milestone level: `floor(depth / interval)` while submerged.
    private var lastMilestoneLevel: Int = 0
    /// Timestamp at which the diver first entered the shallow band during the
    /// current dive (`nil` while deep or surfaced). Drives the dwell-based exit.
    private var shallowSince: Date?

    public init(config: DiveHapticConfig = .default) {
        self.config = config
    }

    /// Ingest one depth reading. Returns the events produced by that sample.
    ///
    /// `timestamp` is the sample's wall-clock time; it drives the shallow-band
    /// dwell so a diver whose wrist never fully clears the water between dives
    /// still fires a per-dive `surface`. Defaults to `Date()` so existing call
    /// sites that pass live samples keep working.
    public mutating func update(depthMeters: Double, at timestamp: Date = Date()) -> [DiveHapticEvent] {
        var events: [DiveHapticEvent] = []

        // Mirror the detector's dive-end rule (see DiveDetector): a dive stays
        // open while deeper than the threshold, ends immediately at 0 m
        // (≤ surfaceExitDepthMeters), and ends after surfaceExitDwellSeconds
        // continuously in the shallow band (between the two) — so repeated dives
        // that never fully surface still fire per-dive edges.
        if !isSubmerged, depthMeters > config.surfaceThresholdMeters {
            // Rising edge: entered the water.
            events.append(.diveStart)
            isSubmerged = true
            lastMilestoneLevel = 0
            shallowSince = nil
        } else if isSubmerged, depthMeters > config.surfaceThresholdMeters {
            // Back deep: cancel any pending shallow-band dwell.
            shallowSince = nil
        } else if isSubmerged, depthMeters <= DiveDetectionConfig.surfaceExitDepthMeters {
            // Falling edge: fully surfaced (0 m). End immediately.
            events.append(.surface)
            isSubmerged = false
            lastMilestoneLevel = 0
            shallowSince = nil
            return events   // No milestone checks at the surface.
        } else if isSubmerged {
            // Shallow band: time the dwell from first entry; surface at expiry.
            // With dwell 0 (the legacy immediate-end value) the FIRST shallow sample
            // is already the exit — match the detector, which ends the dive at the
            // first below-threshold sample — rather than waiting one more sample for
            // the elapsed check to pass.
            if let since = shallowSince {
                if timestamp.timeIntervalSince(since) >= config.surfaceExitDwellSeconds {
                    events.append(.surface)
                    isSubmerged = false
                    lastMilestoneLevel = 0
                    shallowSince = nil
                    return events
                }
            } else if config.surfaceExitDwellSeconds <= 0 {
                events.append(.surface)
                isSubmerged = false
                lastMilestoneLevel = 0
                shallowSince = nil
                return events
            } else {
                shallowSince = timestamp
            }
        }

        // Milestone checks while underwater.
        if isSubmerged, config.milestoneIntervalMeters > 0 {
            let level = Int(depthMeters / config.milestoneIntervalMeters)
            if level > lastMilestoneLevel {
                events.append(.descendMilestone(depthMeters: Double(level) * config.milestoneIntervalMeters))
                lastMilestoneLevel = level
            } else if level < lastMilestoneLevel {
                // Suppress a "0 m" milestone in the shallow band on the way up — the
                // ascent through that band is announced by the surface event, not a
                // milestone. (Descent never emits level 0, so this only affects ascent.)
                if level >= 1 {
                    events.append(.ascendMilestone(depthMeters: Double(level) * config.milestoneIntervalMeters))
                }
                lastMilestoneLevel = level
            }
        }

        return events
    }
}
