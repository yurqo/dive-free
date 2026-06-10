import Foundation
import Domain

public enum DepthProviderError: Error {
    case sensorUnavailable
}

// Extracted outside the watchOS guard so the iOS test target can verify the
// CMWaterSubmersionMeasurement → DepthSample mapping without CoreMotion types.
func makeDepthSample(depth: Measurement<UnitLength>, date: Date) -> DepthSample {
    DepthSample(timestamp: date, depthMeters: depth.converted(to: .meters).value)
}

#if os(watchOS)
import CoreMotion

/// Real depth provider backed by the Apple Watch Ultra water-submersion sensor.
///
/// Subscribes to `CMWaterSubmersionManager` delegate callbacks and emits
/// `DepthSample` values via an `AsyncStream`. The stream and its continuation
/// are created in `init()` so no values are dropped between `start()` (which
/// enables the delegate) and the caller's first `for await` on `depthStream()`.
public final class WaterSubmersionDepthProvider: DepthProvider, @unchecked Sendable {
    private let manager = CMWaterSubmersionManager()
    private var continuation: AsyncStream<DepthSample>.Continuation?
    private let _stream: AsyncStream<DepthSample>

    public init() {
        var cap: AsyncStream<DepthSample>.Continuation?
        _stream = AsyncStream { cap = $0 }
        continuation = cap
    }

    public func start() async throws {
        guard CMWaterSubmersionManager.waterSubmersionAvailable else {
            throw DepthProviderError.sensorUnavailable
        }
        manager.delegate = self
    }

    public func stop() {
        manager.delegate = nil
        continuation?.finish()
        continuation = nil
    }

    public func depthStream() -> AsyncStream<DepthSample> { _stream }
}

extension WaterSubmersionDepthProvider: CMWaterSubmersionManagerDelegate {
    public func manager(
        _ manager: CMWaterSubmersionManager,
        didUpdate measurement: CMWaterSubmersionMeasurement
    ) {
        guard let depth = measurement.depth else { return }
        continuation?.yield(makeDepthSample(depth: depth, date: measurement.date))
    }

    public func manager(
        _ manager: CMWaterSubmersionManager,
        errorOccurred error: Error
    ) {
        continuation?.finish()
        continuation = nil
    }
}
#endif

/// Returns the best available depth provider for the current platform.
/// Falls back to the mock on platforms/simulators without the sensor.
public func makeDepthProvider() -> DepthProvider {
    #if os(watchOS)
    if CMWaterSubmersionManager.waterSubmersionAvailable {
        return WaterSubmersionDepthProvider()
    }
    #endif
    return MockDepthProvider()
}
