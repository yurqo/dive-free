import Foundation
import SwiftData
import Testing
@testable import Persistence
import Domain

@Suite("BackupRestore")
@MainActor
struct BackupRestoreTests {
    // MARK: - Temp dir helper

    /// A fresh, empty temp directory for a single test's staging tree, removed after.
    private func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(in dir: URL, sub: String) -> [String] {
        let url = dir.appendingPathComponent(sub, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.lastPathComponent }.sorted()
    }

    private func exists(_ dir: URL, _ sub: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(sub).path)
    }

    // MARK: - Fixtures

    /// A session with a spot + trip and a marker carrying a voice note.
    private func makeAnchoredSession(t0: Date) -> DiveSession {
        DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(3600),
            dives: [
                Dive(
                    startTime: t0.addingTimeInterval(10),
                    endTime: t0.addingTimeInterval(80),
                    maxDepthMeters: 12.5,
                    samples: [DepthSample(timestamp: t0.addingTimeInterval(40), depthMeters: 12.5)]
                )
            ],
            markers: [
                EventMarker(timestamp: t0.addingTimeInterval(45), kind: .wildlife, text: "turtle", audioFileName: "voice-1.m4a")
            ],
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
    }

    /// A located session with no spot/trip — restore must leave it spot-less (it does
    /// NOT run the proximity assigner; it faithfully reproduces the archived state).
    private func makeSpotlessSession(t0: Date) -> DiveSession {
        DiveSession(
            startTime: t0.addingTimeInterval(10_000),
            endTime: t0.addingTimeInterval(10_600),
            location: GeoPoint(latitude: 10.0, longitude: 10.0),
            locationName: "Far reef"
        )
    }

    private struct Seed {
        var store: DiveStore
        var anchoredID: UUID
        var spotlessID: UUID
        var spotID: UUID
        var tripID: UUID
        var markerID: UUID
        var sessionPhotoID: UUID
        var spotPhotoID: UUID
        var markerPhotoID: UUID
        var videoPhotoID: UUID
    }

    /// Seeds a fresh in-memory store with the two sessions, a spot + trip linked to the
    /// anchored one, and four photos (session-, spot-, marker-linked, and a video).
    private func seedSourceStore() throws -> Seed {
        let store = try DiveStore(inMemory: true)
        let context = store.container.mainContext
        let t0 = Date(timeIntervalSince1970: 0)

        let anchored = makeAnchoredSession(t0: t0)
        let spotless = makeSpotlessSession(t0: t0)
        let anchoredRecord = SessionRecord(from: anchored)
        let spotlessRecord = SessionRecord(from: spotless)
        context.insert(anchoredRecord)
        context.insert(spotlessRecord)

        let spot = Spot(name: "Blue Hole", centerLatitude: 20.5, centerLongitude: -87.0, notes: "deep")
        context.insert(spot)
        anchoredRecord.spot = spot

        let trip = Trip(name: "Yucatán 2026", startDate: t0, endDate: t0.addingTimeInterval(3600), notes: "week trip")
        context.insert(trip)
        anchoredRecord.trip = trip

        let marker = (anchoredRecord.markers ?? []).first!

        // Photos: one on the session, one on the spot, one on the marker, one video.
        let sessionPhoto = PhotoRecord(
            assetIdentifier: "local-session",
            thumbnailData: Data("thumb-session".utf8),
            assetCloudIdentifier: "cloud-session",
            session: anchoredRecord
        )
        let spotPhoto = PhotoRecord(
            assetIdentifier: "local-spot",
            thumbnailData: Data("thumb-spot".utf8),
            assetCloudIdentifier: "cloud-spot",
            spot: spot
        )
        let markerPhoto = PhotoRecord(
            assetIdentifier: "local-marker",
            thumbnailData: Data("thumb-marker".utf8),
            assetCloudIdentifier: "cloud-marker",
            session: anchoredRecord,
            marker: marker
        )
        let videoPhoto = PhotoRecord(
            assetIdentifier: "local-video",
            thumbnailData: Data("thumb-video".utf8),
            assetCloudIdentifier: "cloud-video",
            isVideo: true,
            session: anchoredRecord
        )
        context.insert(sessionPhoto)
        context.insert(spotPhoto)
        context.insert(markerPhoto)
        context.insert(videoPhoto)

        try context.save()
        return Seed(
            store: store,
            anchoredID: anchored.id,
            spotlessID: spotless.id,
            spotID: spot.id,
            tripID: trip.id,
            markerID: marker.id,
            sessionPhotoID: sessionPhoto.id,
            spotPhotoID: spotPhoto.id,
            markerPhotoID: markerPhoto.id,
            videoPhotoID: videoPhoto.id
        )
    }

    // MARK: - Export: options gate what gets staged

    @Test("export with all options off stages manifest + thumbnails only")
    func exportMetadataOnly() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            appVersion: "1.3.0",
            options: BackupExportOptions()  // all false
        )

        // Manifest present and carries all metadata regardless of toggles.
        #expect(exists(staging, "manifest.json"))
        #expect(archive.sessions.count == 2)
        #expect(archive.spots.count == 1)
        #expect(archive.trips.count == 1)
        #expect(archive.photos.count == 4)

        // Thumbnails always attempted (records carry thumbnailData) → 4 files.
        #expect(names(in: staging, sub: "thumbnails").count == 4)
        // No heavy media staged.
        #expect(!exists(staging, "voice"))
        #expect(!exists(staging, "photos"))
        #expect(!exists(staging, "videos"))

        // Every PhotoBackup has a thumbnail name but no media name.
        #expect(archive.photos.allSatisfy { $0.thumbnailFileName != nil })
        #expect(archive.photos.allSatisfy { $0.mediaFileName == nil })
    }

    @Test("each toggle adds exactly the right files")
    func exportTogglesAddFiles() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()

        var writeCalls: [BackupRestore.PhotoRef] = []
        let archive = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions(includeVoiceNotes: true, includePhotos: true, includeVideos: true),
            audioBytes: { $0 == "voice-1.m4a" ? Data("m4a".utf8) : nil },
            writePhotoMedia: { ref, url in
                writeCalls.append(ref)
                try? Data("media-\(ref.id)".utf8).write(to: url)
                return true
            }
        )

        #expect(names(in: staging, sub: "voice") == ["voice-1.m4a"])
        // 3 non-video photos → photos/, 1 video → videos/.
        #expect(names(in: staging, sub: "photos").count == 3)
        #expect(names(in: staging, sub: "videos").count == 1)
        #expect(names(in: staging, sub: "thumbnails").count == 4)

        // writePhotoMedia called once per photo; the video ref is flagged isVideo.
        #expect(writeCalls.count == 4)
        #expect(writeCalls.first { $0.id == source.videoPhotoID }?.isVideo == true)

        // Manifest media names reflect what was written.
        let videoBackup = archive.photos.first { $0.id == source.videoPhotoID }
        #expect(videoBackup?.mediaFileName == "\(source.videoPhotoID.uuidString).mov")
        let sessionBackup = archive.photos.first { $0.id == source.sessionPhotoID }
        #expect(sessionBackup?.mediaFileName == "\(source.sessionPhotoID.uuidString).jpg")
    }

    @Test("includePhotos on but includeVideos off stages photos, not videos")
    func exportPhotosButNotVideos() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions(includePhotos: true, includeVideos: false),
            writePhotoMedia: { _, url in try? Data("x".utf8).write(to: url); return true }
        )
        #expect(names(in: staging, sub: "photos").count == 3)
        #expect(!exists(staging, "videos"))
        #expect(archive.photos.first { $0.isVideo }?.mediaFileName == nil)
    }

    @Test("writePhotoMedia returning false leaves mediaFileName nil and no file")
    func exportMediaWriteFailure() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions(includePhotos: true),
            writePhotoMedia: { _, url in try? Data("partial".utf8).write(to: url); return false }
        )
        // Partial files removed; no successful photo media.
        #expect(names(in: staging, sub: "photos").isEmpty)
        #expect(archive.photos.filter { !$0.isVideo }.allSatisfy { $0.mediaFileName == nil })
    }

    @Test("staged names and the manifest carry the original's real extension, sanitized")
    func exportUsesRealMediaExtension() async throws {
        let source = try seedSourceStore()
        let context = source.store.container.mainContext

        // PhotoKit reports what the bytes actually are — HEIC stills, MP4 clips — and the
        // staged file must say so, or the re-import on restore silently drops it.
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: context).stageArchive(
            into: staging,
            options: BackupExportOptions(includePhotos: true, includeVideos: true),
            mediaFileExtension: { $0.isVideo ? "MP4" : "heic" },
            writePhotoMedia: { ref, url in try? Data("orig-\(ref.id)".utf8).write(to: url); return true }
        )
        #expect(names(in: staging, sub: "photos").allSatisfy { $0.hasSuffix(".heic") })
        #expect(names(in: staging, sub: "videos") == ["\(source.videoPhotoID.uuidString).mp4"])
        #expect(
            archive.photos.first { $0.id == source.videoPhotoID }?.mediaFileName
                == "\(source.videoPhotoID.uuidString).mp4"
        )

        // Restore finds those files by their manifest names, whatever the extension.
        let dest = try DiveStore(inMemory: true)
        var seen: [UUID: URL] = [:]
        _ = try BackupRestore(context: dest.container.mainContext).restore(
            fromStagingDirectory: staging,
            reimportPhoto: { pb, url in
                if let url { seen[pb.id] = url }
                return "reimported-\(pb.id)"
            }
        )
        #expect(seen.count == 4)
        #expect(seen[source.videoPhotoID]?.pathExtension == "mp4")

        // A path-ish extension is scrubbed to a plain suffix — it can't escape the tree.
        let hostile = try makeStagingDir()
        let hostileArchive = try await BackupRestore(context: context).stageArchive(
            into: hostile,
            options: BackupExportOptions(includePhotos: true),
            mediaFileExtension: { _ in "../../ev/il" },
            writePhotoMedia: { _, url in try? Data("x".utf8).write(to: url); return true }
        )
        #expect(
            hostileArchive.photos.filter { !$0.isVideo }
                .allSatisfy { $0.mediaFileName == "\($0.id.uuidString).evil" }
        )
        #expect(names(in: hostile, sub: "photos").count == 3)

        // Nothing usable reported → the jpg/mov convention still applies.
        let fallback = try makeStagingDir()
        let fallbackArchive = try await BackupRestore(context: context).stageArchive(
            into: fallback,
            options: BackupExportOptions(includeVideos: true),
            mediaFileExtension: { _ in "" },
            writePhotoMedia: { _, url in try? Data("x".utf8).write(to: url); return true }
        )
        #expect(
            fallbackArchive.photos.first { $0.isVideo }?.mediaFileName
                == "\(source.videoPhotoID.uuidString).mov"
        )
    }

    // MARK: - Round-trip via staging

    @Test("export then restore recreates sessions, spot/trip links, photos, and mirrors audio")
    func roundTrip() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        let clip = Data("m4a-bytes".utf8)

        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            appVersion: "1.3.0",
            options: BackupExportOptions(includeVoiceNotes: true, includePhotos: true, includeVideos: true),
            audioBytes: { $0 == "voice-1.m4a" ? clip : nil },
            writePhotoMedia: { ref, url in try? Data("orig-\(ref.id)".utf8).write(to: url); return true }
        )

        // Restore into a FRESH store.
        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        var materialized: [String: Data] = [:]
        var reimportCalls: [(id: UUID, url: URL?)] = []
        let summary = try BackupRestore(context: context).restore(
            fromStagingDirectory: staging,
            materializeAudio: { name, data in materialized[name] = data; return true },
            reimportPhoto: { pb, url in
                reimportCalls.append((pb.id, url))
                return "reimported-\(pb.id)"
            }
        )

        // Summary counts.
        #expect(summary.sessionsImported == 2)
        #expect(summary.sessionsSkipped == 0)
        #expect(summary.spotsCreated == 1)
        #expect(summary.spotsLinked == 1)
        #expect(summary.tripsCreated == 1)
        #expect(summary.tripsLinked == 1)
        #expect(summary.audioRestored == 1)
        #expect(summary.photosRestored == 4)

        // Audio materialized to "disk".
        #expect(materialized == ["voice-1.m4a": clip])

        // Both sessions exist.
        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(sessions.count == 2)
        let anchored = sessions.first { $0.id == source.anchoredID }
        #expect(anchored?.spot?.id == source.spotID)
        #expect(anchored?.spot?.name == "Blue Hole")
        #expect(anchored?.trip?.id == source.tripID)

        // Marker audioData mirrored.
        let mirroredMarker = (anchored?.markers ?? []).first { $0.audioFileName == "voice-1.m4a" }
        #expect(mirroredMarker?.audioData == clip)

        // Photos recreated + reattached (session, spot, AND marker links) + thumbnails.
        let photos = try context.fetch(FetchDescriptor<PhotoRecord>())
        #expect(photos.count == 4)
        let sessionPhoto = photos.first { $0.id == source.sessionPhotoID }
        #expect(sessionPhoto?.session?.id == source.anchoredID)
        #expect(sessionPhoto?.assetCloudIdentifier == "cloud-session")
        #expect(sessionPhoto?.assetIdentifier == "reimported-\(source.sessionPhotoID)")
        #expect(sessionPhoto?.thumbnailData == Data("thumb-session".utf8))

        let spotPhoto = photos.first { $0.id == source.spotPhotoID }
        #expect(spotPhoto?.spot?.id == source.spotID)

        let markerPhoto = photos.first { $0.id == source.markerPhotoID }
        #expect(markerPhoto?.marker?.id == source.markerID)
        #expect(markerPhoto?.session?.id == source.anchoredID)

        let videoPhoto = photos.first { $0.id == source.videoPhotoID }
        #expect(videoPhoto?.isVideo == true)

        // reimportPhoto received the bundled file URL for each photo.
        #expect(reimportCalls.count == 4)
        #expect(reimportCalls.allSatisfy { $0.url != nil })

        // Spotless session stays spot-less.
        #expect(sessions.first { $0.id == source.spotlessID }?.spot == nil)
    }

    @Test("metadata-only restore passes nil media URL to reimportPhoto and restores thumbnails")
    func restoreMetadataOnly() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions()  // all off → thumbnails only
        )

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        var reimportURLs: [URL?] = []
        let summary = try BackupRestore(context: context).restore(
            fromStagingDirectory: staging,
            reimportPhoto: { _, url in reimportURLs.append(url); return nil }
        )

        #expect(summary.photosRestored == 4)
        #expect(reimportURLs.count == 4)
        #expect(reimportURLs.allSatisfy { $0 == nil })

        // Thumbnails still restored, no local asset id.
        let photos = try context.fetch(FetchDescriptor<PhotoRecord>())
        #expect(photos.allSatisfy { $0.thumbnailData != nil })
        #expect(photos.allSatisfy { $0.assetIdentifier == nil })
    }

    // MARK: - Idempotent re-import

    @Test("restoring the same backup twice imports nothing the second time and creates no duplicates")
    func idempotentReimport() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions()
        )

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let restorer = BackupRestore(context: context)

        let first = try restorer.restore(fromStagingDirectory: staging)
        #expect(first.sessionsImported == 2)
        #expect(first.photosRestored == 4)

        let sessionsAfterFirst = try context.fetch(FetchDescriptor<SessionRecord>()).count
        let spotsAfterFirst = try context.fetch(FetchDescriptor<Spot>()).count
        let tripsAfterFirst = try context.fetch(FetchDescriptor<Trip>()).count
        let photosAfterFirst = try context.fetch(FetchDescriptor<PhotoRecord>()).count

        let second = try restorer.restore(fromStagingDirectory: staging)
        #expect(second.sessionsImported == 0)
        #expect(second.sessionsSkipped == 2)
        #expect(second.spotsCreated == 0)
        #expect(second.tripsCreated == 0)
        #expect(second.spotsLinked == 0)
        #expect(second.tripsLinked == 0)
        #expect(second.photosRestored == 0)  // deduped by id

        #expect(try context.fetch(FetchDescriptor<SessionRecord>()).count == sessionsAfterFirst)
        #expect(try context.fetch(FetchDescriptor<Spot>()).count == spotsAfterFirst)
        #expect(try context.fetch(FetchDescriptor<Trip>()).count == tripsAfterFirst)
        #expect(try context.fetch(FetchDescriptor<PhotoRecord>()).count == photosAfterFirst)
    }

    // MARK: - Additive

    @Test("restore is additive — a pre-existing unrelated session survives")
    func additiveKeepsExisting() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging, options: BackupExportOptions())

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = DiveSession(startTime: Date(timeIntervalSince1970: 500_000))
        context.insert(SessionRecord(from: existing))
        try context.save()

        _ = try BackupRestore(context: context).restore(fromStagingDirectory: staging)

        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(sessions.count == 3)
        #expect(sessions.contains { $0.id == existing.id })
    }

    // MARK: - Preserves existing assignments

    @Test("restore does not clobber a session's existing spot assignment (only nil→set)")
    func preservesExistingSpotAssignment() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging, options: BackupExportOptions())

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = DiveSession(
            id: source.anchoredID,
            startTime: Date(timeIntervalSince1970: 0),
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
        let existingRecord = SessionRecord(from: existing)
        context.insert(existingRecord)
        let spotB = Spot(name: "Cenote Dos Ojos", centerLatitude: 20.3, centerLongitude: -87.4)
        context.insert(spotB)
        existingRecord.spot = spotB
        try context.save()

        let summary = try BackupRestore(context: context).restore(fromStagingDirectory: staging)

        #expect(summary.sessionsSkipped == 1)
        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        let anchored = sessions.first { $0.id == source.anchoredID }
        #expect(anchored?.spot?.id == spotB.id)
        #expect(anchored?.spot?.name == "Cenote Dos Ojos")
        #expect(anchored?.spot?.id != source.spotID)
        #expect(summary.spotsLinked == 0)
    }

    // MARK: - Preserves an existing photo's asset link (data-integrity)

    @Test("restore leaves an existing photo's local asset id untouched and does not re-import it")
    func preservesExistingPhotoAssetLink() async throws {
        // Bundle full-res media for every photo so the vulnerable Phase-B re-import path
        // is armed.
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions(includePhotos: true, includeVideos: true),
            writePhotoMedia: { ref, url in try? Data("orig-\(ref.id)".utf8).write(to: url); return true }
        )

        // The target device already holds the session photo, linked to a good local
        // asset but with no cloud id yet — the exact shape the old code corrupted.
        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = PhotoRecord(
            id: source.sessionPhotoID,
            assetIdentifier: "existing-local-id",
            assetCloudIdentifier: nil
        )
        context.insert(existing)
        try context.save()

        // Spy: record every id the reimport closure is asked about, and hand back a
        // *different* id so any accidental write is visible.
        var reimportedIDs: [UUID] = []
        let summary = try BackupRestore(context: context).restore(
            fromStagingDirectory: staging,
            reimportPhoto: { pb, _ in
                reimportedIDs.append(pb.id)
                return "reimported-\(pb.id)"
            }
        )

        let photos = try context.fetch(FetchDescriptor<PhotoRecord>())
        let restored = photos.first { $0.id == source.sessionPhotoID }

        // The existing link is preserved entirely — id NOT overwritten, no reimport asked.
        #expect(restored?.assetIdentifier == "existing-local-id")
        #expect(!reimportedIDs.contains(source.sessionPhotoID))
        // A nil cloud id is still additively filled from the backup (gap-fill, not clobber).
        #expect(restored?.assetCloudIdentifier == "cloud-session")

        // No duplicate record for that id.
        #expect(photos.filter { $0.id == source.sessionPhotoID }.count == 1)

        // Counters reflect only genuine new work: the 3 other photos are new records and
        // do get re-imported; the pre-existing one is neither restored nor re-imported.
        #expect(summary.photosRestored == 3)
        #expect(reimportedIDs.count == 3)
        #expect(Set(reimportedIDs) == [source.spotPhotoID, source.markerPhotoID, source.videoPhotoID])

        // The 3 new records DID get their id set from the reimport closure.
        let newPhoto = photos.first { $0.id == source.spotPhotoID }
        #expect(newPhoto?.assetIdentifier == "reimported-\(source.spotPhotoID)")
    }

    @Test("restore does not overwrite an existing photo's good cloud id")
    func preservesExistingPhotoCloudID() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging, options: BackupExportOptions())  // metadata only

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let existing = PhotoRecord(
            id: source.sessionPhotoID,
            assetIdentifier: "existing-local-id",
            assetCloudIdentifier: "existing-cloud-id"
        )
        context.insert(existing)
        try context.save()

        _ = try BackupRestore(context: context).restore(fromStagingDirectory: staging)

        let restored = try context.fetch(FetchDescriptor<PhotoRecord>()).first { $0.id == source.sessionPhotoID }
        #expect(restored?.assetIdentifier == "existing-local-id")
        #expect(restored?.assetCloudIdentifier == "existing-cloud-id")  // not clobbered by "cloud-session"
    }

    @Test("restore does not overwrite an existing photo's thumbnail")
    func preservesExistingPhotoThumbnail() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging, options: BackupExportOptions())  // metadata + thumbnails

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        // A record this device already holds, with a freshly regenerated thumbnail. The
        // archive carries an older thumbnail for the same id; since `thumbnailData` is
        // CloudKit-mirrored, overwriting it would push the stale blob to every device.
        let existing = PhotoRecord(id: source.sessionPhotoID, thumbnailData: Data("fresh-thumb".utf8))
        context.insert(existing)
        try context.save()

        _ = try BackupRestore(context: context).restore(fromStagingDirectory: staging)

        let photos = try context.fetch(FetchDescriptor<PhotoRecord>())
        let kept = photos.first { $0.id == source.sessionPhotoID }
        #expect(kept?.thumbnailData == Data("fresh-thumb".utf8))  // not the archived "thumb-session"

        // Still additive the other way: a record with no thumbnail gets one (nil→set).
        #expect(photos.first { $0.id == source.spotPhotoID }?.thumbnailData == Data("thumb-spot".utf8))
    }

    // MARK: - No dangling media references in the manifest

    @Test("a lean backup emits no audioFileName for voice notes it didn't bundle")
    func leanBackupStripsUnbundledAudioReference() async throws {
        let source = try seedSourceStore()
        let context = source.store.container.mainContext
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: context).stageArchive(
            into: staging,
            options: BackupExportOptions()  // voice notes OFF (the default)
        )

        // Nothing bundled → the manifest must not claim a clip that isn't in the zip.
        #expect(!exists(staging, "voice"))
        let exported = archive.sessions.flatMap(\.markers)
        #expect(!exported.isEmpty)
        #expect(exported.allSatisfy { $0.audioFileName == nil })

        // Only the *exported copies* are stripped; the live records keep their audio.
        let live = try context.fetch(FetchDescriptor<SessionRecord>()).flatMap { $0.markers ?? [] }
        #expect(live.contains { $0.audioFileName == "voice-1.m4a" })

        // Restoring it produces markers with no audio reference rather than a broken one.
        let dest = try DiveStore(inMemory: true)
        _ = try BackupRestore(context: dest.container.mainContext).restore(fromStagingDirectory: staging)
        let restored = try dest.container.mainContext
            .fetch(FetchDescriptor<SessionRecord>())
            .flatMap { $0.markers ?? [] }
        #expect(!restored.isEmpty)
        #expect(restored.allSatisfy { $0.audioFileName == nil })
    }

    @Test("voice notes on, but a clip's bytes don't resolve → its reference is dropped too")
    func unresolvableVoiceNoteReferenceDropped() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        let archive = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging,
            options: BackupExportOptions(includeVoiceNotes: true),
            audioBytes: { _ in nil }  // the clip is gone from disk and has no mirrored blob
        )
        #expect(!exists(staging, "voice"))
        #expect(archive.sessions.flatMap(\.markers).allSatisfy { $0.audioFileName == nil })
    }

    // MARK: - Tombstone

    @Test("a tombstoned session id is skipped on restore")
    func tombstonedSessionSkipped() async throws {
        let source = try seedSourceStore()
        let staging = try makeStagingDir()
        _ = try await BackupRestore(context: source.store.container.mainContext).stageArchive(
            into: staging, options: BackupExportOptions())

        let dest = try DiveStore(inMemory: true)
        let context = dest.container.mainContext
        let tombstoned: Set<UUID> = [source.anchoredID]

        let summary = try BackupRestore(context: context).restore(
            fromStagingDirectory: staging,
            isTombstoned: { tombstoned.contains($0) }
        )

        #expect(summary.sessionsImported == 1)
        #expect(summary.sessionsSkipped == 1)

        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == source.spotlessID)
        #expect(!sessions.contains { $0.id == source.anchoredID })
    }

    // MARK: - Missing manifest

    @Test("restore throws on a staging directory with no manifest")
    func restoreMissingManifest() async throws {
        let dest = try DiveStore(inMemory: true)
        let staging = try makeStagingDir()  // empty
        #expect(throws: BackupArchiveError.self) {
            try BackupRestore(context: dest.container.mainContext).restore(fromStagingDirectory: staging)
        }
    }
}
