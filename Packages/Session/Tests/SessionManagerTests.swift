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
    private func makeManager() throws -> (manager: SessionManager, store: DiveStore) {
        let store = try DiveStore(inMemory: true)
        let sensors = SensorManager(
            provider: MockDepthProvider(interval: 0.01, profile: [0, 2, 5, 8, 5, 2, 0])
        )
        // minimumDiveDuration: 0 — the mock burst is well under the default 3 s,
        // so at least one dive gets detected during the 100 ms sleep in persistsSession.
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDuration: 0))
        let manager = SessionManager(
            sensors: sensors,
            detector: detector,
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
        #expect(!record.dives.isEmpty)
        #expect(!record.dives[0].samples.isEmpty)
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
        let kinds = Set(records[0].markers.map { $0.kind })
        #expect(kinds == Set(["wildlife", "note"]))
    }

    @Test("addMarker while idle is a no-op")
    func addMarkerWhileIdleIsNoop() throws {
        let (manager, store) = try makeManager()
        defer { _ = store }
        manager.addMarker(kind: .hazard)
        #expect(manager.markers.isEmpty)
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
}
