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
    // Surface track stored as an inline Codable blob. Defaulted for lightweight
    // migration of rows created before tracks existed.
    public var track: [TrackPoint] = []
    // Session-wide heart-rate / water-temperature series (inline Codable blobs,
    // defaulted for migration of rows created before these existed).
    public var heartRateSamples: [HeartRateSample] = []
    public var temperatureSamples: [TemperatureSample] = []
    // Reverse-geocoded area name, resolved after the session is saved. Optional
    // (like latitude/longitude) so existing rows migrate to nil automatically.
    public var locationName: String?
    // Whether the user edited the area name by hand (auto-resolve must not clobber).
    public var locationNameEdited: Bool = false
    // User annotation — all optional, defaulted for lightweight migration.
    public var title: String?
    public var notes: String?
    public var rating: Int?
    // Manually-entered dive conditions, stored as primitive columns — a Codable
    // composite attribute crashes on read in SwiftData ("Could not cast
    // Optional<Any> to DiveConditions"). The `conditions` computed facade below
    // packs/unpacks these. All optional → lightweight migration.
    public var visibilityRaw: String?
    public var currentRaw: String?
    public var surfaceRaw: String?
    public var tideRaw: String?
    public var waterTemperatureCelsius: Double?
    public var airTemperatureCelsius: Double?

    /// Typed view over the stored condition columns (not itself persisted).
    public var conditions: DiveConditions {
        get {
            DiveConditions(
                visibility: visibilityRaw.flatMap(WaterVisibility.init(rawValue:)),
                current: currentRaw.flatMap(WaterCurrent.init(rawValue:)),
                surface: surfaceRaw.flatMap(SurfaceCondition.init(rawValue:)),
                tide: tideRaw.flatMap(TideStage.init(rawValue:)),
                waterTemperatureCelsius: waterTemperatureCelsius,
                airTemperatureCelsius: airTemperatureCelsius
            )
        }
        set {
            visibilityRaw = newValue.visibility?.rawValue
            currentRaw = newValue.current?.rawValue
            surfaceRaw = newValue.surface?.rawValue
            tideRaw = newValue.tide?.rawValue
            waterTemperatureCelsius = newValue.waterTemperatureCelsius
            airTemperatureCelsius = newValue.airTemperatureCelsius
        }
    }

    // Auto-fetched weather extras (Open-Meteo), as primitive columns with a
    // computed facade (same reason as conditions). `weatherFetched` records that
    // the fetch succeeded so the deferred pass doesn't refetch.
    public var weatherCode: Int?
    public var windSpeedKmh: Double?
    public var waveHeightMeters: Double?
    public var weatherFetched: Bool = false

    /// Typed view over the stored weather columns (not itself persisted); `nil`
    /// until a fetch has run.
    public var weather: DiveWeather? {
        get {
            guard weatherFetched else { return nil }
            return DiveWeather(weatherCode: weatherCode, windSpeedKmh: windSpeedKmh, waveHeightMeters: waveHeightMeters)
        }
        set {
            weatherCode = newValue?.weatherCode
            windSpeedKmh = newValue?.windSpeedKmh
            waveHeightMeters = newValue?.waveHeightMeters
        }
    }

    // Whether distance/maps use the cleaned (outlier-rejected + smoothed) track.
    // Defaulted true for lightweight migration of rows created before the toggle.
    public var smoothTrack: Bool = true

    // Total active energy burned over the session (kilocalories), from the
    // workout. Optional → lightweight migration of rows created before it.
    public var activeEnergyKilocalories: Double?

    /// The dive spot this session belongs to (assigned on import). Optional so
    /// existing rows migrate to nil and get backfilled by the spot assigner.
    public var spot: Spot?

    @Relationship(deleteRule: .cascade, inverse: \DiveRecord.session)
    public var dives: [DiveRecord]

    @Relationship(deleteRule: .cascade, inverse: \MarkerRecord.session)
    public var markers: [MarkerRecord]

    @Relationship(deleteRule: .cascade, inverse: \PhotoRecord.session)
    public var photos: [PhotoRecord] = []

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        track: [TrackPoint] = [],
        heartRateSamples: [HeartRateSample] = [],
        temperatureSamples: [TemperatureSample] = [],
        locationName: String? = nil,
        locationNameEdited: Bool = false,
        title: String? = nil,
        notes: String? = nil,
        rating: Int? = nil,
        conditions: DiveConditions = DiveConditions(),
        weather: DiveWeather? = nil,
        weatherFetched: Bool = false,
        smoothTrack: Bool = true,
        activeEnergyKilocalories: Double? = nil,
        dives: [DiveRecord] = [],
        markers: [MarkerRecord] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.latitude = latitude
        self.longitude = longitude
        self.track = track
        self.heartRateSamples = heartRateSamples
        self.temperatureSamples = temperatureSamples
        self.locationName = locationName
        self.locationNameEdited = locationNameEdited
        self.title = title
        self.notes = notes
        self.rating = rating
        self.visibilityRaw = conditions.visibility?.rawValue
        self.currentRaw = conditions.current?.rawValue
        self.surfaceRaw = conditions.surface?.rawValue
        self.tideRaw = conditions.tide?.rawValue
        self.waterTemperatureCelsius = conditions.waterTemperatureCelsius
        self.airTemperatureCelsius = conditions.airTemperatureCelsius
        self.weatherCode = weather?.weatherCode
        self.windSpeedKmh = weather?.windSpeedKmh
        self.waveHeightMeters = weather?.waveHeightMeters
        self.weatherFetched = weatherFetched
        self.smoothTrack = smoothTrack
        self.activeEnergyKilocalories = activeEnergyKilocalories
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
            location: location,
            track: track,
            heartRateSamples: heartRateSamples,
            temperatureSamples: temperatureSamples,
            locationName: locationName,
            locationNameEdited: locationNameEdited,
            title: title,
            notes: notes,
            rating: rating,
            conditions: conditions,
            weather: weather,
            weatherFetched: weatherFetched,
            smoothTrack: smoothTrack,
            activeEnergyKilocalories: activeEnergyKilocalories
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
            track: session.track,
            heartRateSamples: session.heartRateSamples,
            temperatureSamples: session.temperatureSamples,
            locationName: session.locationName,
            locationNameEdited: session.locationNameEdited,
            title: session.title,
            notes: session.notes,
            rating: session.rating,
            conditions: session.conditions,
            weather: session.weather,
            weatherFetched: session.weatherFetched,
            smoothTrack: session.smoothTrack,
            activeEnergyKilocalories: session.activeEnergyKilocalories,
            dives: session.dives.map { DiveRecord(from: $0) },
            markers: session.markers.map { MarkerRecord(from: $0) }
        )
    }
}
