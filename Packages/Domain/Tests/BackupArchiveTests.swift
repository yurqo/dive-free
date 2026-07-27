import Foundation
import Testing
@testable import Domain

/// Tests for the pure `BackupArchive` manifest format (the zip-container model):
/// full round-trip (nested `DiveSession`s + photo metadata, no embedded media
/// bytes), version gating, malformed-input handling, deterministic bytes, and the
/// empty archive.
@Suite("BackupArchive")
struct BackupArchiveTests {
    // MARK: - Fixtures

    /// A `Date` `t` seconds past the epoch.
    private func d(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

    /// Two sessions, each with dives/markers/track/samples; the first carries a
    /// voice-note marker whose `audioFileName` names the audio file bundled in the zip.
    private func session1() -> DiveSession {
        let dive = Dive(
            startTime: d(60),
            endTime: d(90),
            maxDepthMeters: 12,
            samples: [
                DepthSample(timestamp: d(60), depthMeters: 0),
                DepthSample(timestamp: d(75), depthMeters: 12),
                DepthSample(timestamp: d(90), depthMeters: 0),
            ]
        )
        let markers = [
            EventMarker(timestamp: d(75), kind: .wildlife, text: "Turtle"),
            EventMarker(timestamp: d(80), kind: .note, text: "voice", audioFileName: "note-1.m4a"),
        ]
        let track = [
            TrackPoint(timestamp: d(0), location: GeoPoint(latitude: 10.0, longitude: 20.0)),
            TrackPoint(timestamp: d(120), location: GeoPoint(latitude: 10.001, longitude: 20.001)),
        ]
        return DiveSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            startTime: d(0),
            endTime: d(210),
            dives: [dive],
            markers: markers,
            location: GeoPoint(latitude: 10.0, longitude: 20.0),
            track: track,
            heartRateSamples: [HeartRateSample(timestamp: d(75), bpm: 82)],
            temperatureSamples: [TemperatureSample(timestamp: d(75), celsius: 21)],
            locationName: "Blue Hole",
            title: "Morning session",
            notes: "Great, viz 30m",
            rating: 4,
            smoothTrack: false
        )
    }

