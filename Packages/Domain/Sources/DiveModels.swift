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
    /// Horizontal accuracy of the fix in meters (lower is better), or `nil` for
    /// interpolated/legacy points with no known accuracy. Optional so payloads
    /// from older app versions (which had no accuracy field) still decode.
    public var horizontalAccuracy: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    /// Great-circle distance to another point, in meters (haversine).
    public func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

public extension Array where Element == TrackPoint {
    /// Total surface distance along the track, summing great-circle hops between
    /// consecutive time-ordered points (meters).
    var surfaceDistanceMeters: Double {
        let ordered = sorted { $0.timestamp < $1.timestamp }
        return zip(ordered, ordered.dropFirst())
            .reduce(0.0) { $0 + $1.0.location.distance(to: $1.1.location) }
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
    /// Filename of a voice note recorded for this marker, within the app's
    /// voice-notes directory. `nil` when there's no recording. Optional so
    /// payloads from older app versions still decode.
    public var audioFileName: String?

    public init(id: UUID = UUID(), timestamp: Date, kind: MarkerKind, text: String? = nil, audioFileName: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.audioFileName = audioFileName
    }

    /// Convenience for built-in kinds.
    public init(id: UUID = UUID(), timestamp: Date, kind: EventKind, text: String? = nil, audioFileName: String? = nil) {
        self.init(id: id, timestamp: timestamp, kind: MarkerKind(kind), text: text, audioFileName: audioFileName)
    }

    /// Whether a voice note is attached.
    public var hasAudio: Bool { audioFileName != nil }
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

/// A timestamped surface GPS fix. A session's `track` is the ordered series of
/// these, captured while the diver is at the surface (GPS doesn't work
/// underwater), forming the surface path drawn on the map.
public struct TrackPoint: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var location: GeoPoint

    public init(id: UUID = UUID(), timestamp: Date, location: GeoPoint) {
        self.id = id
        self.timestamp = timestamp
        self.location = location
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
    /// Ordered surface GPS fixes captured during the session (the surface path).
    public var track: [TrackPoint]

    public var maxDepthMeters: Double { dives.map(\.maxDepthMeters).max() ?? 0 }
    public var diveCount: Int { dives.count }

    /// Total surface distance traveled during the session (meters), from the track.
    public var surfaceDistanceMeters: Double { track.surfaceDistanceMeters }

    /// Linearly-interpolated surface position at the given instant, clamped to
    /// the track's endpoints. `nil` only when there is no track at all. Used to
    /// place dive events and surface markers along the path by timestamp.
    public func surfaceLocation(at time: Date) -> GeoPoint? {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        if time <= first.timestamp { return first.location }
        if time >= last.timestamp { return last.location }
        for (a, b) in zip(ordered, ordered.dropFirst()) where time >= a.timestamp && time <= b.timestamp {
            let span = b.timestamp.timeIntervalSince(a.timestamp)
            guard span > 0 else { return a.location }
            let f = time.timeIntervalSince(a.timestamp) / span
            return GeoPoint(
                latitude: a.location.latitude + (b.location.latitude - a.location.latitude) * f,
                longitude: a.location.longitude + (b.location.longitude - a.location.longitude) * f
            )
        }
        return last.location
    }

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

    /// Geographic position to draw an event marker at: along the surface path for
    /// surface markers, or along the straight submersion→surfacing segment of the
    /// dive that contains it for underwater markers. `nil` when there is no track.
    public func markerLocation(_ marker: EventMarker) -> GeoPoint? {
        if let dive = dives.first(where: { marker.timestamp >= $0.startTime && marker.timestamp <= $0.endTime }),
           let submersion = surfaceLocation(at: dive.startTime),
           let surfacing = surfaceLocation(at: dive.endTime) {
            let span = dive.endTime.timeIntervalSince(dive.startTime)
            let fraction = span > 0
                ? max(0, min(1, marker.timestamp.timeIntervalSince(dive.startTime) / span))
                : 0
            return GeoPoint(
                latitude: submersion.latitude + (surfacing.latitude - submersion.latitude) * fraction,
                longitude: submersion.longitude + (surfacing.longitude - submersion.longitude) * fraction
            )
        }
        return surfaceLocation(at: marker.timestamp)
    }

    /// The session as an ordered timeline of dives and the surface intervals
    /// around them (before the first dive, between dives, and after the last).
    /// Surface gaps shorter than a second are dropped as noise.
    public var segments: [SessionSegment] {
        let ordered = dives.sorted { $0.startTime < $1.startTime }
        var result: [SessionSegment] = []
        var cursor = startTime
        func markersIn(_ from: Date, _ to: Date) -> Int {
            markers.filter { $0.timestamp >= from && $0.timestamp <= to }.count
        }
        func appendSurface(upTo end: Date) {
            guard end.timeIntervalSince(cursor) >= 1 else { return }
            // Surface distance traveled during just this interval (track hops
            // between the cursor and the next dive / session end).
            let distance = track
                .filter { $0.timestamp >= cursor && $0.timestamp <= end }
                .surfaceDistanceMeters
            result.append(SessionSegment(
                id: result.count, kind: .surface, startTime: cursor, endTime: end,
                distanceMeters: distance, markerCount: markersIn(cursor, end)
            ))
        }
        for dive in ordered {
            appendSurface(upTo: dive.startTime)
            result.append(SessionSegment(
                id: result.count, kind: .dive(dive), startTime: dive.startTime, endTime: dive.endTime,
                markerCount: markersIn(dive.startTime, dive.endTime)
            ))
            cursor = max(cursor, dive.endTime)
        }
        appendSurface(upTo: endTime ?? cursor)
        return result
    }

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        dives: [Dive] = [],
        markers: [EventMarker] = [],
        location: GeoPoint? = nil,
        track: [TrackPoint] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.dives = dives
        self.markers = markers
        self.location = location
        self.track = track
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, dives, markers, location, track
    }

    /// Decoded leniently so payloads from an older app version (which had no
    /// `track`) still decode — `track` simply defaults to empty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        dives = try c.decode([Dive].self, forKey: .dives)
        markers = try c.decode([EventMarker].self, forKey: .markers)
        location = try c.decodeIfPresent(GeoPoint.self, forKey: .location)
        track = try c.decodeIfPresent([TrackPoint].self, forKey: .track) ?? []
    }
}

/// One leg of a session's timeline: either a dive (submersion) or a surface
/// interval between/around dives. Built by `DiveSession.segments` so the summary
/// can render the session as an ordered list.
public struct SessionSegment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case dive(Dive)
        case surface
    }

    public let id: Int
    public let kind: Kind
    public let startTime: Date
    public let endTime: Date
    /// Surface distance traveled during this segment (meters). Meaningful for
    /// surface intervals; 0 for dives (GPS doesn't track underwater).
    public let distanceMeters: Double
    /// Number of markers placed during this segment's time window.
    public let markerCount: Int

    public var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    /// The dive when this segment is a dive, else `nil`.
    public var dive: Dive? {
        if case .dive(let dive) = kind { return dive }
        return nil
    }

    /// Whether this segment is a dive (vs a surface interval).
    public var isDive: Bool { dive != nil }

    public init(id: Int, kind: Kind, startTime: Date, endTime: Date, distanceMeters: Double = 0, markerCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.markerCount = markerCount
    }
}
