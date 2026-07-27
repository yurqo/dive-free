import Foundation
import SwiftData
import Domain

/// Assembles a DiveFree backup from the SwiftData store (export) and rebuilds the store
/// from an unzipped backup (restore). This is the *testable core* of backup & restore —
/// it owns the model ↔ manifest mapping, dedupe, and relationship linking.
///
/// ## Layering — Persistence never touches PhotoKit/UIKit
///
/// A backup is a **ZIP container**: a `manifest.json` (the ``BackupArchive``) plus
/// discrete media files. This type builds the manifest and *stages the file tree* into a
/// caller-provided directory; the caller (the app) then zips it with ``ZipContainer``.
/// Every impure edge — resolving a voice note's bytes, a photo's thumbnail, or writing a
/// full-resolution original out of the Photos library — is deferred to an **injected
/// closure**. That keeps Persistence Foundation-only (no PhotoKit) and keeps this type
/// filesystem-deterministic and unit-testable, with the app wiring VoiceNoteStore /
/// PhotoKit into the closures.
///
/// ## Staging layout produced / consumed
///
/// ```
/// manifest.json                 the encoded BackupArchive
/// voice/<audioFileName>         voice-note originals   (only if includeVoiceNotes)
/// thumbnails/<photoID>.jpg      small gallery thumbnails (always attempted)
/// photos/<photoID>.<ext>        full-res photo originals (only if includePhotos)
/// videos/<photoID>.<ext>        full-res video originals (only if includeVideos)
/// ```
///
/// `<ext>` is the original's *real* extension (heic/dng/png/mp4/…), reported by the
/// caller — the bytes are whatever the Photos library stores, and mislabelling them
/// breaks the re-import on restore. Restore locates every file by the name recorded in
/// the manifest, so the extension is never assumed.
///
/// ## Restore is faithfully additive
///
/// Restore reproduces the archive as-is and never overwrites edits the user made on the
/// target device: sessions dedupe by id, spots/trips/photos upsert by id, and a
/// relationship is only ever set when it's currently `nil` (never re-pointed). It
/// deliberately does *not* run the proximity ``SpotAssigner`` — that would recenter
/// archived spots and could spawn near-duplicates, breaking a deterministic restore.
///
/// `@MainActor` because it reads/writes through a SwiftData `ModelContext`, which is
/// main-actor isolated.
@MainActor
public struct BackupRestore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Photo resolution handle

    /// The minimal, PhotoKit-free description of a photo the app needs to resolve its
    /// bytes during export. Passed to the export closures so the app can try a local
    /// (fast, device-only) resolution first and fall back to the cross-device cloud
    /// identifier.
    public struct PhotoRef: Sendable, Equatable {
        /// The `PhotoRecord.id` (also the file basename used in the staging tree).
        public var id: UUID
        /// `PHAsset.localIdentifier` — device-local, fast, may be stale on another device.
        public var assetIdentifier: String?
        /// `PHCloudIdentifier.stringValue` — stable across devices for iCloud relink.
        public var assetCloudIdentifier: String?
        /// Whether the asset is a video (drives which media toggle / staging dir applies).
        public var isVideo: Bool

        public init(id: UUID, assetIdentifier: String?, assetCloudIdentifier: String?, isVideo: Bool) {
            self.id = id
            self.assetIdentifier = assetIdentifier
            self.assetCloudIdentifier = assetCloudIdentifier
            self.isVideo = isVideo
        }
    }

    // MARK: - Export

    /// Builds the ``BackupArchive`` manifest for every session, spot, trip, and photo in
    /// the store and **stages the backup's file tree** into `stagingDir` (creating it if
    /// needed). The caller zips `stagingDir` afterwards (see ``ZipContainer``).
    ///
    /// Metadata always travels; heavy media is opt-in per `options`. Thumbnails are
    /// always attempted so a restored gallery works offline even from a metadata-only
    /// backup.
    ///
    /// - Parameters:
    ///   - stagingDir: an (ideally empty) directory to write `manifest.json` and the
    ///     media subtrees into.
    ///   - appVersion: the producing app version (informational, stored in the manifest).
    ///   - options: which heavy media to bundle (voice/photos/videos).
    ///   - audioBytes: resolves a marker's voice-note file name to its raw bytes (the app
    ///     passes VoiceNoteStore); falls back to the marker's own `audioData`. Only
    ///     consulted when `options.includeVoiceNotes`.
    ///   - thumbnailBytes: resolves a photo's small thumbnail bytes; falls back to the
    ///     record's stored `thumbnailData`. Always attempted.
    ///   - mediaFileExtension: the **real** file extension of the original the caller is
    ///     about to write (`heic`, `dng`, `mp4`, …), so the staged file and the manifest
    ///     name match the bytes. `nil` falls back to `jpg`/`mov`.
    ///   - writePhotoMedia: resolves a photo/video's full-resolution original and *writes*
    ///     it to the given URL, returning whether it succeeded. Only called for a kind
    ///     whose toggle is on. Streaming a large video to disk stays in the app layer.
    /// - Returns: the ``BackupArchive`` that was written to `manifest.json` (handy for a
    ///   size estimate and for tests).
    @discardableResult
    public func stageArchive(
        into stagingDir: URL,
        appVersion: String? = nil,
        options: BackupExportOptions,
        progress: BackupProgressHandler? = nil,
        audioBytes: (String) async -> Data? = { _ in nil },
        thumbnailBytes: (PhotoRef) async -> Data? = { _ in nil },
        mediaFileExtension: (PhotoRef) async -> String? = { _ in nil },
        writePhotoMedia: (PhotoRef, URL) async -> Bool = { _, _ in false }
    ) async throws -> BackupArchive {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        progress?(BackupProgress(phase: .preparing))

        // --- Sessions / spots / trips metadata ---
        let sessionRecords = try context.fetch(FetchDescriptor<SessionRecord>())

        let spots = try context.fetch(FetchDescriptor<Spot>()).map { spot in
            SpotBackup(
                id: spot.id,
                name: spot.name,
                latitude: spot.centerLatitude,
                longitude: spot.centerLongitude,
                country: spot.country,
                countryCode: spot.countryCode,
                notes: spot.notes,
                createdAt: spot.createdAt,
                sessionIDs: (spot.sessions ?? []).map { $0.id }
            )
        }

        let trips = try context.fetch(FetchDescriptor<Trip>()).map { trip in
            TripBackup(
                id: trip.id,
                name: trip.name,
                startDate: trip.startDate,
                endDate: trip.endDate,
                notes: trip.notes,
                createdAt: trip.createdAt,
                sessionIDs: (trip.sessions ?? []).map { $0.id }
            )
        }

        // --- Voice notes (opt-in) ---
        // Resolve each referenced clip once (deduped by file name). Prefer the on-disk
        // file via the injected closure; fall back to the marker's CloudKit-synced blob
        // so a clip that only ever synced as bytes is still captured. Manifest markers
        // already reference `audioFileName`, so no manifest change is needed for audio.
        var bundledAudio: Set<String> = []
        if options.includeVoiceNotes {
            let voiceDir = stagingDir.appendingPathComponent("voice", isDirectory: true)
            // Names first, so the phase has a real total to report against.
            let clipNames = sessionRecords
                .flatMap { ($0.markers ?? []).compactMap(\.audioFileName) }
                .reduce(into: [String]()) { unique, name in
                    if !unique.contains(name) { unique.append(name) }
                }
            let clipBytes: [String: Data] = sessionRecords.reduce(into: [:]) { blobs, record in
                for marker in (record.markers ?? []) {
                    if let name = marker.audioFileName, blobs[name] == nil, let data = marker.audioData {
                        blobs[name] = data
                    }
                }
            }
            progress?(BackupProgress(phase: .voiceNotes, completed: 0, total: clipNames.count))
            for (index, fileName) in clipNames.enumerated() {
                try Task.checkCancellation()
                guard let bytes = await audioBytes(fileName) ?? clipBytes[fileName] else { continue }
                try fm.createDirectory(at: voiceDir, withIntermediateDirectories: true)
                try await Self.write(bytes, to: voiceDir.appendingPathComponent(fileName))
                bundledAudio.insert(fileName)
                progress?(BackupProgress(phase: .voiceNotes, completed: index + 1, total: clipNames.count))
            }
        }

        // Never let the manifest reference a clip the zip doesn't contain. A lean backup
        // (voice notes off — the default) that still carried `audioFileName` would restore
        // markers whose voice note can't play; the same goes for a clip whose bytes didn't
        // resolve. The reference is dropped from the **exported copies only** —
        // `toDomain()` returns detached value types, so the live SwiftData markers keep
        // their audio.
        let sessions = sessionRecords.map { record -> DiveSession in
            var session = record.toDomain()
            session.markers = session.markers.map { marker in
                guard let name = marker.audioFileName, !bundledAudio.contains(name) else { return marker }
                var stripped = marker
                stripped.audioFileName = nil
                return stripped
            }
            return session
        }

        // --- Photos (metadata always; thumbnail always attempted; media opt-in) ---
        let thumbsDir = stagingDir.appendingPathComponent("thumbnails", isDirectory: true)
        let photosDir = stagingDir.appendingPathComponent("photos", isDirectory: true)
        let videosDir = stagingDir.appendingPathComponent("videos", isDirectory: true)

        var photoBackups: [PhotoBackup] = []
        let photoRecords = try context.fetch(FetchDescriptor<PhotoRecord>())
        progress?(BackupProgress(phase: .photos, completed: 0, total: photoRecords.count))
        for (index, record) in photoRecords.enumerated() {
            // Cancellation is checked per photo: this is the long pole (originals may
            // download from iCloud), so it must abort promptly rather than at the end.
            try Task.checkCancellation()
            defer { progress?(BackupProgress(phase: .photos, completed: index + 1, total: photoRecords.count)) }

            // Skip a model already deleted underneath us (reading its properties would
            // trap — the deleted-model crash pattern this codebase guards against).
            guard record.modelContext != nil else { continue }

            let ref = PhotoRef(
                id: record.id,
                assetIdentifier: record.assetIdentifier,
                assetCloudIdentifier: record.assetCloudIdentifier,
                isVideo: record.isVideo
            )

            // Thumbnail: always attempt. Injected closure first, then the stored blob.
            var thumbnailFileName: String?
            if let thumb = await thumbnailBytes(ref) ?? record.thumbnailData {
                let name = "\(record.id.uuidString).jpg"
                try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
                try await Self.write(thumb, to: thumbsDir.appendingPathComponent(name))
                thumbnailFileName = name
            }

            // Full-res media: only for the matching toggle. The extension must describe
            // the bytes the closure actually writes — `PHAssetResourceManager` emits the
            // *original* encoding (HEIC/DNG/PNG stills, `.mp4` clips), and a mislabelled
            // file fails to re-import on restore, silently dropping the user's originals.
            // `mediaFileExtension` reports the real one; the `jpg`/`mov` fallback only
            // applies when the caller can't tell us (e.g. tests).
            var mediaFileName: String?
            let includeMedia = record.isVideo ? options.includeVideos : options.includePhotos
            if includeMedia {
                let ext = Self.sanitizedExtension(await mediaFileExtension(ref))
                    ?? (record.isVideo ? "mov" : "jpg")
                let name = "\(record.id.uuidString).\(ext)"
                let dir = record.isVideo ? videosDir : photosDir
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(name)
                if await writePhotoMedia(ref, dest) {
                    mediaFileName = name
                } else {
                    // The closure may have written a partial file before failing; drop it
                    // so a broken original never ships (and stays out of the manifest).
                    try? fm.removeItem(at: dest)
                }
            }

            photoBackups.append(PhotoBackup(
                id: record.id,
                sessionID: record.session?.id,
                spotID: record.spot?.id,
                markerID: record.marker?.id,
                assetCloudIdentifier: record.assetCloudIdentifier,
                isVideo: record.isVideo,
                createdAt: record.createdAt,
                thumbnailFileName: thumbnailFileName,
                mediaFileName: mediaFileName
            ))
        }

        let archive = BackupArchive(
            exportedAt: Date(),
            appVersion: appVersion,
            sessions: sessions,
            spots: spots,
            trips: trips,
            photos: photoBackups
        )
        try archive.encoded().write(to: stagingDir.appendingPathComponent("manifest.json"), options: .atomic)
        return archive
    }

    // MARK: - Restore

    /// Counts describing what a ``restore(fromStagingDirectory:isTombstoned:materializeAudio:reimportPhoto:)``
    /// call did.
    public struct RestoreSummary: Sendable, Equatable {
        public var sessionsImported: Int
        public var sessionsSkipped: Int
        public var spotsCreated: Int
        public var spotsLinked: Int
        public var tripsCreated: Int
        public var tripsLinked: Int
        public var audioRestored: Int
        /// New `PhotoRecord`s created from the manifest (existing ids dedupe, not counted).
        ///
        /// There is deliberately no re-import count here: whether a photo's original was
        /// *relinked* to an asset already in the library or *saved back* into Photos is
        /// entirely the app layer's business (it owns the closure that decides), and the
        /// app reports its own `photosReimported` from that pass.
        public var photosRestored: Int

        public init(
            sessionsImported: Int = 0,
            sessionsSkipped: Int = 0,
            spotsCreated: Int = 0,
            spotsLinked: Int = 0,
            tripsCreated: Int = 0,
            tripsLinked: Int = 0,
            audioRestored: Int = 0,
            photosRestored: Int = 0
        ) {
            self.sessionsImported = sessionsImported
            self.sessionsSkipped = sessionsSkipped
            self.spotsCreated = spotsCreated
            self.spotsLinked = spotsLinked
            self.tripsCreated = tripsCreated
            self.tripsLinked = tripsLinked
            self.audioRestored = audioRestored
            self.photosRestored = photosRestored
        }
    }

    /// Restores an already-unzipped backup staging directory into the store. **Additive**
    /// — never wipes existing data; sessions dedupe by id, spots/trips/photos upsert by
    /// id, relationships are only set when currently `nil`.
    ///
    /// - Parameters:
    ///   - dir: the unzipped staging directory (the caller unzips the `.zip` first).
    ///   - isTombstoned: whether a session id was deleted on this device and must not be
    ///     resurrected (defaults to never — an explicit restore usually wants everything).
    ///   - materializeAudio: writes a restored clip's bytes to disk (the app passes
    ///     VoiceNoteStore; defaults to a no-op). Called once per bundled `voice/<name>`
    ///     file; returns `true` if it actually wrote (so `audioRestored` counts real
    ///     writes, not clips already present).
    ///   - reimportPhoto: given a ``PhotoBackup`` and the bundled full-res file URL (or
    ///     `nil` when none was bundled), returns the `PHAsset.localIdentifier` to store —
    ///     the app relinks if the asset still resolves, else re-imports the bundled bytes
    ///     to Photos, else returns `nil`. Defaults to a no-op returning `nil`.
    /// - Returns: a ``RestoreSummary`` of what changed.
    /// - Throws: ``BackupArchiveError`` if `manifest.json` is missing/undecodable;
    ///   rethrows filesystem/SwiftData errors.
    @discardableResult
    public func restore(
        fromStagingDirectory dir: URL,
        isTombstoned: @MainActor @escaping (UUID) -> Bool = { _ in false },
        materializeAudio: (String, Data) -> Bool = { _, _ in false },
        reimportPhoto: (PhotoBackup, URL?) -> String? = { _, _ in nil }
    ) throws -> RestoreSummary {
        let fm = FileManager.default
        var summary = RestoreSummary()

        // Decode the manifest.
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw BackupArchiveError.malformed("manifest.json is missing from the backup")
        }
        let archive = try BackupArchive.decode(manifestData)

        // 1. Load bundled voice notes (small; safe to hold in memory) and materialize
        //    each to disk so on-device playback finds the file. `audioByName` also feeds
        //    the cross-device `audioData` mirror below.
        var audioByName: [String: Data] = [:]
        let voiceDir = dir.appendingPathComponent("voice", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: voiceDir, includingPropertiesForKeys: nil) {
            for file in files {
                if let data = try? Data(contentsOf: file) {
                    audioByName[file.lastPathComponent] = data
                }
            }
        }
        for (fileName, data) in audioByName {
            if materializeAudio(fileName, data) {
                summary.audioRestored += 1
            }
        }

        // 2. Import sessions (dedupe by id, honour tombstones). Mirror bundled audio into
        //    each marker's `audioData` so cross-device playback works even when the
        //    on-disk file is absent.
        let importer = SessionImporter(
            context: context,
            mirrorAudio: { marker in
                guard marker.audioData == nil,
                      let fileName = marker.audioFileName,
                      let bytes = audioByName[fileName]
                else { return false }
                marker.audioData = bytes
                return true
            },
            isTombstoned: isTombstoned
        )
        for session in archive.sessions {
            if try importer.importSession(session) {
                summary.sessionsImported += 1
            } else {
                summary.sessionsSkipped += 1
            }
        }

        // Index sessions once (present after step 2; tombstoned/absent ids simply won't
        // be found and won't be linked).
        let sessionsByID = Dictionary(
            try context.fetch(FetchDescriptor<SessionRecord>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 3. Create-if-missing + link spots (additive: existing fields untouched; a
        //    session already assigned is NOT re-linked — only nil→set).
        for sb in archive.spots {
            let spot = try existingSpot(id: sb.id) ?? {
                let created = Spot(
                    id: sb.id,
                    name: sb.name,
                    centerLatitude: sb.latitude,
                    centerLongitude: sb.longitude,
                    createdAt: sb.createdAt,
                    notes: sb.notes,
                    country: sb.country,
                    countryCode: sb.countryCode
                )
                context.insert(created)
                summary.spotsCreated += 1
                return created
            }()
            for sessionID in sb.sessionIDs {
                if let session = sessionsByID[sessionID], session.spot == nil {
                    session.spot = spot
                    summary.spotsLinked += 1
                }
            }
        }

        // 4. Create-if-missing + link trips (same additive pattern).
        for tb in archive.trips {
            let trip = try existingTrip(id: tb.id) ?? {
                let created = Trip(
                    id: tb.id,
                    name: tb.name,
                    startDate: tb.startDate,
                    endDate: tb.endDate,
                    notes: tb.notes,
                    createdAt: tb.createdAt
                )
                context.insert(created)
                summary.tripsCreated += 1
                return created
            }()
            for sessionID in tb.sessionIDs {
                if let session = sessionsByID[sessionID], session.trip == nil {
                    session.trip = trip
                    summary.tripsLinked += 1
                }
            }
        }

        // 5. Recreate/dedupe photos by id; reattach to session/spot/marker; restore the
        //    thumbnail; relink or re-import the original via the app closure.
        let markersByID = Dictionary(
            try context.fetch(FetchDescriptor<MarkerRecord>())
                .compactMap { $0.modelContext != nil ? ($0.id, $0) : nil },
            uniquingKeysWith: { first, _ in first }
        )
        let spotsByID = Dictionary(
            try context.fetch(FetchDescriptor<Spot>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var photosByID = Dictionary(
            try context.fetch(FetchDescriptor<PhotoRecord>())
                .compactMap { $0.modelContext != nil ? ($0.id, $0) : nil },
            uniquingKeysWith: { first, _ in first }
        )

        for pb in archive.photos {
            let record: PhotoRecord
            if let existing = photosByID[pb.id] {
                record = existing
            } else {
                let created = PhotoRecord(id: pb.id, createdAt: pb.createdAt, isVideo: pb.isVideo)
                context.insert(created)
                photosByID[pb.id] = created
                summary.photosRestored += 1
                record = created
            }

            // Cloud id is additive (only nil→set), matching the relationship guards:
            // a good cloud id the target device already resolved is never overwritten.
            if record.assetCloudIdentifier == nil {
                record.assetCloudIdentifier = pb.assetCloudIdentifier
            }

            // Reattach relationships (additive: only nil→set, so a link the user changed
            // on this device is preserved).
            if record.session == nil, let sid = pb.sessionID { record.session = sessionsByID[sid] }
            if record.spot == nil, let spid = pb.spotID { record.spot = spotsByID[spid] }
            if record.marker == nil, let mid = pb.markerID { record.marker = markersByID[mid] }

            // Thumbnail bytes → cross-device blob (drives the offline gallery). Additive
            // like every field around it: an existing thumbnail is a *fresher* render of
            // the same asset, and since this blob is CloudKit-mirrored, overwriting it
            // with the archived one would push the downgrade to all the user's devices.
            if record.thumbnailData == nil, let thumbName = pb.thumbnailFileName {
                let turl = dir.appendingPathComponent("thumbnails", isDirectory: true).appendingPathComponent(thumbName)
                if let tdata = try? Data(contentsOf: turl) {
                    record.thumbnailData = tdata
                }
            }

            // Full-res original is additive too (only nil→set). A record that already
            // has a local asset id — the user's existing, working link on this device —
            // is left entirely alone: we neither relink nor re-import, so we can't null
            // a valid id, wipe a good cloud id, or save a duplicate asset into Photos.
            // A newly-created (or previously-unlinked) record starts nil, so the guard
            // permits establishing its id from the app's relink/reimport as before.
            if record.assetIdentifier == nil {
                var mediaURL: URL?
                if let mediaName = pb.mediaFileName {
                    let sub = pb.isVideo ? "videos" : "photos"
                    let murl = dir.appendingPathComponent(sub, isDirectory: true).appendingPathComponent(mediaName)
                    if fm.fileExists(atPath: murl.path) { mediaURL = murl }
                }
                record.assetIdentifier = reimportPhoto(pb, mediaURL)
            }
        }

        try context.save()
        return summary
    }

    // MARK: - Off-main I/O

    /// Writes bytes to disk **off the main actor**.
    ///
    /// This type is `@MainActor` (SwiftData demands it), so a plain `data.write(to:)` here
    /// would block the main thread for the whole write. Staging a large library is hundreds
    /// of such writes plus gigabytes of originals — enough to freeze the UI for minutes and
    /// get the app killed by the iOS watchdog. Hopping to a detached task keeps the main
    /// thread free to animate progress and service a Cancel tap; `Data` and `URL` are both
    /// `Sendable`, so nothing unsafe crosses the boundary.
    private static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: .atomic)
        }.value
    }

    // MARK: - Naming helpers

    /// Normalizes a caller-supplied file extension into something safe to concatenate into
    /// a zip entry name: lowercased, alphanumerics only (so no `/`, `.` or traversal can
    /// sneak in), non-empty, and short. Returns `nil` when nothing usable is left.
    private static func sanitizedExtension(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !cleaned.isEmpty, cleaned.count <= 10 else { return nil }
        return cleaned
    }

    // MARK: - Fetch helpers

    private func existingSpot(id: UUID) throws -> Spot? {
        var descriptor = FetchDescriptor<Spot>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func existingTrip(id: UUID) throws -> Trip? {
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
