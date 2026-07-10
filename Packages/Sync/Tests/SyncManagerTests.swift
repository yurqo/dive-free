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

    /// Records every voice-note file (url + name metadata) handed to the transport.
    private final class FileTransferRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL] = []
        private(set) var names: [String] = []
        func record(_ url: URL, _ metadata: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
            names.append((metadata[SyncManager.fileNameKey] as? String) ?? "")
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

    @Test("a deletion message is forwarded to onDeleteSession, not onReceiveSession")
    func decodesDeletion() {
        let manager = SyncManager(performTransfer: { _, _ in })
        let deleted = Mutex<UUID?>(nil)
        let received = Mutex<DiveSession?>(nil)
        manager.onDeleteSession = { id in deleted.withLock { $0 = id } }
        manager.onReceiveSession = { session in received.withLock { $0 = session } }

        let id = UUID()
        manager.handleReceived([SyncManager.deletedKey: id.uuidString])

        #expect(deleted.withLock { $0 } == id)
        #expect(received.withLock { $0 } == nil)
    }

    @Test("deleting a session drops its pending send so a retry can't resurrect it")
    func deletionCancelsPendingSend() throws {
        let manager = SyncManager(performTransfer: { _, _ in }, performDeletion: { _ in })
        let session = makeSession()
        try manager.send(session)
        #expect(manager.pendingCount == 1)

        manager.sendDeletion(session.id)
        #expect(manager.pendingCount == 0)
    }

    @Test("re-adopting outstanding transfers populates pending and reports the count")
    func adoptsOutstandingTransfers() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let manager = SyncManager(
            performTransfer: { _, _ in },
            outstandingTransfers: { [(id: "transfer-1", data: data)] }
        )
        let counts = Mutex<[Int]>([])
        manager.onPendingCountChange = { newCount in counts.withLock { $0.append(newCount) } }

        #expect(manager.pendingCount == 0)
        manager.adoptOutstandingTransfers()

        #expect(manager.pendingCount == 1)
        #expect(counts.withLock { $0 } == [1])
    }

    @Test("re-adopted entries are not re-sent by retryPending while system-owned")
    func retryPendingSkipsSystemOwned() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let recorder = TransferRecorder()
        let manager = SyncManager(
            performTransfer: { recorder.record($0, $1) },
            outstandingTransfers: { [(id: "transfer-1", data: data)] }
        )
        manager.adoptOutstandingTransfers()

        manager.retryPending()
        // The OS still owns the queued transfer — no duplicate re-send.
        #expect(recorder.calls.isEmpty)
        #expect(manager.pendingCount == 1)
    }

    @Test("retryPending reclaims a system-owned entry the OS no longer lists")
    func retryPendingReclaimsDroppedTransfer() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let recorder = TransferRecorder()
        // The OS lists the transfer at adoption, then drops it without a
        // didFinish (unpair / daemon restart) — the outstanding list goes empty.
        let outstanding = Mutex<[(id: String, data: Data)]>([(id: "transfer-1", data: data)])
        let manager = SyncManager(
            performTransfer: { recorder.record($0, $1) },
            outstandingTransfers: { outstanding.withLock { $0 } }
        )
        manager.adoptOutstandingTransfers()
        #expect(manager.pendingCount == 1)

        outstanding.withLock { $0 = [] }
        manager.retryPending()
        // Reclaimed and re-sent rather than starved forever.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].id == "transfer-1")
        #expect(manager.pendingCount == 1)

        // The re-send completes normally.
        manager.completeTransfer(id: "transfer-1", data: data, error: nil)
        #expect(manager.pendingCount == 0)
    }

    @Test("a failed didFinish for a re-adopted entry triggers a re-send")
    func reAdoptedFailureRetries() throws {
        struct TransferError: Error {}
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let recorder = TransferRecorder()
        let manager = SyncManager(
            performTransfer: { recorder.record($0, $1) },
            outstandingTransfers: { [(id: "transfer-1", data: data)] }
        )
        manager.adoptOutstandingTransfers()

        // A prior-launch transfer that finished with an error clears the system's
        // copy, so the entry becomes ours and is re-sent.
        manager.completeTransfer(id: "transfer-1", data: data, error: TransferError())
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].id == "transfer-1")
        #expect(manager.pendingCount == 1)

        // Now that it's no longer system-owned, retryPending re-sends it too.
        manager.retryPending()
        #expect(recorder.calls.count == 2)
    }

    @Test("adopting the same transfer twice does not double-count it")
    func adoptIsIdempotent() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let manager = SyncManager(
            performTransfer: { _, _ in },
            outstandingTransfers: { [(id: "transfer-1", data: data)] }
        )
        manager.adoptOutstandingTransfers()
        manager.adoptOutstandingTransfers()
        #expect(manager.pendingCount == 1)
    }

    @Test("sendDeletion drops the matching re-adopted entry by stored id, leaving others")
    func deletionDropsAdoptedEntry() throws {
        let target = makeSession()
        let other = makeSession()
        let targetData = try JSONEncoder().encode(target)
        let otherData = try JSONEncoder().encode(other)
        let deleted = Mutex<UUID?>(nil)
        let manager = SyncManager(
            performTransfer: { _, _ in },
            performDeletion: { id in deleted.withLock { $0 = id } },
            outstandingTransfers: {
                [(id: "transfer-target", data: targetData), (id: "transfer-other", data: otherData)]
            }
        )
        manager.adoptOutstandingTransfers()
        #expect(manager.pendingCount == 2)

        // sendDeletion filters by the stored session id (no payload decode) and
        // drops only the matching entry; the unrelated one stays pending.
        manager.sendDeletion(target.id)
        #expect(manager.pendingCount == 1)
        #expect(deleted.withLock { $0 } == target.id)
    }

    @Test("confirmed delivery of a re-adopted entry reports the stored session id")
    func adoptedDeliveryReportsSessionID() throws {
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        let manager = SyncManager(
            performTransfer: { _, _ in },
            outstandingTransfers: { [(id: "transfer-1", data: data)] }
        )
        manager.adoptOutstandingTransfers()

        let delivered = Mutex<UUID?>(nil)
        manager.onSessionDelivered = { id in delivered.withLock { $0 = id } }
        manager.completeTransfer(id: "transfer-1", data: data, error: nil)

        #expect(delivered.withLock { $0 } == session.id)
        #expect(manager.pendingCount == 0)
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

    @Test("sendAudioFile hands the file and name metadata to the transport")
    func sendAudioFileRoutesThroughSeam() throws {
        let recorder = FileTransferRecorder()
        let manager = SyncManager(performTransfer: { _, _ in }, performFileTransfer: { recorder.record($0, $1) })
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        manager.sendAudioFile(fileURL, fileName: "voice-1.m4a")
        #expect(recorder.urls == [fileURL])
        #expect(recorder.names == ["voice-1.m4a"])
    }

    @Test("a confirmed voice-note delivery fires onAudioFileDelivered with the metadata name")
    func audioDeliveryConfirmed() {
        let manager = SyncManager(performTransfer: { _, _ in })
        let delivered = Mutex<String?>(nil)
        manager.onAudioFileDelivered = { name in delivered.withLock { $0 = name } }

        manager.completeFileTransfer(
            fileName: nil,
            fileURL: URL(fileURLWithPath: "/tmp/whatever.m4a"),
            metadata: [SyncManager.fileNameKey: "voice-1.m4a"],
            error: nil
        )
        #expect(delivered.withLock { $0 } == "voice-1.m4a")
    }

    @Test("a failed voice-note transfer re-sends via the transport when the file exists")
    func audioFailureResendsWhenFileExists() throws {
        struct TransferError: Error {}
        let recorder = FileTransferRecorder()
        let manager = SyncManager(performTransfer: { _, _ in }, performFileTransfer: { recorder.record($0, $1) })
        let delivered = Mutex<String?>(nil)
        manager.onAudioFileDelivered = { name in delivered.withLock { $0 = name } }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        manager.completeFileTransfer(
            fileName: "voice-1.m4a",
            fileURL: fileURL,
            metadata: [SyncManager.fileNameKey: "voice-1.m4a"],
            error: TransferError()
        )
        #expect(recorder.urls == [fileURL])          // re-sent once
        #expect(recorder.names == ["voice-1.m4a"])
        #expect(delivered.withLock { $0 } == nil)     // a failure never confirms delivery
    }

    @Test("a failed voice-note transfer with a missing file neither re-sends nor confirms")
    func audioFailureMissingFileNoResend() {
        struct TransferError: Error {}
        let recorder = FileTransferRecorder()
        let manager = SyncManager(performTransfer: { _, _ in }, performFileTransfer: { recorder.record($0, $1) })
        let delivered = Mutex<String?>(nil)
        manager.onAudioFileDelivered = { name in delivered.withLock { $0 = name } }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        manager.completeFileTransfer(
            fileName: "missing.m4a",
            fileURL: missing,
            metadata: [SyncManager.fileNameKey: "missing.m4a"],
            error: TransferError()
        )
        #expect(recorder.urls.isEmpty)                // nothing to re-send
        #expect(delivered.withLock { $0 } == nil)
    }

    @Test("a live session snapshot round-trips through the application context")
    func liveSessionSync() {
        let captured = Mutex<[String: Any]?>(nil)
        let manager = SyncManager(applyContext: { ctx in captured.withLock { $0 = ctx } })
        let snapshot = LiveSessionSnapshot(
            isActive: true,
            startTime: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1042),
            depthMeters: 12.4,
            maxDepthMeters: 14.1,
            diveCount: 3,
            isSubmerged: true,
            currentDiveElapsed: 20
        )

        manager.sendLiveSession(snapshot)
        let context = captured.withLock { $0 }
        #expect(context?[SyncManager.liveSessionKey] != nil)

        let received = Mutex<LiveSessionSnapshot?>(nil)
        manager.onReceiveLiveSession = { snap in received.withLock { $0 = snap } }
        manager.handleApplicationContext(context ?? [:])
        #expect(received.withLock { $0 } == snapshot)
    }

    @Test("the terminal live snapshot (isActive false) is delivered to the phone")
    func liveSessionEnded() {
        let manager = SyncManager(applyContext: { _ in })
        let ended = LiveSessionSnapshot(
            isActive: false, startTime: Date(timeIntervalSince1970: 0),
            depthMeters: 0, maxDepthMeters: 8, diveCount: 2, isSubmerged: false
        )
        manager.sendLiveSession(ended)

        let received = Mutex<LiveSessionSnapshot?>(nil)
        manager.onReceiveLiveSession = { snap in received.withLock { $0 = snap } }
        // Simulate the phone receiving what the watch put on the context.
        guard let data = try? JSONEncoder().encode(ended) else { Issue.record("encode failed"); return }
        manager.handleApplicationContext([SyncManager.liveSessionKey: data])
        #expect(received.withLock { $0 }?.isActive == false)
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
