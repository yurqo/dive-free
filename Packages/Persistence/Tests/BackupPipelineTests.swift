import Foundation
import SwiftData
import Testing
@testable import Persistence
import Domain

/// End-to-end backup pipeline tests: `stageArchive` → `ZipContainer.zip` →
/// `ZipContainer.unzip` → `BackupRestore.restore`, exactly as the iPhone app runs it.
///
/// The existing `ZipContainerTests` and `BackupRestoreTests` each cover only one hop:
/// zip/unzip over synthetic dirs, and stage→restore over plain directories. Nothing
/// exercised the full seam with a *realistic* full backup (many entries across all four
/// media subdirs, larger high-entropy binaries, boundary-sized files). This suite fills
/// that gap and guards the round-trip.
@Suite("BackupPipeline")
@MainActor
struct BackupPipelineTests {

    // MARK: - Deterministic pseudo-random bytes

    /// A splitmix64-seeded byte blob of an exact size — high-entropy but reproducible, so
    /// a failure is deterministic. Realistic media is entropy-compressed (heic/mp4), which
    /// tiny patterned test fixtures don't resemble.
    private func bytes(seed: UInt64, count: Int) -> Data {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var out = Data(capacity: count)
        var buffer = [UInt8]()
        buffer.reserveCapacity(8)
        while out.count < count {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            buffer.removeAll(keepingCapacity: true)
            for shift in stride(from: 0, through: 56, by: 8) {
                buffer.append(UInt8((z >> UInt64(shift)) & 0xFF))
            }
            let take = min(8, count - out.count)
            out.append(contentsOf: buffer.prefix(take))
        }
        return out
    }

    // MARK: - Temp dirs

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixture shapes

    private struct MediaFixture {
        var id: UUID
        var isVideo: Bool
        var ext: String
        var thumbnail: Data
        var original: Data
    }

    // MARK: - The full round-trip

