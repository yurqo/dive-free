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

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        dives: [DiveRecord] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.latitude = latitude
        self.longitude = longitude
        self.dives = dives
    }
}

/// SwiftData-backed record for a single dive within a session.
@Model
public final class DiveRecord {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date
    public var maxDepthMeters: Double
    public var session: SessionRecord?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        maxDepthMeters: Double,
        session: SessionRecord? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.maxDepthMeters = maxDepthMeters
        self.session = session
    }
}

// MARK: - Domain mapping

public extension DiveRecord {
    /// Maps this persistence record into the dependency-free domain `Dive`.
    func toDomain() -> Dive {
        Dive(id: id, startTime: startTime, endTime: endTime, maxDepthMeters: maxDepthMeters)
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
            location: location
        )
    }
}
