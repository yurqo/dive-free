import Foundation

/// A pure, versioned, dependency-free archive of a user's DiveFree data, suitable
/// for a full backup & restore round-trip on the same or another device.
///
/// This is the *format* only. The Persistence/UI layers assemble a `BackupArchive`
/// from SwiftData (sessions, spots, trips) plus the voice-note audio bytes, encode
/// it with ``encoded()``, and later rebuild their models from a ``decode(_:)`` result.
/// Nothing here touches SwiftData or the filesystem, so it stays deterministic and
/// unit-testable.
///
/// - `sessions` reuse the Domain ``DiveSession`` model directly.
/// - `spots`/`trips` are pure Codable DTOs (``SpotBackup``/``TripBackup``) because the
///   real `Spot`/`Trip` types are Persistence `@Model`s not visible to Domain. Each
///   carries the list of session IDs that belong to it so relationships can be
///   reconstructed on import.
/// - `audio` maps a voice-note file name (as referenced by
///   ``EventMarker/audioFileName``) to its raw bytes. `Data` JSON-encodes as base64,
///   so the audio travels inside the same self-contained JSON archive.

// MARK: - Spot / Trip DTOs

/// A pure snapshot of a dive spot for backup, including the sessions logged at it.
public struct SpotBackup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var country: String?
    public var countryCode: String?
    public var notes: String?
    public var createdAt: Date
    /// IDs of the ``DiveSession``s that belong to this spot.
    public var sessionIDs: [UUID]

    public init(
        id: UUID,
        name: String,
        latitude: Double,
        longitude: Double,
        country: String? = nil,
        countryCode: String? = nil,
        notes: String? = nil,
        createdAt: Date,
        sessionIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
        self.countryCode = countryCode
        self.notes = notes
        self.createdAt = createdAt
        self.sessionIDs = sessionIDs
    }
}

/// A pure snapshot of a trip for backup, including the sessions grouped under it.
public struct TripBackup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var startDate: Date
    public var endDate: Date
    public var notes: String?
    public var createdAt: Date
    /// IDs of the ``DiveSession``s that belong to this trip.
    public var sessionIDs: [UUID]

    public init(
        id: UUID,
        name: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        createdAt: Date,
        sessionIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.createdAt = createdAt
        self.sessionIDs = sessionIDs
    }
}

// MARK: - Errors

/// Failures raised when decoding a ``BackupArchive``.
public enum BackupArchiveError: Error, Equatable {
    /// The archive's `formatVersion` is newer than this build can read.
    case unsupportedVersion(found: Int, supported: Int)
    /// The bytes are not a valid archive (bad JSON, wrong shape, missing keys).
    /// The associated string is a short human-readable reason for diagnostics.
    case malformed(String)
}

// MARK: - Archive

/// The top-level backup container. Bump ``currentFormatVersion`` whenever the shape
/// changes; ``decode(_:)`` rejects archives from a *newer* format than this build
/// understands while tolerating older/equal ones.
public struct BackupArchive: Codable, Sendable, Equatable {
    /// The format version this build writes and can read.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// When this archive was produced.
    public var exportedAt: Date
    /// The app version that produced it, purely informational.
    public var appVersion: String?
    public var sessions: [DiveSession]
    public var spots: [SpotBackup]
    public var trips: [TripBackup]
    /// Voice-note file name → raw audio bytes (base64 in JSON).
    public var audio: [String: Data]

    public init(
        formatVersion: Int = BackupArchive.currentFormatVersion,
        exportedAt: Date,
        appVersion: String? = nil,
        sessions: [DiveSession] = [],
        spots: [SpotBackup] = [],
        trips: [TripBackup] = [],
        audio: [String: Data] = [:]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.sessions = sessions
        self.spots = spots
        self.trips = trips
        self.audio = audio
    }

    // MARK: Coding

    /// A deterministic encoder/decoder pair. `.sortedKeys` gives byte-stable output,
    /// and a fixed ISO-8601 date strategy keeps dates portable and reproducible.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes the archive to deterministic JSON bytes.
    public func encoded() throws -> Data {
        try BackupArchive.makeEncoder().encode(self)
    }

    /// Decodes an archive and validates its `formatVersion`.
    ///
    /// - Throws: ``BackupArchiveError/unsupportedVersion(found:supported:)`` if the
    ///   archive is newer than ``currentFormatVersion``; ``BackupArchiveError/malformed(_:)``
    ///   for any decoding failure (so callers never see a raw `DecodingError`).
    public static func decode(_ data: Data) throws -> BackupArchive {
        // First read only the version so a forward-incompatible archive is rejected
        // with a clear error rather than an opaque decoding failure on new fields.
        let version: Int
        do {
            version = try makeDecoder().decode(VersionProbe.self, from: data).formatVersion
        } catch {
            throw BackupArchiveError.malformed(String(describing: error))
        }
        guard version <= currentFormatVersion else {
            throw BackupArchiveError.unsupportedVersion(found: version, supported: currentFormatVersion)
        }
        do {
            return try makeDecoder().decode(BackupArchive.self, from: data)
        } catch {
            throw BackupArchiveError.malformed(String(describing: error))
        }
    }

    /// Minimal shape used to read `formatVersion` before a full decode.
    private struct VersionProbe: Decodable {
        let formatVersion: Int
    }
}
