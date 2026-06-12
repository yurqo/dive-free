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

    /// Decode leniently: unknown or legacy raw values (e.g. the old "custom")
    /// map to `.note` rather than failing the whole payload's decode.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EventKind(rawValue: raw) ?? .note
    }

    /// This built-in kind as a `MarkerKind` snapshot.
    public var markerKind: MarkerKind { MarkerKind(self) }

    /// All built-in kinds as `MarkerKind`s, for the marker menu.
    public static var builtInMarkerKinds: [MarkerKind] { allCases.map(MarkerKind.init) }
}

/// A marker kind as id + emoji + label. Covers both built-in `EventKind`s and
/// user-defined custom markers. Markers store this as a **snapshot** so they
/// still render even if a custom definition is later edited or deleted.
public struct MarkerKind: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Built-in kinds use the `EventKind` raw value; custom kinds use a UUID string.
    public var id: String
    public var emoji: String
    public var label: String

    public init(id: String, emoji: String, label: String) {
        self.id = id
        self.emoji = emoji
        self.label = label
    }

    public init(_ builtIn: EventKind) {
        self.init(id: builtIn.rawValue, emoji: builtIn.emoji, label: builtIn.label)
    }
}

/// A user-placed marker at a point in time during the session.
public struct EventMarker: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: MarkerKind
    public var text: String?

    public init(id: UUID = UUID(), timestamp: Date, kind: MarkerKind, text: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
    }

    /// Convenience for built-in kinds.
    public init(id: UUID = UUID(), timestamp: Date, kind: EventKind, text: String? = nil) {
        self.init(id: id, timestamp: timestamp, kind: MarkerKind(kind), text: text)
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

    /// Linearly-interpolated depth at the given instant, or `nil` if the time
    /// falls outside the dive's sample range. Used to place event markers on the
    /// depth profile at the depth the diver was actually at when the marker
    /// landed.
    public func interpolatedDepth(at time: Date) -> Double? {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last,
              time >= first.timestamp, time <= last.timestamp else { return nil }
        for (a, b) in zip(ordered, ordered.dropFirst()) where time >= a.timestamp && time <= b.timestamp {
            let span = b.timestamp.timeIntervalSince(a.timestamp)
            guard span > 0 else { return a.depthMeters }
            let fraction = time.timeIntervalSince(a.timestamp) / span
            return a.depthMeters + (b.depthMeters - a.depthMeters) * fraction
        }
        return last.depthMeters
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
    public var markerCountsByKind: [MarkerKind: Int] {
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