    @Test("stage → zip → unzip → restore round-trips a realistic full backup")
    func fullRoundTrip() async throws {
        let chunk = 1 << 20  // ZipContainer's copy granularity — probe both sides of it.

        // A source store with several sessions, spots, trips, and voice-note markers.
        let source = try DiveStore(inMemory: true)
        let srcCtx = source.container.mainContext
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        var voiceBytesByName: [String: Data] = [:]
        var sessionIDs: [UUID] = []
        for s in 0..<4 {
            let base = t0.addingTimeInterval(Double(s) * 100_000)
            let clipName = "voice-\(s).m4a"
            let session = DiveSession(
                startTime: base,
                endTime: base.addingTimeInterval(3600),
                dives: [
                    Dive(
                        startTime: base.addingTimeInterval(10),
                        endTime: base.addingTimeInterval(90),
                        maxDepthMeters: Double(10 + s),
                        samples: [DepthSample(timestamp: base.addingTimeInterval(40), depthMeters: Double(10 + s))]
                    )
                ],
                markers: [
                    EventMarker(timestamp: base.addingTimeInterval(45), kind: .wildlife, text: "turtle \(s)", audioFileName: clipName)
                ],
                location: GeoPoint(latitude: 20.0 + Double(s), longitude: -87.0)
            )
            let record = SessionRecord(from: session)
            srcCtx.insert(record)
            sessionIDs.append(session.id)
            // Realistic voice-note bytes; also mirror onto the marker (both export paths).
            let clip = bytes(seed: 0xA0000 &+ UInt64(s), count: 40_000 + s * 9_000)
            voiceBytesByName[clipName] = clip
            if let marker = (record.markers ?? []).first {
                marker.audioData = clip
            }
        }

        let spot = Spot(name: "Blue Hole", centerLatitude: 20.0, centerLongitude: -87.0, notes: "deep")
        srcCtx.insert(spot)
        let trip = Trip(name: "Trip", startDate: t0, endDate: t0.addingTimeInterval(300_000), notes: "week")
        srcCtx.insert(trip)
        // Link the first session to both.
        let firstSession = try srcCtx.fetch(FetchDescriptor<SessionRecord>()).first { $0.id == sessionIDs[0] }
        firstSession?.spot = spot
        firstSession?.trip = trip

        // Photos + videos across a spread of sizes, including chunk-boundary and zero-byte
        // originals — the cases a full library hits but synthetic fixtures skip.
        var fixtures: [MediaFixture] = []
        let photoSizes = [0, 1, chunk - 1, chunk, chunk + 1, 300_000, 2_500_000, 4_000_000, 512, chunk * 2]
        for (i, size) in photoSizes.enumerated() {
            let id = UUID()
            fixtures.append(MediaFixture(
                id: id,
                isVideo: false,
                ext: "heic",
                thumbnail: bytes(seed: 0xB0000 &+ UInt64(i), count: 60_000 + i * 3_000),
                original: bytes(seed: 0xC0000 &+ UInt64(i), count: size)
            ))
        }
        let videoSizes = [chunk * 5 + 7, 8_000_000, chunk * 3, 15_000_000]
        for (i, size) in videoSizes.enumerated() {
            let id = UUID()
            fixtures.append(MediaFixture(
                id: id,
                isVideo: true,
                ext: "mp4",
                thumbnail: bytes(seed: 0xD0000 &+ UInt64(i), count: 70_000 + i * 2_500),
                original: bytes(seed: 0xE0000 &+ UInt64(i), count: size)
            ))
        }

        // Insert PhotoRecords (some attached to the first session/spot) with thumbnailData.
        let fixturesByID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        for (i, f) in fixtures.enumerated() {
            let record = PhotoRecord(
                id: f.id,
                assetIdentifier: "local-\(f.id)",
                thumbnailData: f.thumbnail,
                assetCloudIdentifier: "cloud-\(f.id)",
                createdAt: t0.addingTimeInterval(Double(i)),
                isVideo: f.isVideo,
                session: i % 2 == 0 ? firstSession : nil,
                spot: i % 3 == 0 ? spot : nil
            )
            srcCtx.insert(record)
        }
        try srcCtx.save()

        // --- Stage (app: BackupService.exportBackup) ---
        let staging = try makeDir()
        let archive = try await BackupRestore(context: srcCtx).stageArchive(
            into: staging,
            appVersion: "1.3.2",
            options: BackupExportOptions(includeVoiceNotes: true, includePhotos: true, includeVideos: true),
            audioBytes: { voiceBytesByName[$0] },
            thumbnailBytes: { _ in nil },  // fall back to record.thumbnailData, like a cache miss
            mediaFileExtension: { ref in fixturesByID[ref.id]?.ext },
            writePhotoMedia: { ref, dest in
                guard let f = fixturesByID[ref.id] else { return false }
                do { try f.original.write(to: dest); return true } catch { return false }
            }
        )
        #expect(archive.sessions.count == 4)
        #expect(archive.photos.count == fixtures.count)

        // --- Zip (app runs this off the main actor) ---
        let zipURL = try makeDir().appendingPathComponent("backup.zip")
        try ZipContainer.zip(directory: staging, to: zipURL)

        // --- Unzip into a fresh, empty directory ---
        let restoreDir = try makeDir().appendingPathComponent("unzipped", isDirectory: true)
        try ZipContainer.unzip(zipURL, to: restoreDir)

        // --- Restore into a SECOND fresh store ---
        let dest = try DiveStore(inMemory: true)
        let destCtx = dest.container.mainContext
        var materializedAudio: [String: Data] = [:]
        var reimportedMedia: [UUID: Data] = [:]
        let summary = try BackupRestore(context: destCtx).restore(
            fromStagingDirectory: restoreDir,
            materializeAudio: { name, data in materializedAudio[name] = data; return true },
            reimportPhoto: { pb, url in
                if let url, let data = try? Data(contentsOf: url) { reimportedMedia[pb.id] = data }
                return "reimported-\(pb.id)"
            }
        )

        // --- Assertions: counts ---
        #expect(summary.sessionsImported == 4)
        #expect(summary.spotsCreated == 1)
        #expect(summary.tripsCreated == 1)
        #expect(summary.photosRestored == fixtures.count)
        #expect(try destCtx.fetch(FetchDescriptor<SessionRecord>()).count == 4)
        #expect(try destCtx.fetch(FetchDescriptor<Spot>()).count == 1)
        #expect(try destCtx.fetch(FetchDescriptor<Trip>()).count == 1)
        #expect(try destCtx.fetch(FetchDescriptor<PhotoRecord>()).count == fixtures.count)

        // --- Voice-note byte-compare (every clip survived the round-trip) ---
        #expect(materializedAudio.count == voiceBytesByName.count)
        for (name, expected) in voiceBytesByName {
            #expect(materializedAudio[name] == expected, "voice note \(name) bytes differ after round-trip")
        }

        // --- Media original byte-compare (all sizes incl. boundaries + zero-byte) ---
        #expect(reimportedMedia.count == fixtures.count)
        for f in fixtures {
            #expect(reimportedMedia[f.id] == f.original, "media \(f.id) (\(f.original.count) bytes) differs after round-trip")
        }

        // --- Thumbnail byte-compare (mirrored into the restored record) ---
        let restoredPhotos = try destCtx.fetch(FetchDescriptor<PhotoRecord>())
        for record in restoredPhotos {
            let f = fixturesByID[record.id]
            #expect(f != nil)
            #expect(record.thumbnailData == f?.thumbnail, "thumbnail \(record.id) differs after round-trip")
        }
    }

