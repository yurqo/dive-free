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
    /// Latest water temperature (°C), or `nil` if none yet (no sensor / not submerged).
    public private(set) var currentTemperatureCelsius: Double?
    /// Water-temperature samples collected this session.
    public private(set) var temperatureSamples: [TemperatureSample] = []
    public private(set) var isRunning = false

    /// Called on `@MainActor` after every ingested sample. Install this from
    /// `SessionManager` to drive live dive detection without tight coupling.
    @ObservationIgnored
    public var onSamplesChanged: (@MainActor () -> Void)?

    private let provider: DepthProvider
    private var streamTask: Task<Void, Never>?
    private var temperatureTask: Task<Void, Never>?
    private var lastTemperatureSampleAt: Date?
    /// Minimum spacing between stored temperature samples, to bound the series size.
    private static let minTemperatureSampleInterval: TimeInterval = 2

    public init(provider: DepthProvider = makeDepthProvider()) {
        self.provider = provider
    }

    public func start() async throws {
        guard !isRunning else { return }
        try await provider.start()
        isRunning = true
        samples.removeAll()
        temperatureSamples.removeAll()
        currentTemperatureCelsius = nil
        lastTemperatureSampleAt = nil
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.provider.depthStream() {
                self.ingest(sample)
            }
        }
        temperatureTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.provider.temperatureStream() {
                self.ingestTemperature(sample)
            }
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        temperatureTask?.cancel()
        temperatureTask = nil
        provider.stop()
        isRunning = false
        onSamplesChanged = nil
    }

    private func ingest(_ sample: DepthSample) {
        samples.append(sample)
        currentDepthMeters = sample.depthMeters
        onSamplesChanged?()
    }

    private func ingestTemperature(_ sample: TemperatureSample) {
        // Live readout updates every reading; the stored series is throttled.
        currentTemperatureCelsius = sample.celsius
        if let last = lastTemperatureSampleAt,
           sample.timestamp.timeIntervalSince(last) < Self.minTemperatureSampleInterval { return }
        lastTemperatureSampleAt = sample.timestamp
        temperatureSamples.append(sample)
    }
}
