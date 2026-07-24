import Foundation
import SwiftData
import Domain

/// Assembles a ``BackupArchive`` from the SwiftData store (export) and rebuilds the
/// store's models from an archive (restore). This is the *testable core* of DiveFree's
/// backup & restore — it owns the model ↔ DTO mapping, dedupe, and relationship linking,
/// and delegates the two impure edges (reading/writing voice-note audio bytes) to
/// injected closures so the app wires in VoiceNoteStore while tests stay filesystem-free.
///
/// Restore is faithfully **additive**: it reproduces the archive as-is (each spot's exact
/// center, each session's exact assignment) and never overwrites edits the user made on
/// the target device. It deliberately does *not* run the proximity ``SpotAssigner`` —
/// that would recenter archived spots and could spawn near-duplicates, breaking a
/// deterministic restore. (Auto-assignment of new live sessions happens elsewhere.)
///
/// `@MainActor` because it reads/writes through a SwiftData `ModelContext`, which is
/// main-actor isolated.
@MainActor
public struct BackupRestore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Export

    /// Builds a full ``BackupArchive`` from every session, spot, and trip in the store.
    ///
    /// - Parameters:
    ///   - appVersion: the producing app version (informational, stored in the archive).
    ///   - audioBytes: resolves a marker's voice-note file name to its raw bytes (the
    ///     app passes VoiceNoteStore / the marker's `audioData`). Returning `nil` omits
    ///     that clip from the archive.
    public func makeArchive(appVersion: String? = nil, audioBytes: (String) -> Data?) throws -> BackupArchive {
        let sessionRecords = try context.fetch(FetchDescriptor<SessionRecord>())
        let sessions = sessionRecords.map { $0.toDomain() }

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

        // Collect every referenced voice-note file name (deduped) across all sessions'
        // markers, then resolve bytes. Prefer the on-disk file via the injected
        // closure; fall back to the marker's own CloudKit-synced `audioData` so a
        // clip that only ever synced as a blob (never materialized to disk) is still
        // captured. Only include clips we can resolve one way or the other.
        var audio: [String: Data] = [:]
        for record in sessionRecords {
            for marker in (record.markers ?? []) {
                guard let fileName = marker.audioFileName, audio[fileName] == nil else { continue }
                if let bytes = audioBytes(fileName) ?? marker.audioData {
                    audio[fileName] = bytes
                }
            }
        }

        return BackupArchive(
            exportedAt: Date(),
            appVersion: appVersion,
            sessions: sessions,
            spots: spots,
            trips: trips,
            audio: audio
        )
    }

    // MARK: - Restore

    /// Counts describing what a ``restore(from:isTombstoned:materializeAudio:)`` call did.
    public struct RestoreSummary: Sendable, Equatable {
        public var sessionsImported: Int
        public var sessionsSkipped: Int
        public var spotsCreated: Int
        public var spotsLinked: Int
        public var tripsCreated: Int
        public var tripsLinked: Int
        public var audioRestored: Int

        public init(
            sessionsImported: Int = 0,
            sessionsSkipped: Int = 0,
            spotsCreated: Int = 0,
            spotsLinked: Int = 0,
            tripsCreated: Int = 0,
            tripsLinked: Int = 0,
            audioRestored: Int = 0
        ) {
            self.sessionsImported = sessionsImported
            self.sessionsSkipped = sessionsSkipped
            self.spotsCreated = spotsCreated
            self.spotsLinked = spotsLinked
            self.tripsCreated = tripsCreated
            self.tripsLinked = tripsLinked
            self.audioRestored = audioRestored
        }
    }

    /// Restores an archive into the store. **Additive** — never wipes existing data;
    /// sessions dedupe by id, spots/trips upsert by id.
    ///
    /// - Parameters:
    ///   - archive: the decoded archive to restore.
    ///   - isTombstoned: whether a session id was deleted on this device and must not be
    ///     resurrected (defaults to never).
    ///   - materializeAudio: writes a restored clip's bytes to disk (the app passes
    ///     VoiceNoteStore; defaults to a no-op). Called once per archive audio entry;
    ///     returns `true` if it actually wrote the file (so `audioRestored` counts only
    ///     real writes, not clips that already existed on disk).
    /// - Returns: a ``RestoreSummary`` of what changed.
    @discardableResult
    public func restore(
        from archive: BackupArchive,
        isTombstoned: @MainActor @escaping (UUID) -> Bool = { _ in false },
        materializeAudio: (String, Data) -> Bool = { _, _ in false }
    ) throws -> RestoreSummary {
        var summary = RestoreSummary()

        // 1. Materialize audio to disk so on-device playback finds the file. Count only
        //    clips the closure actually wrote (it returns false for ones already present).
        for (fileName, data) in archive.audio {
            if materializeAudio(fileName, data) {
                summary.audioRestored += 1
            }
        }

        // 2. Import sessions (dedupe by id, honour tombstones). Mirror the archive's
        //    audio bytes into each marker's `audioData` so cross-device playback works
        //    even when the on-disk file is absent.
        let importer = SessionImporter(
            context: context,
            mirrorAudio: { marker in
                guard marker.audioData == nil,
                      let fileName = marker.audioFileName,
                      let bytes = archive.audio[fileName]
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

        // Fetch every session once and index by id, so spot/trip linking is a dict
        // lookup rather than a per-id store round-trip. (Sessions from step 2 are now
        // present; ids not here — tombstoned/absent — simply won't be linked.)
        let sessionsByID = Dictionary(
            try context.fetch(FetchDescriptor<SessionRecord>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 3. Create-if-missing + link spots. Additive: an existing spot's fields are
        //    left untouched, and a session already assigned to a spot on this device is
        //    NOT re-linked (only nil→set), so user re-assignments survive a restore.
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

        try context.save()
        return summary
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
