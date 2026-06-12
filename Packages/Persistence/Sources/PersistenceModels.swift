import Foundation
import SwiftData
import Domain

/// SwiftData-backed record for a stored dive session.
@Model
public final class SessionRecord {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var latitude: Double?
    public var longitude: Double?

    @Relationship(deleteRule: .cascade, inverse: \DiveRecord.session)
    public var dives: [DiveRecord]

    @Relationship(deleteRule: .cascade, inverse: \MarkerRecord.session)
    public var markers: [MarkerRecord]

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        dives: [DiveRecord] = [],
        markers: [MarkerRecord] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.latitude = latitude
        self.longitude = longitude
        self.dives = dives
        self.markers = markers
    }
}

/// SwiftData-backed record for a single dive within a session.
/// Depth samples are stored as an inline `Codable` blob — always loaded with the dive,
/// no per-sample row overhead.
@Model
public final class DiveRecord {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date
    public var maxDepthMeters: Double
    public var samples: [DepthSample]
    public var session: SessionRecord?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        maxDepthMeters: Double,
        samples: [DepthSample] = [],
        session: SessionRecord? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.maxDepthMeters = maxDepthMeters
        self.samples = samples
        self.session = session
    }
}

/// SwiftData-backed record for a user-placed event marker within a session.
@Model
public final class MarkerRecord {
    public var id: UUID
    public var timestamp: Date
    public var kind: String       // `MarkerKind.id` (built-in EventKind raw value, or custom UUID)
    // Snapshot of the kind's emoji/label so a marker renders even if a custom
    // definition is later edited/deleted. Defaulted for lightweight migration of
    // pre-existing rows (built-ins are re-resolved from `EventKind` in toDomain).
    public var emoji: String = ""
    public var label: String = ""
    public var text: String?
    public var session: SessionRecord?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        kind: String,
        emoji: String = "",
        label: String = "",
        text: String? = nil,
        session: SessionRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.emoji = emoji
        self.label = label
        self.text = text
        self.session = session
    }
}

/// A user-defined custom marker definition (managed on iPhone, synced to Watch).
@Model
public final class CustomMarkerRecord {
    public var id: UUID
    public var emoji: String
    public var label: String
    public var createdAt: Date

    public init(id: UUID = UUID(), emoji: String, label: String, createdAt: Date = Date()) {
        self.id = id
        self.emoji = emoji
        self.label = label
        self.createdAt = createdAt
    }

    public func toMarkerKind() -> MarkerKind {
        MarkerKind(id: id.uuidString, emoji: emoji, label: label)
    }
}

// MARK: - Record → Domain

public extension DiveRecord {
    /// Maps this persistence record into the dependency-free domain `Dive`.
    func toDomain() -> Dive {
        Dive(id: id, startTime: startTime, endTime: endTime, maxDepthMeters: maxDepthMeters, samples: samples)
    }
}

public extension MarkerRecord {
    /// Maps this persistence record into the dependency-free domain `EventMarker`.
    func toDomain() -> EventMarker {
        // Built-in kinds re-resolve their canonical emoji/label from EventKind
        // (also fixes legacy rows stored before the snapshot fields existed);
        // custom kinds use the stored snapshot.
        let resolved: MarkerKind
        if let builtIn = EventKind(rawValue: kind) {
            resolved = MarkerKind(builtIn)
        } else {
            resolved = MarkerKind(id: kind, emoji: emoji, label: label)
        }
        return EventMarker(id: id, timestamp: timestamp, kind: resolved, text: text)
    }
}

public extension SessionRecord {
    /// Maps this persistence record into the dependency-free domain `DiveSession`.
    func toDomain() -> DiveSession {
        let location: GeoPoint? = {
            guard let latitude, let longitude else { return nil }
            return GeoPoint(latitude: latitude, longitude: longitude)
        }()
        return DiveSession(
            id: id,
            startTime: startTime,
            endTime: endTime,
            dives: dives.map { $0.toDomain() },
            markers: markers.map { $0.toDomain() },
            location: location
        )
    }
}

// MARK: - Domain → Record

public extension DiveRecord {
    /// Creates a new `DiveRecord` from a domain `Dive`.
    convenience init(from dive: Dive) {
        self.init(
            id: dive.id,
            startTime: dive.startTime,
            endTime: dive.endTime,
            maxDepthMeters: dive.maxDepthMeters,
            samples: dive.samples
        )
    }
}

public extension MarkerRecord {
    /// Creates a new `MarkerRecord` from a domain `EventMarker`.
    convenience init(from marker: EventMarker) {
        self.init(
            id: marker.id,
            timestamp: marker.timestamp,
            kind: marker.kind.id,
            emoji: marker.kind.emoji,
            label: marker.kind.label,
            text: marker.text
        )
    }
}

public extension SessionRecord {
    /// Creates a new `SessionRecord` (with child records) from a domain `DiveSession`.
    convenience init(from session: DiveSession) {
        self.init(
            id: session.id,
            startTime: session.startTime,
            endTime: session.endTime,
            latitude: session.location?.latitude,
            longitude: session.location?.longitude,
            dives: session.dives.map { DiveRecord(from: $0) },
            markers: session.markers.map { MarkerRecord(from: $0) }
        )
    }
}