    // MARK: - Raw ZipContainer stress (many entries, empty dirs, nesting, boundaries)

    /// Snapshots every regular file under `dir` as relative-path → bytes.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path + "/"
        var out: [String: Data] = [:]
        let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            out[String(full.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return out
    }

    @Test("zip/unzip round-trips hundreds of entries with nesting, empty dirs and boundary sizes")
    func manyEntriesRoundTrip() throws {
        let fm = FileManager.default
        let chunk = 1 << 20
        let src = try makeDir()

        // A realistic "everything" tree: manifest + hundreds of thumbnails/originals/voice
        // across the four subdirs, plus a deeply nested path and an (empty) directory.
        var expected: [String: Data] = [:]
        func put(_ path: String, _ data: Data) throws {
            let url = src.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            expected[path] = data
        }

        try put("manifest.json", bytes(seed: 1, count: 20_000))
        for i in 0..<250 {
            let id = UUID().uuidString
            try put("thumbnails/\(id).jpg", bytes(seed: 0x1000 &+ UInt64(i), count: 40_000 + (i % 7) * 5_000))
            // Vary original sizes around the chunk boundary and include a zero-byte entry.
            let sizes = [0, 1, chunk - 1, chunk, chunk + 1, 250_000]
            try put("photos/\(id).heic", bytes(seed: 0x2000 &+ UInt64(i), count: sizes[i % sizes.count]))
        }
        for i in 0..<20 {
            try put("videos/\(UUID().uuidString).mp4", bytes(seed: 0x3000 &+ UInt64(i), count: chunk * 2 + i))
        }
        for i in 0..<40 {
            try put("voice/voice-\(i).m4a", bytes(seed: 0x4000 &+ UInt64(i), count: 30_000 + i * 800))
        }
        // Deeply nested path + an empty directory (writer skips empties; must not break).
        try put("a/b/c/d/e/deep.bin", bytes(seed: 0x5000, count: chunk + 999))
        try fm.createDirectory(at: src.appendingPathComponent("empty/sub"), withIntermediateDirectories: true)

        let zipURL = try makeDir().appendingPathComponent("many.zip")
        try ZipContainer.zip(directory: src, to: zipURL)

        let dest = try makeDir().appendingPathComponent("out", isDirectory: true)
        try ZipContainer.unzip(zipURL, to: dest)

        #expect(try snapshot(dest) == expected)
    }
}
