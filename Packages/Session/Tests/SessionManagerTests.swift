import Foundation
import Testing
import SwiftData
import Domain
import Sensors
import Persistence
@testable import Session

@Suite("SessionManager")
@MainActor
struct SessionManagerTests {
    /// Returns a session manager wired to a fast mock sensor and an in-memory store.
    /// The caller must keep the returned `DiveStore` alive for the duration of the
    /// test — `ModelContext` does not retain its container, so releasing the store
    /// while the context is still in use causes a crash.
    private func makeManager(
        profile: [Double] = [0, 2, 5, 8, 5, 2, 0],
        location: GeoPoint? = nil,
        dwell: TimeInterval = 3,
        provider: DepthProvider? = nil,
        config: DiveDetectionConfig? = nil
    ) throws -> (manager: SessionManager, store: DiveStore) {
        let store = try DiveStore(inMemory: true)
        let sensors = SensorManager(
            provider: provider ?? MockDepthProvider(interval: 0.01, profile: profile)
        )
        // minimumDiveDuration: 0 — the mock burst is well under the default 3 s,
        // so at least one dive gets detected during the 100 ms sleep in persistsSession.
        let detector = DiveDetector(config: config ?? DiveDetectionConfig(surfaceExitDwellSeconds: dwell, minimumDiveDuration: 0))
        let manager = SessionManager(
            sensors: sensors,
            detector: detector,
            location: StubLocationProvider(point: location),
            modelContext: store.container.mainContext
        )
        return (manager, store)
    }

    @Test("isActive toggles correctly across start and stop")
    func activeStateToggles() async throws {
        let (manager, store) = try makeManager()
        defer { _ = store } // keep container alive through modelContext.save()
        #expect(!manager.isActive)
        try await manager.startSession()
        #expect(manager.isActive)
        try manager.stopSession()
        #expect(!manager.isActive)
    }

    @Test("persists a SessionRecord with dives and samples after stopSession")
    func persistsSession() async throws {
        let (manager, store) = try makeManager()
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(100)) // let samples accumulate
        let session = try manager.stopSession()

        // Domain value returned
        #expect(session != nil)
        #expect(session!.startTime <= session!.endTime!)

