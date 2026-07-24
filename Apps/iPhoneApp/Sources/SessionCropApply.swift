import Foundation
import SwiftData
import Domain
import Persistence

/// Applies a session crop to a stored `SessionRecord`, trimming the surface tails
/// and cleaning up the artifacts that fall outside the kept range.
///
/// The actual clamp/filter is delegated to the tested Domain `DiveSession.cropped(to:)`
/// (via `record.toDomain()`), which guarantees the crop can never cut through a dive
/// or exceed the session bounds. This function just writes the trimmed scalar/blob
/// fields back onto the record and deletes the now-out-of-range markers (removing
/// their voice-note files first, since those live outside the model graph).
///
/// The HKWorkout and `activeEnergyKilocalories` are intentionally **not** edited:
/// re-attributing burned energy to a shorter window isn't worth the complexity, and
/// the resulting small kcal discrepancy is acceptable for a session logger. Dives,
/// session-level photos, spot/trip, weather, conditions, and `workoutUUID` are also
/// left untouched — only the surface series, bounds, and dropped markers change.
///
/// Returns the `SessionCropResult` so the caller can present a post-crop summary
/// (counts / whether audio was dropped) if it wants.
@MainActor
@discardableResult
func applyCrop(to record: SessionRecord, range: ClosedRange<Date>, in context: ModelContext) -> SessionCropResult {
    // Reading/mutating a deleted @Model traps (#148) — bail with a neutral result
    // if the record is already gone from its context (project-wide pattern).
    guard record.modelContext != nil else {
        return SessionCropResult(
            session: record.toDomain(),
            droppedTrackPoints: 0,
            droppedHeartRateSamples: 0,
            droppedTemperatureSamples: 0,
            droppedMarkers: []
        )
    }

    let result = record.toDomain().cropped(to: range)
    let cropped = result.session

    // Write back the trimmed bounds + surface series (dives/markers stay as their
    // own records; markers are pruned below).
    record.startTime = cropped.startTime
    record.endTime = cropped.endTime
    record.track = cropped.track
    record.heartRateSamples = cropped.heartRateSamples
    record.temperatureSamples = cropped.temperatureSamples

    // Delete the markers whose timestamp fell outside the kept range, collecting
    // their voice-note file names as we go. The on-disk clips are only removed
    // AFTER a successful save — if the save throws we leave both the marker
    // records and their audio files intact (the safe partial state). SwiftData's
    // cascade drops the record + its externalStorage `audioData`; the marker→photos
    // relationship is `.nullify`, so any linked photos detach and survive.
    let droppedIDs = Set(result.droppedMarkers.map(\.id))
    var droppedAudioNames: [String] = []
    for marker in (record.markers ?? []) where droppedIDs.contains(marker.id) {
        if let name = marker.audioFileName { droppedAudioNames.append(name) }
        context.delete(marker)
    }

    do {
        try context.save()
    } catch {
        // Save failed: don't touch the audio files — markers + clips stay intact.
        return result
    }

    for name in droppedAudioNames { VoiceNoteStore.delete(name) }
    return result
}
