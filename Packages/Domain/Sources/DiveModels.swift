import Foundation

/// A single depth reading. Depth is in meters, positive downward (0 = surface).
public struct DepthSample: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var depthMeters: Double

    public init(timestamp: Date, depthMeters: Double) {
        self.timestamp = timestamp
        self.depthMeters = depthMeters
    }
}

/// A geographic coordinate where a session took place.
public struct GeoPoint: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Kinds of events a diver can mark during a session. Built-in kinds only;
/// user-defined custom markers are tracked separately (see roadmap).
public enum EventKind: String, Sendable, Codable, CaseIterable {
    case note
    case wildlife
    case hazard
    case photo

    /// Emoji shown in the marker carousel and summaries.
    public var emoji: String {
        switch self {
        case .note: "🗒️"
        case .wildlife: "🐠"
        case .hazard: "⚠️"
        case .photo: "📸"
        }
    }

    /// Human-readable label.
    public var label: String {
        switch self {
        case .note: "Note"
        case .wildlife: "Wildlife"
        case .hazard: "Hazard"
        case .photo: "Photo"
        }
    }
}

/// A user-placed marker at a point in time during the session.
public struct EventMarker: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: EventKind
    public var text: String?

    public init(id: UUID = UUID(), timestamp: Date, kind: EventKind, text: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
    }
}

/// One point of a dive's depth-over-time profile, with elapsed seconds since
/// the dive started. `id` is the sample's position in time order, stable for
/// chart selection within a single dive.
public struct DepthProfilePoint: Sendable, Equatable, Identifiable {
    public var id: Int
    public var secondsFromStart: TimeInterval
    public var depthMeters: Double

    public init(id: Int, secondsFromStart: TimeInterval, depthMeters: Double) {
        self.id = id
        self.secondsFromStart = secondsFromStart
        self.depthMeters = depthMeters
    }
}

/// A single descent/ascent detected within a session.
public struct Dive: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date
    public var maxDepthMeters: Double
    public var samples: [DepthSample]

    public var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    /// Depth samples expressed as seconds-from-dive-start, ordered in time and
    /// ready to plot (x = elapsed seconds, y = depth). Keeps charting code free
    /// of timestamp math and makes the transform unit-testable.
    public var depthProfile: [DepthProfilePoint] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { index, sample in
                DepthProfilePoint(
                    id: index,
                    secondsFromStart: sample.timestamp.timeIntervalSince(startTime),
                    depthMeters: sample.depthMeters
                )
            }
    }

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        maxDepthMeters: Double,
        samples: [DepthSample] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.maxDepthMeters = maxDepthMeters
        self.samples = samples
    }
}

/// A complete in-water session containing one or more dives.
public struct DiveSession: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var dives: [Dive]
    public var markers: [EventMarker]
    public var location: GeoPoint?

    public var maxDepthMeters: Double { dives.map(\.maxDepthMeters).max() ?? 0 }
    public var diveCount: Int { dives.count }

    /// Total wall-clock duration of the session, or 0 while still in progress.
    public var totalDuration: TimeInterval {
        guard let endTime else { return 0 }
        return endTime.timeIntervalSince(startTime)
    }

    /// Mean surface interval (recovery time) between consecutive dives, or `nil`
    /// with fewer than two dives. Dives are ordered by start time before pairing,
    /// and negative gaps from overlapping dives are clamped to zero.
    public var averageSurfaceInterval: TimeInterval? {
        let ordered = dives.sorted { $0.startTime < $1.startTime }
        guard ordered.count >= 2 else { return nil }
        let total = zip(ordered, ordered.dropFirst()).reduce(0.0) { sum, pair in
            sum + max(0, pair.1.startTime.timeIntervalSince(pair.0.endTime))
        }
        return total / Double(ordered.count - 1)
    }

    /// Count of placed markers grouped by kind.
    public var markerCountsByKind: [EventKind: Int] {
        markers.reduce(into: [:]) { counts, marker in counts[marker.kind, default: 0] += 1 }
    }

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        dives: [Dive] = [],
        markers: [EventMarker] = [],
        location: GeoPoint? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.dives = dives
        self.markers = markers
        self.location = location
    }
}