        // Persisted record present
        let records = try store.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(records.count == 1)
        let record = records[0]
        #expect(record.startTime == session!.startTime)
        #expect(!(record.dives ?? []).isEmpty)
        #expect(!(record.dives ?? [])[0].samples.isEmpty)
    }

    @Test("second startSession call is a no-op while active")
    func doubleStartIsNoop() async throws {
        let (manager, store) = try makeManager()
        defer { _ = store }
        try await manager.startSession()
        let first = manager.startTime
        try await manager.startSession() // should be ignored
        #expect(manager.startTime == first)
    }

    @Test("stopSession while idle returns nil")
    func stopWhileIdleReturnsNil() throws {
        let (manager, store) = try makeManager()
        defer { _ = store }
        let result = try manager.stopSession()
        #expect(result == nil)
    }

    @Test("markers added during session are persisted to SwiftData")
    func persistsMarkersAddedDuringSession() async throws {
        let (manager, store) = try makeManager()
        defer { _ = store }

        try await manager.startSession()
        manager.addMarker(kind: .wildlife)
        manager.addMarker(kind: .note)
        try await Task.sleep(for: .milliseconds(50))
        try manager.stopSession()

        let records = try store.container.mainContext.fetch(FetchDescriptor<SessionRecord>())
        #expect(records.count == 1)
        let kinds = Set((records[0].markers ?? []).map { $0.kind })
        #expect(kinds == Set(["wildlife", "note"]))
    }

    @Test("addMarker while idle is a no-op")
    func addMarkerWhileIdleIsNoop() throws {
        let (manager, store) = try makeManager()
        defer { _ = store }
        manager.addMarker(kind: .hazard)
        #expect(manager.markers.isEmpty)
    }

    @Test("currentDiveStart is set while submerged and cleared on stop")
    func currentDiveStartTracksSubmersion() async throws {
        // Profile stays below the surface, so the diver is continuously submerged.
        let (manager, store) = try makeManager(profile: [5, 5, 5])
        defer { _ = store }

        #expect(manager.currentDiveStart == nil) // idle
        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.currentDiveStart != nil)
        #expect((manager.currentDiveElapsed ?? -1) >= 0)

        try manager.stopSession()
        #expect(manager.currentDiveStart == nil)
        #expect(manager.currentDiveElapsed == nil)
    }

    @Test("currentDiveStart stays nil while at the surface")
    func currentDiveStartNilAtSurface() async throws {
        let (manager, store) = try makeManager(profile: [0, 0])
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.currentDiveStart == nil)
        #expect(manager.currentDiveElapsed == nil)
        try manager.stopSession()
    }

    @Test("surfaceInterval is nil at the surface before any dive")
    func surfaceIntervalNilBeforeFirstDive() async throws {
        let (manager, store) = try makeManager(profile: [0, 0])
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.surfaceInterval == nil)
        try manager.stopSession()
    }

    @Test("surfaceInterval is nil while continuously submerged")
    func surfaceIntervalNilWhileSubmerged() async throws {
        let (manager, store) = try makeManager(profile: [5, 5, 5])
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.currentDiveStart != nil)
        #expect(manager.surfaceInterval == nil)
        try manager.stopSession()
    }

    @Test("surfaceInterval starts counting after a dive ends at the surface")
    func surfaceIntervalStartsAfterDive() async throws {
        // Dive then surface, looped. Poll until we observe a surface moment that
        // follows a counted dive (the looping mock alternates submerged/surface).
        let (manager, store) = try makeManager(profile: [6, 6, 6, 6, 6, 0, 0, 0, 0, 0])
        defer { _ = store }

        try await manager.startSession()
        var observed: TimeInterval?
        for _ in 0..<200 {
            if manager.diveCount >= 1, let interval = manager.surfaceInterval {
                observed = interval
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(observed != nil)
        #expect((observed ?? -1) >= 0)
        try manager.stopSession()
    }

    @Test("surfaceInterval and lastSurfacedAt reset on stopSession")
    func surfaceIntervalResetsOnStop() async throws {
        let (manager, store) = try makeManager(profile: [6, 6, 6, 6, 6, 0, 0, 0, 0, 0])
        defer { _ = store }

        try await manager.startSession()
        for _ in 0..<200 where manager.lastSurfacedAt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try manager.stopSession()
        #expect(manager.lastSurfacedAt == nil)
        #expect(manager.surfaceInterval == nil)
    }

    @Test("live detection updates diveCount and maxDepthMeters before stopSession")
    func liveDetectionUpdatesWhileActive() async throws {
        let (manager, store) = try makeManager()
        defer { _ = store }

        try await manager.startSession()
        // Let the mock burst (profile [0,2,5,8,5,2,0] at 0.01 s/sample) run.
        try await Task.sleep(for: .milliseconds(200))

        // Dives and max depth are live — detectable before stopping.
        #expect(manager.diveCount >= 1)
        #expect(manager.maxDepthMeters >= 8)

        // After stopping, live state is reset.
        try manager.stopSession()
        #expect(manager.diveCount == 0)
        #expect(manager.maxDepthMeters == 0)
    }

    @Test("a shallow surface bounce keeps the session a single dive")
    func bounceStaysOneDive() async throws {
        // Deep → 0.8 m bounce (well under the dwell) → deep → surface, played once.
        let profile = [0] + Array(repeating: 4.0, count: 8)
            + [0.8, 0.8] + Array(repeating: 4.0, count: 8) + [0]
        let (manager, store) = try makeManager(
            dwell: 0.5,
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02)
        )
        defer { _ = store }

        try await manager.startSession()
        // Poll until the scripted profile has fully played and detection settled.
        for _ in 0..<200 where manager.currentDepthMeters != 0 || manager.diveCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.diveCount == 1)           // the bounce merged, not split
        #expect(manager.currentDiveStart == nil)  // ended at the 0 m surface sample
        try manager.stopSession()
    }

    @Test("a shallow hang past the dwell ends the dive at the crossing")
    func shallowHangEndsAtCrossing() async throws {
        // Deep, then a long 0.5 m hang that never reaches 0 m; the dwell must expire
        // and end the dive at the crossing (its last sample is a deep one).
        let profile = [0] + Array(repeating: 4.0, count: 8)
            + Array(repeating: 0.5, count: 40)
        let (manager, store) = try makeManager(
            dwell: 0.3,
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02)
        )
        defer { _ = store }

        try await manager.startSession()
        for _ in 0..<300 where manager.currentDiveStart != nil || manager.diveCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.diveCount == 1)
        #expect(manager.currentDiveStart == nil)  // dwell expired → surfaced
        // The single dive ends at the crossing: its last sample is still deep,
        // the shallow hang is excluded.
        #expect(manager.dives.first?.samples.last.map { $0.depthMeters > 1 } == true)
        try manager.stopSession()
    }

    @Test("a shallow hang does not phantom-confirm a dive the detector won't log")
    func shallowHangDoesNotPhantomConfirm() async throws {
        // A tier at 1.0 m / 1.0 s. The diver dips just past 1 m for a few fast samples
        // (deep span well under 1 s → the detector never logs it), then hangs shallow
        // at 0.5 m with a long dwell so the dive stays open. `currentDiveConfirmed`
        // must freeze the elapsed at the shallow crossing: it stays false even as
        // wall-clock time keeps passing during the hang. (Without the freeze it would
        // flip true once Date() - start crosses 1 s, locking in a dive never logged.)
        let profile = [0] + Array(repeating: 1.2, count: 4) + Array(repeating: 0.5, count: 30)
        let (manager, store) = try makeManager(
            provider: ScriptedDepthProvider(profile: profile, interval: 0.03),
            config: DiveDetectionConfig(
                surfaceExitDwellSeconds: 5,
                thresholds: [.init(minimumDepthMeters: 1.0, minimumDuration: 1.0)]
            )
        )
        defer { _ = store }

        try await manager.startSession()
        // Let the scripted profile finish; the dive is then held open in the shallow
        // band (dwell is 5 s and no more samples arrive to expire it).
        for _ in 0..<200 where manager.currentDiveStart == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.currentDiveStart != nil)
        // Wait past the tier's 1 s duration in wall-clock terms — long enough that the
        // un-frozen elapsed would have confirmed.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(manager.currentDiveConfirmed == false)
        #expect(manager.diveCount == 0)   // detector never logs the sub-second deep spike
        try manager.stopSession()
    }

    @Test("captured surface location is attached to the stopped session")
    func capturesLocation() async throws {
        let spot = GeoPoint(latitude: 20.5, longitude: -87.0)
        let (manager, store) = try makeManager(location: spot)
        defer { _ = store }

        try await manager.startSession()
        // Let the background location task resolve the stubbed fix.
        try await Task.sleep(for: .milliseconds(50))
        let session = try manager.stopSession()

        #expect(session?.location == spot)
    }

    @Test("session location is nil when no fix is available")
    func noLocationWhenUnavailable() async throws {
        let (manager, store) = try makeManager(location: nil)
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        let session = try manager.stopSession()

        #expect(session?.location == nil)
    }

    @Test("lastLocationFixAt is set after a fix and cleared on stop")
    func tracksLastLocationFix() async throws {
        let (manager, store) = try makeManager(location: GeoPoint(latitude: 1, longitude: 2))
        defer { _ = store }

        #expect(manager.lastLocationFixAt == nil)
        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.lastLocationFixAt != nil)

        try manager.stopSession()
        #expect(manager.lastLocationFixAt == nil)
    }

    @Test("lastLocationFixAt stays nil when no fix is available")
    func noFixLeavesTimestampNil() async throws {
        let (manager, store) = try makeManager(location: nil)
        defer { _ = store }

        try await manager.startSession()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.lastLocationFixAt == nil)
    }

    // MARK: - Configurable detection (plan 15)

    @Test("setDetectionConfig before startSession changes which descents count")
    func setDetectionConfigAppliesAtStart() async throws {
        // A shallow 1.2 m profile: a 1.5 m tier rejects it, a 1.0 m tier accepts it.
        // The config set before start must decide acceptance for this session.
        let profile = [0.0] + Array(repeating: 1.2, count: 20) + [0.0]
        let (manager, store) = try makeManager(
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02),
            config: DiveDetectionConfig(surfaceExitDwellSeconds: 0.3, thresholds: [
                .init(minimumDepthMeters: 1.5, minimumDuration: 0)   // would reject 1.2 m
            ])
        )
        defer { _ = store }

        manager.setDetectionConfig(DiveDetectionConfig(surfaceExitDwellSeconds: 0.3, thresholds: [
            .init(minimumDepthMeters: 1.0, minimumDuration: 0)       // accepts 1.2 m
        ]))
        try await manager.startSession()
        for _ in 0..<200 where manager.currentDepthMeters != 0 || manager.diveCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.diveCount == 1)   // logged under the custom tier
        try manager.stopSession()
    }

    @Test("a config change mid-session does not apply until the next session")
    func midSessionConfigDeferred() async throws {
        // Start with a permissive 1.0 m tier so the 1.2 m descent registers, then set a
        // stricter 3.0 m config mid-session — it must NOT retroactively drop the dive.
        let profile = [0.0] + Array(repeating: 1.2, count: 30) + [0.0]
        let (manager, store) = try makeManager(
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02),
            config: DiveDetectionConfig(surfaceExitDwellSeconds: 0.3, thresholds: [
                .init(minimumDepthMeters: 1.0, minimumDuration: 0)
            ])
        )
        defer { _ = store }

        try await manager.startSession()
        for _ in 0..<200 where manager.diveCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.diveCount == 1)
        manager.setDetectionConfig(DiveDetectionConfig(surfaceExitDwellSeconds: 0.3, thresholds: [
            .init(minimumDepthMeters: 3.0, minimumDuration: 0)      // stricter — would reject 1.2 m
        ]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.diveCount == 1)   // the running session keeps its original config
        try manager.stopSession()
    }

    @Test("auto-detection stays suppressed through a sub-dwell bounce after a manual stop")
    func manualStopSuppressesThroughBounce() async throws {
        // Deep throughout, with one brief sub-dwell shallow bounce, and the session
        // never surfaces (0 m). A manual dive is started then stopped while still deep,
        // so auto-detection is suppressed until a true surface — which never comes. The
        // bounce must NOT clear the suppression and open a phantom auto dive.
        let profile = Array(repeating: 4.0, count: 25) + [0.8] + Array(repeating: 4.0, count: 25)
        let (manager, store) = try makeManager(
            dwell: 5,
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02)
        )
        defer { _ = store }

        try await manager.startSession()
        manager.startManualDive()
        // Wait until we're actually deep, then stop the manual dive while still deep.
        for _ in 0..<100 where manager.currentDepthMeters <= 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        manager.stopManualDive()
        #expect(manager.diveCount == 1)             // the manual dive
        // Let the sub-dwell bounce and re-descent finish playing (~1 s of profile).
        try await Task.sleep(for: .milliseconds(1500))
        #expect(manager.currentDiveStart == nil)    // suppression held — no phantom live dive
        #expect(manager.diveCount == 1)             // still only the manual dive
        try manager.stopSession()
    }

    @Test("a manual stop in the shallow band suppresses a re-descent within the dwell")
    func manualStopShallowSuppressesRedescent() async throws {
        // The stop happens at 0.8 m — in the surface band but NOT surfaced (0 m). With a
        // long dwell, a re-descent to 4 m must not open a live auto dive: the detector's
        // pre-emption extends to the first true surface exit (which never comes), so the
        // live layer must stay suppressed to match (no live/final mismatch).
        let profile = Array(repeating: 0.8, count: 12) + Array(repeating: 4.0, count: 25)
        let (manager, store) = try makeManager(
            dwell: 5,
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02)
        )
        defer { _ = store }

        try await manager.startSession()
        manager.startManualDive()
        // Wait for the first shallow (0.8 m) sample so the stop reads the shallow band.
        for _ in 0..<100 where manager.currentDepthMeters == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        manager.stopManualDive()
        // Let the re-descent to 4 m play out (well within the 5 s dwell).
        try await Task.sleep(for: .milliseconds(800))
        #expect(manager.currentDiveStart == nil)   // suppression armed on the shallow stop
        #expect(manager.diveCount == 1)            // only the manual dive (live == final)
        try manager.stopSession()
    }

    @Test("a manual stop in the shallow band clears suppression once the dwell elapses")
    func manualStopShallowClearsAfterDwell() async throws {
        // Same shallow stop, but the diver then hangs shallow past the (short) dwell — a
        // genuine surface exit — which must clear the suppression so the later descent
        // opens a fresh auto dive.
        let profile = Array(repeating: 0.8, count: 40) + Array(repeating: 4.0, count: 30) + [0.0]
        let (manager, store) = try makeManager(
            dwell: 0.3,
            provider: ScriptedDepthProvider(profile: profile, interval: 0.02)
        )
        defer { _ = store }

        try await manager.startSession()
        manager.startManualDive()
        for _ in 0..<100 where manager.currentDepthMeters == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        manager.stopManualDive()
        // Poll for the descent opening a live dive once the dwell has cleared suppression.
        var opened = false
        for _ in 0..<200 {
            if manager.currentDiveStart != nil { opened = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opened)   // dwell elapsed → suppression cleared → the descent opened a dive
        try manager.stopSession()
    }
}

/// Returns a fixed location (or nil) without touching CoreLocation.
private struct StubLocationProvider: LocationProviding {
    let point: GeoPoint?
    func currentLocation() async -> GeoPoint? { point }
}

/// Emits a depth profile **once** (unlike `MockDepthProvider`, which loops), at a
/// real cadence so wall-clock and sample timestamps agree — lets the live
/// surface-exit dwell in `SessionManager` be exercised deterministically without
/// a second pass re-opening dives.
private struct ScriptedDepthProvider: DepthProvider {
    let profile: [Double]
    let interval: Double
    func start() async throws {}
    func stop() {}
    func depthStream() -> AsyncStream<DepthSample> {
        let profile = profile, interval = interval
        return AsyncStream { continuation in
            let task = Task {
                for depth in profile {
                    if Task.isCancelled { break }
                    continuation.yield(DepthSample(timestamp: Date(), depthMeters: depth))
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
