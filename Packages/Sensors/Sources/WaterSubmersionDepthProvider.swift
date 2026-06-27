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

// Likewise extracted so the iOS test target can verify the temperature mapping.
func makeTemperatureSample(temperature: Measurement<UnitTemperature>, date: Date) -> TemperatureSample {
    TemperatureSample(timestamp: date, celsius: temperature.converted(to: .celsius).value)
}

#if os(watchOS)
import CoreMotion

/// Real depth provider backed by the Apple Watch Ultra water-submersion sensor.
///
/// Subscribes to `CMWaterSubmersionManager` delegate callbacks and emits
/// `DepthSample` values via an `AsyncStream`. The stream and its continuation
/// are created in `init()` so no values are dropped between `start()` (which
/// enables the delegate) and the caller's first `for await` on `depthStream()`.
public final class WaterSubmersionDepthProvider: NSObject, DepthProvider, CMWaterSubmersionManagerDelegate, @unchecked Sendable {
    private let manager = CMWaterSubmersionManager()
    private var continuation: AsyncStream<DepthSample>.Continuation?
    private var _stream: AsyncStream<DepthSample>
    private var tempContinuation: AsyncStream<TemperatureSample>.Continuation?
    private var _temperatureStream: AsyncStream<TemperatureSample>

    override public init() {
        (_stream, continuation) = Self.makeStream()
        (_temperatureStream, tempContinuation) = Self.makeStream()
        super.init()
    }

    private static func makeStream<Element>() -> (AsyncStream<Element>, AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element> { continuation = $0 }
        return (stream, continuation)
    }

    public func start() async throws {
        guard CMWaterSubmersionManager.waterSubmersionAvailable else {
            throw DepthProviderError.sensorUnavailable
        }
        // Re-arm the streams: stop() finished the previous ones, and a finished
        // AsyncStream can't be restarted — so without this a second session (the
        // provider is reused for the app's lifetime) would record nothing.
        (_stream, continuation) = Self.makeStream()
        (_temperatureStream, tempContinuation) = Self.makeStream()
        manager.delegate = self
    }

    public func stop() {
        manager.delegate = nil
        continuation?.finish()
        continuation = nil
        tempContinuation?.finish()
        tempContinuation = nil
    }

    public func depthStream() -> AsyncStream<DepthSample> { _stream }
    public func temperatureStream() -> AsyncStream<TemperatureSample> { _temperatureStream }

    // MARK: - CMWaterSubmersionManagerDelegate

    public func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {
        if let depth = measurement.depth {
            continuation?.yield(makeDepthSample(depth: depth, date: measurement.date))
        } else if measurement.submersionState == .pastMaxDepth {
            // Deeper than the entitlement can measure: no depth value is provided,
            // so clamp to the ceiling. The UI renders this as "6+".
            continuation?.yield(DepthSample(timestamp: measurement.date, depthMeters: DepthFormat.maxMeasurableMeters))
        } else if measurement.submersionState == .notSubmerged {
            // Surfaced with no depth value — emit 0 m so the detector ends the dive
            // (see the surfacing event below for why this matters).
            continuation?.yield(DepthSample(timestamp: measurement.date, depthMeters: 0))
        }
    }

    public func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        // The depth-*measurement* stream stops once the diver is out of the water
        // (and a surface measurement carries no depth), so the in-progress dive
        // would never close — leaving the session stuck "submerged". That makes
        // the Action button place markers instead of recording a voice note, and
        // blocks voice notes entirely. Acting on the notSubmerged transition emits
        // a 0 m sample so the detector returns to the surface and ends the dive.
        if event.state == .notSubmerged {
            continuation?.yield(DepthSample(timestamp: event.date, depthMeters: 0))
        }
    }

    public func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterTemperature) {
        tempContinuation?.yield(makeTemperatureSample(temperature: measurement.temperature, date: measurement.date))
    }

    public func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: any Error) {
        continuation?.finish()
        continuation = nil
        tempContinuation?.finish()
        tempContinuation = nil
    }
}
#endif

/// Simulator-only capability overrides, written by the watch Settings (debug)
/// toggles and read here, so the SE / Series-10-11 / Ultra tiers can be exercised
/// in the simulator — which otherwise has no real sensors and reports depth as
/// always available. These paths only matter in the Simulator.
public enum SimCapabilityOverride {
    public static let depthSensorKey = "sim.hasDepthSensor"
    public static let actionButtonKey = "sim.hasActionButton"

    /// Reads a Bool override, defaulting to `true` when unset.
    public static func value(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Whether this device can measure water depth. `true` on a real Apple Watch
/// Ultra (40 m) or Series 10/11 (6 m). `false` on a real watch without the
/// sensor (Series 9 and earlier, SE) — the UI hides depth there. In the
/// simulator it follows the Settings override (default `true`).
public enum DepthSensor {
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return SimCapabilityOverride.value(SimCapabilityOverride.depthSensorKey)
        #elseif os(watchOS)
        return CMWaterSubmersionManager.waterSubmersionAvailable
        #else
        return true
        #endif
    }
}

/// Returns the best depth provider for this device:
/// - real watch with the sensor → `WaterSubmersionDepthProvider` (live depth);
/// - real watch without it → `UnavailableDepthProvider` (no depth, no fake dives);
/// - simulator / other platforms → `MockDepthProvider` (synthetic profile for dev).
public func makeDepthProvider() -> DepthProvider {
    #if targetEnvironment(simulator)
    // Honour the Settings depth-sensor override so the no-depth reduced flow is
    // testable: off → no depth/dives (like a real SE). (Picked up at session
    // start; restart the app after toggling.)
    return SimCapabilityOverride.value(SimCapabilityOverride.depthSensorKey)
        ? MockDepthProvider()
        : UnavailableDepthProvider()
    #elseif os(watchOS)
    return CMWaterSubmersionManager.waterSubmersionAvailable
        ? WaterSubmersionDepthProvider()
        : UnavailableDepthProvider()
    #else
    return MockDepthProvider()
    #endif
}
