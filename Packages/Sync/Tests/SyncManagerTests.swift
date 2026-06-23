import Foundation
import Testing
import Domain
@testable import Sync

@Suite("SyncManager")
struct SyncManagerTests {
    private func makeSession(id: UUID = UUID()) -> DiveSession {
        DiveSession(
            id: id,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 600),
            dives: [
                Dive(
                    startTime: Date(timeIntervalSince1970: 10),
                    endTime: Date(timeIntervalSince1970: 40),
                    maxDepthMeters: 9.0
                )
            ],
            location: GeoPoint(latitude: 40.0, longitude: -70.0)
        )
    }

    /// Records every (id, data) handed to the transport.
    private final class TransferRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(id: String, data: Data)] = []
        func record(_ id: String, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            calls.append((id, data))
        }
    }

    @Test("a session survives a JSON encode/decode round trip")
    func sessionRoundTrips() throws {
        let original = makeSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiveSession.self, from: data)
        #expect(decoded == original)
    }

    @Test("a session with markers survives the payload round trip")
    func roundTripsWithMarkers() throws {
        let original = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 600),
            markers: [
                EventMarker(timestamp: Date(timeIntervalSince1970: 30), kind: .wildlife, text: "turtle"),
                EventMarker(timestamp: Date(timeIntervalSince1970: 90), kind: .hazard),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiveSession.self, from: data)
        #expect(decoded == original)
        #expect(decoded.markers.count == 2)
    }

    @Test("send hands the payload to the transport and marks it pending")
    func sendQueuesPayload() throws {
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })

        #expect(manager.pendingCount == 0)
        try manager.send(makeSession())

        #expect(recorder.calls.count == 1)
        #expect(manager.pendingCount == 1)
    }

    @Test("confirmed delivery clears the pending entry")
    func completionClearsPending() throws {
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })
        try manager.send(makeSession())

        let sent = recorder.calls[0]
        manager.completeTransfer(id: sent.id, data: sent.data, error: nil)
        #expect(manager.pendingCount == 0)
    }

    @Test("a failed transfer is retried and stays pending")
    func failureRetries() throws {
        struct TransferError: Error {}
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })
        try manager.send(makeSession())

        let sent = recorder.calls[0]
        manager.completeTransfer(id: sent.id, data: sent.data, error: TransferError())

        #expect(recorder.calls.count == 2)            // original + retry
        #expect(recorder.calls[1].id == sent.id)       // same payload
        #expect(manager.pendingCount == 1)             // still outstanding
    }

    @Test("repeated failures stop auto-retrying after the cap")
    func retryCapStopsStorm() throws {
        struct TransferError: Error {}
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })
        try manager.send(makeSession())
        let sent = recorder.calls[0]

        // Drive far more failures than the cap; auto-retries must not run away.
        for _ in 0..<20 {
            manager.completeTransfer(id: sent.id, data: sent.data, error: TransferError())
        }
        // 1 original + at most a bounded number of retries (cap is 5).
        #expect(recorder.calls.count <= 6)
        #expect(manager.pendingCount == 1)            // still outstanding, not dropped

        // A reachability-driven retry resets the budget and tries again.
        manager.retryPending()
        #expect(recorder.calls.count >= 7)
    }

    @Test("retryPending re-sends every outstanding payload")
    func retryResendsAll() throws {
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })
        try manager.send(makeSession(id: UUID()))
        try manager.send(makeSession(id: UUID()))

        manager.retryPending()
        #expect(recorder.calls.count == 4)             // 2 sends + 2 retries
        #expect(manager.pendingCount == 2)
    }

    @Test("pending count changes are reported to the observer")
    func reportsPendingCount() throws {
        let recorder = TransferRecorder()
        let manager = SyncManager(performTransfer: { recorder.record($0, $1) })
        let counts = Mutex<[Int]>([])
        manager.onPendingCountChange = { newCount in counts.withLock { $0.append(newCount) } }

        try manager.send(makeSession())
        let sent = recorder.calls[0]
        manager.completeTransfer(id: sent.id, data: sent.data, error: nil)

        #expect(counts.withLock { $0 } == [1, 0])
    }

    @Test("received payloads are decoded and forwarded")
    func decodesIncoming() throws {
        let manager = SyncManager(performTransfer: { _, _ in })
        let original = makeSession()
        let data = try JSONEncoder().encode(original)

        let received = Mutex<DiveSession?>(nil)
        manager.onReceiveSession = { session in received.withLock { $0 = session } }
        manager.handleReceived([SyncManager.payloadKey: data, SyncManager.idKey: original.id.uuidString])

        #expect(received.withLock { $0 } == original)
    }

    @Test("malformed payloads are ignored")
    func ignoresGarbage() {
        let manager = SyncManager(performTransfer: { _, _ in })
        let received = Mutex<DiveSession?>(nil)
        manager.onReceiveSession = { session in received.withLock { $0 = session } }

        manager.handleReceived([:])
        manager.handleReceived([SyncManager.payloadKey: Data([0x00, 0x01])])
        #expect(received.withLock { $0 } == nil)
    }

    @Test("custom markers round-trip through the application context")
    func customMarkersSync() {
        let captured = Mutex<[String: Any]?>(nil)
        let manager = SyncManager(applyContext: { ctx in captured.withLock { $0 = ctx } })
        let kinds = [MarkerKind(.wildlife), MarkerKind(id: "abc-123", emoji: "🦈", label: "Shark")]

        manager.sendCustomMarkers(kinds)
        let context = captured.withLock { $0 }
        #expect(context?[SyncManager.markersKey] != nil)

        let received = Mutex<[MarkerKind]>([])
        manager.onReceiveCustomMarkers = { kinds in received.withLock { $0 = kinds } }
        manager.handleApplicationContext(context ?? [:])
        #expect(received.withLock { $0 } == kinds)
    }

    @Test("units preference round-trips through the application context")
    func unitPreferenceSync() {
        let captured = Mutex<[String: Any]?>(nil)
        let manager = SyncManager(applyContext: { ctx in captured.withLock { $0 = ctx } })
        let pref = UnitPreference(mode: .custom, customDepth: .meters, customDistance: .imperial, customTemperature: .fahrenheit)

        manager.sendUnitPreference(pref)
        let context = captured.withLock { $0 }
        #expect(context?[SyncManager.unitsKey] != nil)

        let received = Mutex<UnitPreference?>(nil)
        manager.onReceiveUnitPreference = { pref in received.withLock { $0 = pref } }
        manager.handleApplicationContext(context ?? [:])
        #expect(received.withLock { $0 } == pref)
    }

    @Test("markers and units share the context without clobbering each other")
    func markersAndUnitsCoexist() {
        let captured = Mutex<[String: Any]?>(nil)
        let manager = SyncManager(applyContext: { ctx in captured.withLock { $0 = ctx } })

        manager.sendCustomMarkers([MarkerKind(.wildlife)])
        manager.sendUnitPreference(.imperial)

        // The second send must not drop the first key — both live in one context.
        let context = captured.withLock { $0 }
        #expect(context?[SyncManager.markersKey] != nil)
        #expect(context?[SyncManager.unitsKey] != nil)
    }
}

/// Minimal lock-guarded box so test observers can capture values from the
/// arbitrary thread `SyncManager` callbacks fire on.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
