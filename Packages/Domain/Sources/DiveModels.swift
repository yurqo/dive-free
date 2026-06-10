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

/// Kinds of events a diver can mark during a session.
public enum EventKind: String, Sendable, Codable, CaseIterable {
    case note
    case wildlife
    case hazard
    case photo
    case custom
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

/// A single descent/ascent detected within a session.
public struct Dive: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date
    public var maxDepthMeters: Double
    public var samples: [DepthSample]

    public var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

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
