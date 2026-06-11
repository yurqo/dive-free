import Foundation
import Domain
import Testing
@testable import Sensors

/// A provider whose stream is fed manually, so tests can drive the capture loop
/// deterministically rather than racing a timed mock.
private final class ControlledProvider: DepthProvider, @unchecked Sendable {
    private let stream: AsyncStream<DepthSample>
    let continuation: AsyncStream<DepthSample>.Continuation

    init() {
        var captured: AsyncStream<DepthSample>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() async throws {}
    func stop() { continuation.finish() }
    func depthStream() -> AsyncStream<DepthSample> { stream }
}

@Suite("SensorManager")
@MainActor
struct SensorManagerTests {
    /// Spins the run loop until `condition` holds or a short budget elapses,
    /// since ingestion happens asynchronously on the stream task.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("collects samples from the mock provider once started")
    func collectsSamples() async throws {
        let manager = SensorManager(
            provider: MockDepthProvider(interval: 0.01, profile: [0, 2, 5, 2, 0])
        )
        try await manager.start()
        #expect(manager.isRunning)

        try await waitUntil { !manager.samples.isEmpty }
        manager.stop()

        #expect(!manager.isRunning)
        #expect(!manager.samples.isEmpty)
    }

    @Test("currentDepthMeters reflects the most recent sample")
    func tracksCurrentDepth() async throws {
        let provider = ControlledProvider()
        let manager = SensorManager(provider: provider)
        try await manager.start()

        provider.continuation.yield(DepthSample(timestamp: Date(), depthMeters: 4.2))
        try await waitUntil { manager.currentDepthMeters == 4.2 }
        #expect(manager.currentDepthMeters == 4.2)

        provider.continuation.yield(DepthSample(timestamp: Date(), depthMeters: 7.9))
        try await waitUntil { manager.currentDepthMeters == 7.9 }
        #expect(manager.currentDepthMeters == 7.9)
        manager.stop()
    }

    @Test("onSamplesChanged fires once per ingested sample")
    func notifiesPerSample() async throws {
        let provider = ControlledProvider()
        let manager = SensorManager(provider: provider)
        var count = 0
        manager.onSamplesChanged = { count += 1 }
        try await manager.start()

        provider.continuation.yield(DepthSample(timestamp: Date(), depthMeters: 1))
        provider.continuation.yield(DepthSample(timestamp: Date(), depthMeters: 2))
        try await waitUntil { count == 2 }
        #expect(count == 2)
        manager.stop()
    }

    @Test("a second start while running is a no-op and keeps samples")
    func doubleStartIsNoop() async throws {
        let provider = ControlledProvider()
        let manager = SensorManager(provider: provider)
        try await manager.start()
        provider.continuation.yield(DepthSample(timestamp: Date(), depthMeters: 3))
        try await waitUntil { manager.samples.count == 1 }

        try await manager.start() // ignored — must not reset the buffer
        #expect(manager.samples.count == 1)
        manager.stop()
    }

    @Test("stop clears the onSamplesChanged callback")
    func stopClearsCallback() async throws {
        let provider = ControlledProvider()
        let manager = SensorManager(provider: provider)
        manager.onSamplesChanged = {}
        try await manager.start()
        manager.stop()
        #expect(manager.onSamplesChanged == nil)
    }
}
