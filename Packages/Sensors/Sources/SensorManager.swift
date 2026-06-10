import Foundation
import Observation
import Domain

/// Observable façade over a `DepthProvider`. Collects live depth into a sample
/// buffer and publishes the current depth for the watch UI to render.
@MainActor
@Observable
public final class SensorManager {
    public private(set) var currentDepthMeters: Double = 0
    public private(set) var samples: [DepthSample] = []
    public private(set) var isRunning = false

    private let provider: DepthProvider
    private var streamTask: Task<Void, Never>?

    public init(provider: DepthProvider = makeDepthProvider()) {
        self.provider = provider
    }

    public func start() async throws {
        guard !isRunning else { return }
        try await provider.start()
        isRunning = true
        samples.removeAll()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.provider.depthStream() {
                self.ingest(sample)
            }
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        provider.stop()
        isRunning = false
    }

    private func ingest(_ sample: DepthSample) {
        samples.append(sample)
        currentDepthMeters = sample.depthMeters
    }
}
