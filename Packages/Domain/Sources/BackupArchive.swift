import Foundation

/// A pure, versioned, dependency-free *manifest* for a DiveFree backup, suitable
/// for a full backup & restore round-trip on the same or another device.
///
/// This is the *format* only. A backup is a **ZIP container**: this JSON manifest
/// (as `manifest.json`) plus discrete media files — voice-note audio, photo/video
/// originals, and thumbnails — stored as separate entries alongside it. The
/// Persistence/UI layers assemble a `BackupArchive` from SwiftData (sessions,
/// spots, trips, photos), write the media files into the zip, encode the manifest
/// with ``encoded()``, and on restore rebuild their models from a ``decode(_:)``
/// result while pulling the referenced files back out of the zip. Nothing here
/// touches SwiftData, PhotoKit, or the filesystem, so it stays deterministic and
/// unit-testable — and it carries **no media bytes**, only references by file name.
///
/// - `sessions` reuse the Domain ``DiveSession`` model directly. Voice-note audio no
///   longer travels inside this JSON; a marker's ``EventMarker/audioFileName`` names
///   the audio file bundled next to the manifest in the zip.
/// - `spots`/`trips` are pure Codable DTOs (``SpotBackup``/``TripBackup``) because the
///   real `Spot`/`Trip` types are Persistence `@Model`s not visible to Domain. Each
///   carries the list of session IDs that belong to it so relationships can be
///   reconstructed on import.
/// - `photos` are ``PhotoBackup`` DTOs mirroring the Persistence `PhotoRecord`
///   `@Model`. Each references its bundled thumbnail/media files by name (or `nil`
///   when the user exported metadata-only), and carries the cross-device-stable
///   `assetCloudIdentifier` so the original can be relinked from iCloud Photos.

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

// MARK: - Photo DTO

/// A pure snapshot of a photo/video attachment for backup, mirroring the fields of
/// the Persistence `PhotoRecord` `@Model`.
///
/// The manifest never carries media bytes. The heavy original and the thumbnail (if
/// any) live as separate files in the zip, named by ``mediaFileName`` and
/// ``thumbnailFileName``. Restore uses those names to pull bytes back out; when
/// ``mediaFileName`` is `nil` the user exported metadata only, so restore relinks the
/// original from iCloud Photos via ``assetCloudIdentifier`` (or skips it).
///
/// The device-local `PHAsset.localIdentifier` is deliberately **not** stored — it is
/// not portable across devices. Only the cross-device-stable
/// `PHCloudIdentifier.stringValue` (``assetCloudIdentifier``) travels.
public struct PhotoBackup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The session this photo belongs to, if attached via a session.
    public var sessionID: UUID?
    /// The spot this photo is attached to directly, if any.
    public var spotID: UUID?
    /// The marker this photo is linked to, if any.
    public var markerID: UUID?
    /// `PHCloudIdentifier.stringValue` for the referenced asset — stable across
    /// devices, so the original can be relinked from iCloud Photos on restore.
    public var assetCloudIdentifier: String?
    /// Whether the referenced asset is a video (drives the play badge / AVKit).
    public var isVideo: Bool
    public var createdAt: Date
    /// Name of the thumbnail file bundled in the zip; `nil` if none.
    public var thumbnailFileName: String?
    /// Name of the full-resolution photo/video file bundled in the zip; `nil` when the
    /// user did not opt to include heavy media (metadata-only export). This is how
    /// restore knows whether bundled bytes exist versus needing to relink or skip.
    public var mediaFileName: String?

    public init(
        id: UUID,
        sessionID: UUID? = nil,
        spotID: UUID? = nil,
        markerID: UUID? = nil,
        assetCloudIdentifier: String? = nil,
        isVideo: Bool = false,
        createdAt: Date,
        thumbnailFileName: String? = nil,
        mediaFileName: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.spotID = spotID
        self.markerID = markerID
        self.assetCloudIdentifier = assetCloudIdentifier
        self.isVideo = isVideo
        self.createdAt = createdAt
        self.thumbnailFileName = thumbnailFileName
        self.mediaFileName = mediaFileName
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

/// The top-level backup container (the zip's `manifest.json`). Bump
/// ``currentFormatVersion`` whenever the shape changes; ``decode(_:)`` rejects
/// archives from a *newer* format than this build understands, and treats any JSON
/// that doesn't match the expected shape as ``BackupArchiveError/malformed(_:)``
/// rather than crashing.
public struct BackupArchive: Codable, Sendable, Equatable {
    /// The format version this build writes and can read. Version 1 is the zip-container
    /// model: this JSON manifest carries metadata only, while media (audio, photo/video
    /// originals, thumbnails) travels as discrete files alongside it in the zip.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// When this archive was produced.
    public var exportedAt: Date
    /// The app version that produced it, purely informational.
    public var appVersion: String?
    public var sessions: [DiveSession]
    public var spots: [SpotBackup]
    public var trips: [TripBackup]
    /// Photo/video attachment metadata. The bytes (thumbnail + optional original) live
    /// as separate files in the zip, referenced by name; see ``PhotoBackup``.
    public var photos: [PhotoBackup]

    public init(
        formatVersion: Int = BackupArchive.currentFormatVersion,
        exportedAt: Date,
        appVersion: String? = nil,
        sessions: [DiveSession] = [],
        spots: [SpotBackup] = [],
        trips: [TripBackup] = [],
        photos: [PhotoBackup] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.sessions = sessions
        self.spots = spots
        self.trips = trips
        self.photos = photos
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
