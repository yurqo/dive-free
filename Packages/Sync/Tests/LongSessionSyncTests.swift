import Foundation
import Testing
import Domain
@testable import Sync

@Suite("Long-session sync")
struct LongSessionSyncTests {
    private struct FileSend {
        let url: URL
        let metadata: [String: Any]
    }

    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        var inline: [(id: String, data: Data)] = []
        var files: [FileSend] = []
        var queued: [FileSend] = []
        var cancelled: Set<String> = []

        func withLock<T>(_ body: (Transport) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(self)
        }
        func finish(_ send: FileSend) { withLock { $0.queued.removeAll { $0.url == send.url } } }
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LongSessionSync-\(UUID())")
        let transport = Transport()
        deinit { try? FileManager.default.removeItem(at: directory) }

        func manager() -> SyncManager {
            let transport = transport
            return SyncManager(
                applyContext: { _ in }, performDeletion: { _ in }, performAck: { _ in }, performAudioAck: { _ in },
                cancelTransfers: { ids in transport.withLock {
                    $0.cancelled.formUnion(ids)
                    $0.inline.removeAll { ids.contains($0.id) }
                    $0.queued.removeAll { ($0.metadata[SyncManager.idKey] as? String).map(ids.contains) == true }
                } },
                outstandingTransfers: { transport.withLock { $0.inline } },
                performFileTransfer: { url, metadata in transport.withLock {
                    let send = FileSend(url: url, metadata: metadata)
                    $0.files.append(send); $0.queued.append(send)
                } },
                outstandingSessionFiles: { transport.withLock { $0.queued.map { ($0.url, $0.metadata) } } },
                outstandingResyncIDs: { [] }, sessionTransferDirectory: directory
            )
        }
    }

    private func session(duration: Int = 2529) -> DiveSession {
        let start = Date(timeIntervalSince1970: 1_791_707_000)
        let dives = (0..<13).map { index in
            let offset = 60 + index * (duration / 14)
            return Dive(startTime: start.addingTimeInterval(Double(offset)), endTime: start.addingTimeInterval(Double(offset + 90)),
                        maxDepthMeters: 5.8, samples: (0...90).map {
                DepthSample(timestamp: start.addingTimeInterval(Double(offset + $0)), depthMeters: 5.8 * sin(Double($0) / 90 * .pi))
            })
        }
        return DiveSession(
            startTime: start, endTime: start.addingTimeInterval(Double(duration)), dives: dives,
            markers: (0..<10).map {
                EventMarker(timestamp: start.addingTimeInterval(Double(80 + $0 * 170)), kind: .note,
                            text: "🐠 Reef note", audioFileName: "voice-\($0).m4a", title: "Reef", transcript: "Original transcript")
            },
            location: GeoPoint(latitude: -8.33536, longitude: 115.66110),
            track: (0...duration).map {
                TrackPoint(timestamp: start.addingTimeInterval(Double($0)),
                           location: GeoPoint(latitude: -8.33536 + Double($0) * 0.000001, longitude: 115.66110, horizontalAccuracy: 4))
            },
            heartRateSamples: stride(from: 0, through: duration, by: 5).map {
                HeartRateSample(timestamp: start.addingTimeInterval(Double($0)), bpm: Double(75 + $0 % 25))
            },
            temperatureSamples: stride(from: 0, through: duration, by: 5).map {
                TemperatureSample(timestamp: start.addingTimeInterval(Double($0)), celsius: 28.3)
            }, locationName: "Bali"
        )
    }

    @Test("42-minute and four-hour recordings arrive with every sample and note", arguments: [2529, 4 * 3600])
    func fullFidelityFileTransfer(duration: Int) throws {
        let fixture = Fixture()
        let watch = fixture.manager()
        let original = session(duration: duration)
        try watch.send(original)
        #expect(fixture.transport.inline.isEmpty)
        let send = try #require(fixture.transport.files.first)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: send.url)) == original)
        #expect(try PropertyListSerialization.data(fromPropertyList: send.metadata, format: .binary, options: 0).count < 1024)
        let phone = Fixture().manager()
        let received = TransportBox<DiveSession?>(nil)
        phone.onReceiveSession = { value, _ in received.withLock { $0 = value } }
        phone.handleReceivedFile(send.url, metadata: send.metadata)
        #expect(received.withLock { $0 } == original)
        fixture.transport.finish(send)
        watch.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: nil)
        #expect(watch.pendingCount == 1) // WC delivery is not proof of a phone save.
        watch.handleReceived([SyncManager.ackKey: original.id.uuidString])
        #expect(watch.pendingCount == 0)
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        #expect(restarted.pendingCount == 0)
    }

    @Test("a relaunch after delivery but before a phone save restores the full recording and resync flag")
    func relaunchBeforeImportAck() throws {
        let fixture = Fixture()
        let first = fixture.manager()
        let original = session()
        try first.send(original, isResync: true)
        let send = try #require(fixture.transport.files.first)
        fixture.transport.finish(send)
        first.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: nil)
        #expect(!FileManager.default.fileExists(atPath: send.url.path))
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        restarted.retryPending()
        let retry = try #require(fixture.transport.files.last)
        #expect(fixture.transport.files.count == 2)
        #expect(retry.metadata[SyncManager.resyncKey] as? Bool == true)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: retry.url)) == original)
        #expect(restarted.pendingCount == 1)
    }

    @Test("short recordings use the same file transport as long sessions")
    func shortSessionUsesFile() throws {
        let fixture = Fixture()
        let original = DiveSession(startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 30))
        try fixture.manager().send(original)
        #expect(fixture.transport.inline.isEmpty)
        let send = try #require(fixture.transport.files.first)
        #expect(send.metadata[SyncManager.sessionFileKey] as? Bool == true)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: send.url)) == original)
    }

    @Test("relaunch and manual resend do not duplicate an OS-queued session file")
    func adoptsQueuedFileWithoutDuplicates() throws {
        let fixture = Fixture()
        let original = session()
        try fixture.manager().send(original)
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        restarted.retryPending()
        try restarted.send(original, isResync: true)
        #expect(fixture.transport.files.count == 1)
        #expect(restarted.pendingCount == 1)
    }

    @Test("refreshing a queued recording preserves its in-flight file and retries the latest data")
    func immutableSnapshotsAndFreshRetries() throws {
        struct Failed: Error {}
        let fixture = Fixture()
        let manager = fixture.manager()
        var original = session()
        try manager.send(original)
        let send = try #require(fixture.transport.files.first)
        let oldBytes = try Data(contentsOf: send.url)
        original.title = "Jemeluk Beach"
        try manager.send(original, isResync: true)
        #expect(try Data(contentsOf: send.url) == oldBytes)
        fixture.transport.finish(send)
        manager.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: Failed())
        let retry = try #require(fixture.transport.files.last)
        #expect(fixture.transport.files.count == 2)
        #expect(retry.metadata[SyncManager.resyncKey] as? Bool == true)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: retry.url)) == original)
    }

    @Test("legacy dictionary transfers of any size migrate to the file queue", arguments: [false, true])
    func migratesOldQueuedSession(long: Bool) throws {
        let fixture = Fixture()
        let original = long ? session() : DiveSession(startTime: Date(timeIntervalSince1970: 0))
        fixture.transport.inline = [("legacy-transfer", try JSONEncoder().encode(original))]
        let manager = fixture.manager()
        manager.adoptOutstandingTransfers()
        manager.retryPending()
        #expect(fixture.transport.cancelled == ["legacy-transfer"])
        #expect(fixture.transport.inline.isEmpty)
        let send = try #require(fixture.transport.files.first)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: send.url)) == original)
    }

    @Test("automatic recovery retries every pending session after the OS loses its queue")
    func recoversAllPendingSessions() throws {
        let fixture = Fixture()
        let originals = [DiveSession(startTime: Date(timeIntervalSince1970: 0)), session(), session(duration: 4 * 3600)]
        let manager = fixture.manager()
        for original in originals { try manager.send(original) }
        fixture.transport.queued = [] // A daemon restart can lose the system queue.

        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        restarted.retryPending()
        #expect(fixture.transport.files.count == 6)
        #expect(restarted.pendingCount == 3)
        let recovered = try fixture.transport.queued.map { try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: $0.url)) }
        #expect(Set(recovered.map(\.id)) == Set(originals.map(\.id)))
        for original in originals { #expect(recovered.first { $0.id == original.id } == original) }

        restarted.handleReceived([SyncManager.ackKey: originals[0].id.uuidString])
        restarted.retryPending()
        #expect(restarted.pendingCount == 2)
        #expect(fixture.transport.files.count == 6) // Still-queued files aren't duplicated.
    }

    @Test("saved-session acknowledgements update only the matching session's status")
    func sessionSpecificPendingStatus() throws {
        let fixture = Fixture()
        let manager = fixture.manager()
        let first = DiveSession(startTime: Date(timeIntervalSince1970: 0))
        let second = session()
        try manager.send(first)
        try manager.send(second)
        #expect(manager.pendingSessionIDs == [first.id, second.id])
        let send = try #require(fixture.transport.files.first)
        fixture.transport.finish(send)
        manager.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: nil)
        #expect(manager.pendingSessionIDs == [first.id, second.id])
        manager.handleReceived([SyncManager.ackKey: first.id.uuidString])
        #expect(manager.pendingSessionIDs == [second.id])
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        #expect(restarted.pendingSessionIDs == [second.id])
    }

    @Test("legacy migration keeps the system copy when durable storage is unavailable")
    func legacyMigrationSurvivesStorageFailure() throws {
        let fixture = Fixture()
        let original = session()
        try Data("blocking file".utf8).write(to: fixture.directory)
        fixture.transport.inline = [("legacy-transfer", try JSONEncoder().encode(original))]
        let manager = fixture.manager()
        manager.adoptOutstandingTransfers()
        manager.retryPending()
        #expect(fixture.transport.cancelled.isEmpty)
        #expect(fixture.transport.inline.count == 1)
        #expect(fixture.transport.files.isEmpty)

        try FileManager.default.removeItem(at: fixture.directory)
        manager.adoptOutstandingTransfers()
        manager.retryPending()
        #expect(fixture.transport.cancelled == ["legacy-transfer"])
        let send = try #require(fixture.transport.files.first)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: send.url)) == original)
    }

    @Test("file retry failures are bounded and the recording survives an exhausted budget")
    func boundedFileRetries() throws {
        struct Failed: Error {}
        let fixture = Fixture()
        let manager = fixture.manager()
        try manager.send(session())
        for _ in 0..<10 {
            let send = try #require(fixture.transport.files.last)
            fixture.transport.finish(send)
            manager.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: Failed())
        }
        #expect(fixture.transport.files.count == 6)
        #expect(manager.pendingCount == 1)
        manager.retryPending()
        #expect(fixture.transport.files.count == 7)
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        #expect(restarted.pendingCount == 1)
    }

    @Test("deleting a large session cancels its file and removes it from the durable outbox")
    func deletionSurvivesRelaunch() throws {
        struct Failed: Error {}
        let fixture = Fixture()
        let manager = fixture.manager()
        let original = session()
        try manager.send(original)
        let send = try #require(fixture.transport.files.first)
        manager.sendDeletion(original.id)
        manager.completeFileTransfer(fileName: nil, fileURL: send.url, metadata: send.metadata, error: Failed())
        #expect(fixture.transport.queued.isEmpty)
        #expect(fixture.transport.files.count == 1)
        let restarted = fixture.manager()
        restarted.adoptOutstandingTransfers()
        restarted.retryPending()
        #expect(restarted.pendingCount == 0)
    }

    @Test("bad session files never become audio files or imported sessions")
    func malformedSessionFile() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let url = fixture.directory.appendingPathComponent("broken.json")
        try Data("invalid".utf8).write(to: url)
        let manager = fixture.manager()
        manager.audioDirectory = fixture.directory.appendingPathComponent("Audio")
        let errors = TransportBox<String?>(nil)
        manager.onSyncError = { value in errors.withLock { $0 = value } }
        manager.onReceiveSession = { _, _ in Issue.record("Must not import malformed data") }
        manager.onReceiveAudioFile = { _ in Issue.record("Session payload was routed as audio") }
        manager.handleReceivedFile(url, metadata: [SyncManager.sessionFileKey: true])
        #expect(errors.withLock { $0 } != nil)
        #expect(!FileManager.default.fileExists(atPath: manager.audioDirectory!.path))
    }

    @Test("a storage failure remains pending and can recover without losing samples")
    func storageFailureRecovers() throws {
        let fixture = Fixture()
        try Data("blocking file".utf8).write(to: fixture.directory)
        let manager = fixture.manager()
        let errors = TransportBox<String?>(nil)
        manager.onSyncError = { value in errors.withLock { $0 = value } }
        let original = session()
        try manager.send(original)
        #expect(manager.pendingCount == 1)
        #expect(errors.withLock { $0 } != nil)
        #expect(fixture.transport.files.isEmpty)
        try FileManager.default.removeItem(at: fixture.directory)
        manager.retryPending()
        let send = try #require(fixture.transport.files.first)
        #expect(try JSONDecoder().decode(DiveSession.self, from: Data(contentsOf: send.url)) == original)
    }
}

private final class TransportBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