    private func session2() -> DiveSession {
        let dive = Dive(
            startTime: d(300),
            endTime: d(330),
            maxDepthMeters: 18,
            samples: [
                DepthSample(timestamp: d(300), depthMeters: 0),
                DepthSample(timestamp: d(315), depthMeters: 18),
                DepthSample(timestamp: d(330), depthMeters: 0),
            ]
        )
        return DiveSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
            startTime: d(250),
            endTime: d(400),
            dives: [dive],
            markers: [EventMarker(timestamp: d(315), kind: .note, text: "deep")],
            location: GeoPoint(latitude: 11.0, longitude: 21.0),
            title: "Afternoon session",
            smoothTrack: false
        )
    }

    /// Three photos exercising every `mediaFileName`/`thumbnailFileName` combination:
    /// a session photo with both thumbnail + full media, a metadata-only spot photo
    /// (`mediaFileName == nil`), and a marker-linked video.
    private func photos(session1ID: UUID, session2ID: UUID, spotID: UUID, markerID: UUID) -> [PhotoBackup] {
        [
            PhotoBackup(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!,
                sessionID: session1ID,
                assetCloudIdentifier: "cloud-photo-1",
                isVideo: false,
                createdAt: d(70),
                thumbnailFileName: "thumb-1.jpg",
                mediaFileName: "photo-1.heic"
            ),
            PhotoBackup(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!,
                spotID: spotID,
                assetCloudIdentifier: "cloud-photo-2",
                isVideo: false,
                createdAt: d(72),
                thumbnailFileName: "thumb-2.jpg",
                mediaFileName: nil // metadata-only: relink from iCloud on restore
            ),
            PhotoBackup(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!,
                sessionID: session2ID,
                markerID: markerID,
                assetCloudIdentifier: "cloud-video-3",
                isVideo: true,
                createdAt: d(320),
                thumbnailFileName: "thumb-3.jpg",
                mediaFileName: "video-3.mov"
            ),
        ]
    }

    /// A full archive: 2 sessions, 2 spots (with session IDs), 1 trip, 3 photos.
    private func fixture() -> BackupArchive {
        let s1 = session1()
        let s2 = session2()
        let spot1 = SpotBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            name: "Blue Hole",
            latitude: 10.0,
            longitude: 20.0,
            country: "Egypt",
            countryCode: "EG",
            notes: "Deep",
            createdAt: d(0),
            sessionIDs: [s1.id]
        )
        let spot2 = SpotBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
            name: "Reef",
            latitude: 11.0,
            longitude: 21.0,
            createdAt: d(5),
            sessionIDs: [s2.id]
        )
        let trip = TripBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            name: "Red Sea 2026",
            startDate: d(0),
            endDate: d(1000),
            notes: "Liveaboard",
            createdAt: d(0),
            sessionIDs: [s1.id, s2.id]
        )
        let markerID = s2.markers[0].id
        return BackupArchive(
            exportedAt: d(500),
            appVersion: "1.2.0",
            sessions: [s1, s2],
            spots: [spot1, spot2],
            trips: [trip],
            photos: photos(session1ID: s1.id, session2ID: s2.id, spotID: spot1.id, markerID: markerID)
        )
    }

    // MARK: - Round-trip

    @Test("full archive survives encode → decode unchanged")
    func roundTrip() throws {
        let original = fixture()
        let data = try original.encoded()
        let decoded = try BackupArchive.decode(data)
        #expect(decoded == original)
    }

    @Test("photo metadata (video, metadata-only, and full media) round-trips")
    func photosRoundTrip() throws {
        let original = fixture()
        let decoded = try BackupArchive.decode(try original.encoded())
        #expect(decoded.photos == original.photos)
        #expect(decoded.photos.count == 3)

        let withMedia = try #require(decoded.photos.first { $0.id == original.photos[0].id })
        #expect(withMedia.thumbnailFileName == "thumb-1.jpg")
        #expect(withMedia.mediaFileName == "photo-1.heic")
        #expect(withMedia.sessionID == original.sessions[0].id)
        #expect(withMedia.isVideo == false)

        let metadataOnly = try #require(decoded.photos.first { $0.id == original.photos[1].id })
        #expect(metadataOnly.mediaFileName == nil)
        #expect(metadataOnly.thumbnailFileName == "thumb-2.jpg")
        #expect(metadataOnly.spotID == original.spots[0].id)
        #expect(metadataOnly.assetCloudIdentifier == "cloud-photo-2")

        let video = try #require(decoded.photos.first { $0.id == original.photos[2].id })
        #expect(video.isVideo == true)
        #expect(video.mediaFileName == "video-3.mov")
        #expect(video.markerID == original.sessions[1].markers[0].id)
    }

    @Test("the manifest embeds no media bytes (no base64 audio/photo blobs)")
    func noEmbeddedMediaBytes() throws {
        let json = String(decoding: try fixture().encoded(), as: UTF8.self)
        // Media travels as files in the zip, never as base64 inside the JSON.
        #expect(!json.contains("\"audio\""))
        // Only file-name references appear, never raw bytes.
        #expect(json.contains("photo-1.heic"))
        #expect(json.contains("note-1.m4a"))
    }

    @Test("nested session relationships round-trip")
    func sessionRelationshipsRoundTrip() throws {
        let original = fixture()
        let decoded = try BackupArchive.decode(try original.encoded())
        #expect(decoded.spots.first?.sessionIDs == [original.sessions[0].id])
        #expect(decoded.trips.first?.sessionIDs == [original.sessions[0].id, original.sessions[1].id])
        #expect(decoded.sessions[0].markers.contains { $0.audioFileName == "note-1.m4a" })
    }

    // MARK: - Version gating

    @Test("archive at the current version decodes")
    func currentVersionDecodes() throws {
        let data = try fixture().encoded()
        let decoded = try BackupArchive.decode(data)
        #expect(decoded.formatVersion == BackupArchive.currentFormatVersion)
    }

    @Test("a newer format version is rejected")
    func futureVersionRejected() throws {
        // Encode a normal archive, then bump the version field in the JSON.
        var archive = fixture()
        archive.formatVersion = BackupArchive.currentFormatVersion + 1
        let data = try archive.encoded()
        #expect {
            try BackupArchive.decode(data)
        } throws: { error in
            error as? BackupArchiveError
                == .unsupportedVersion(
                    found: BackupArchive.currentFormatVersion + 1,
                    supported: BackupArchive.currentFormatVersion
                )
        }
    }

    // MARK: - Malformed input

    @Test("non-JSON bytes throw .malformed")
    func nonJSONMalformed() {
        let data = Data("this is not json".utf8)
        #expect {
            try BackupArchive.decode(data)
        } throws: { error in
            if case .malformed = error as? BackupArchiveError { return true }
            return false
        }
    }

    @Test("JSON missing required keys throws .malformed")
    func missingKeysMalformed() {
        // Valid JSON, valid version, but missing sessions/spots/trips/photos.
        let data = Data(#"{"formatVersion":1}"#.utf8)
        #expect {
            try BackupArchive.decode(data)
        } throws: { error in
            if case .malformed = error as? BackupArchiveError { return true }
            return false
        }
    }

    @Test("a manifest of the right version but the wrong shape is .malformed, not a crash")
    func wrongShapeRejectedAsMalformed() {
        // Passes the version gate, then fails the full decode: unknown `audio` key and no
        // `photos`. Must surface as a clean `.malformed`, never a raw DecodingError.
        let data = Data(#"""
        {"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","sessions":[],"spots":[],"trips":[],"audio":{"note-1.m4a":"3q2+7wABAg=="}}
        """#.utf8)
        #expect {
            try BackupArchive.decode(data)
        } throws: { error in
            if case .malformed = error as? BackupArchiveError { return true }
            return false
        }
    }

    @Test("JSON missing formatVersion throws .malformed, not a raw DecodingError")
    func missingVersionMalformed() {
        let data = Data(#"{"exportedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        #expect {
            try BackupArchive.decode(data)
        } throws: { error in
            if case .malformed = error as? BackupArchiveError { return true }
            return false
        }
    }

    // MARK: - Determinism

    @Test("encoded() is byte-stable across two runs")
    func deterministicEncoding() throws {
        let archive = fixture()
        #expect(try archive.encoded() == archive.encoded())
    }

    // MARK: - Empty archive

    @Test("an empty archive round-trips")
    func emptyRoundTrip() throws {
        let empty = BackupArchive(exportedAt: d(0))
        let decoded = try BackupArchive.decode(try empty.encoded())
        #expect(decoded == empty)
        #expect(decoded.sessions.isEmpty)
        #expect(decoded.spots.isEmpty)
        #expect(decoded.trips.isEmpty)
        #expect(decoded.photos.isEmpty)
    }
}
