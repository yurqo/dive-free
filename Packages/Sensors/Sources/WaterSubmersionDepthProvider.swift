import Foundation
import Domain

#if os(watchOS)
import CoreMotion

/// Real depth provider backed by the Apple Watch Ultra water-submersion sensor.
///
/// Implementation outline (filled in during Phase 2 of the build):
/// - Create a `CMWaterSubmersionManager`, check `waterSubmersionAvailable`.
/// - Set the delegate and forward `CMWaterSubmersionMeasurement.depth` into the stream.
/// - Bridge delegate callbacks into the `AsyncStream` continuation below.
///
/// See: https://developer.apple.com/documentation/coremotion/cmwatersubmersionmanager
public final class WaterSubmersionDepthProvider: DepthProvider, @unchecked Sendable {
    private let manager = CMWaterSubmersionManager()

    public init() {}

    public func start() async throws {
        // TODO(Phase 2): wire CMWaterSubmersionManagerDelegate and begin updates.
    }

    public func stop() {
        // TODO(Phase 2): tear down the manager delegate.
    }

    public func depthStream() -> AsyncStream<DepthSample> {
        AsyncStream { $0.finish() }
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
