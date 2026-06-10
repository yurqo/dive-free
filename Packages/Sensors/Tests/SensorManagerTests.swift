import Foundation
import Testing
@testable import Sensors

@Suite("SensorManager")
@MainActor
struct SensorManagerTests {
    @Test("collects samples from the mock provider once started")
    func collectsSamples() async throws {
        let manager = SensorManager(
            provider: MockDepthProvider(interval: 0.01, profile: [0, 2, 5, 2, 0])
        )
        try await manager.start()
        #expect(manager.isRunning)

        // Let a few samples flow in, then stop.
        try await Task.sleep(for: .milliseconds(80))
        manager.stop()

        #expect(!manager.isRunning)
        #expect(!manager.samples.isEmpty)
    }
}
