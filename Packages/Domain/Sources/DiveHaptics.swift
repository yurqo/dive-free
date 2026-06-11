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
    /// Depth (m) above which the diver is considered at the surface.
    /// Keep aligned with `DiveDetectionConfig.surfaceThresholdMeters`.
    public var surfaceThresholdMeters: Double
    /// Fire a milestone haptic each time depth crosses a multiple of this
    /// interval (m). Set to 0 to disable milestone haptics.
    public var milestoneIntervalMeters: Double

    public init(
        surfaceThresholdMeters: Double = 1.0,
        milestoneIntervalMeters: Double = 5.0
    ) {
        self.surfaceThresholdMeters = surfaceThresholdMeters
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

    public init(config: DiveHapticConfig = .default) {
        self.config = config
    }

    /// Ingest one depth reading. Returns the events produced by that sample.
    public mutating func update(depthMeters: Double) -> [DiveHapticEvent] {
        let submerged = depthMeters > config.surfaceThresholdMeters
        var events: [DiveHapticEvent] = []

        if submerged && !isSubmerged {
            // Rising edge: entered the water.
            events.append(.diveStart)
            isSubmerged = true
            lastMilestoneLevel = 0
        } else if !submerged && isSubmerged {
            // Falling edge: returned to surface.
            events.append(.surface)
            isSubmerged = false
            lastMilestoneLevel = 0
            return events   // No milestone checks at the surface.
        }

        // Milestone checks while underwater.
        if isSubmerged, config.milestoneIntervalMeters > 0 {
            let level = Int(depthMeters / config.milestoneIntervalMeters)
            if level > lastMilestoneLevel {
                events.append(.descendMilestone(depthMeters: Double(level) * config.milestoneIntervalMeters))
                lastMilestoneLevel = level
            } else if level < lastMilestoneLevel {
                events.append(.ascendMilestone(depthMeters: Double(level) * config.milestoneIntervalMeters))
                lastMilestoneLevel = level
            }
        }

        return events
    }
}
