import Foundation

/// Top-level units choice. `custom` reveals per-dimension overrides (the freediver
/// case: meters depth even in the US, with imperial distance/temperature).
public enum UnitMode: String, Codable, CaseIterable, Sendable {
    case metric, imperial, custom
}

/// Depth display unit.
public enum DepthUnit: String, Codable, CaseIterable, Sendable {
    case meters, feet
}

/// Surface-distance display unit family (metric → m/km, imperial → ft/mi).
public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case metric, imperial
}

/// Temperature display unit.
public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit
}

/// Wind-speed display unit. Independent of `UnitMode`: "metric" wind is commonly
/// shown as either km/h *or* m/s, and marine users want knots, so the user picks
/// this directly rather than it being derived from the mode.
public enum WindSpeedUnit: String, Codable, CaseIterable, Sendable {
    case kmh, ms, mph, knots
}

/// The user's units choice: a `mode` plus per-dimension overrides that only take
/// effect in `custom` mode. Resolved into effective units via `depth`/`distance`/
/// `temperature`, which the centralized formatters consult.
///
/// Read fresh from `UserDefaults` at each format call (`current`), mirroring
/// `GPSPrecision`, so a change applies on the next render without threading the
/// preference through every view. The iPhone is the source of truth and syncs the
/// choice to the watch (see `SyncManager.sendUnitPreference`).
public struct UnitPreference: Codable, Sendable, Equatable {
    public var mode: UnitMode
    /// Per-dimension overrides, used only when `mode == .custom`.
    public var customDepth: DepthUnit
    public var customDistance: DistanceUnit
    public var customTemperature: TemperatureUnit
    /// Wind-speed unit. Used as-is regardless of `mode` (see `WindSpeedUnit`).
    public var windSpeed: WindSpeedUnit

    public init(
        mode: UnitMode = .metric,
        customDepth: DepthUnit = .meters,
        customDistance: DistanceUnit = .metric,
        customTemperature: TemperatureUnit = .celsius,
        windSpeed: WindSpeedUnit = .kmh
    ) {
        self.mode = mode
        self.customDepth = customDepth
        self.customDistance = customDistance
        self.customTemperature = customTemperature
        self.windSpeed = windSpeed
    }

    /// Lenient decode so a synced payload from an older build (missing a
    /// dimension) still applies rather than being dropped on cross-device
    /// version skew — each absent field falls back to the region default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = UnitPreference.regionDefault
        mode = try container.decodeIfPresent(UnitMode.self, forKey: .mode) ?? fallback.mode
        customDepth = try container.decodeIfPresent(DepthUnit.self, forKey: .customDepth) ?? fallback.customDepth
        customDistance = try container.decodeIfPresent(DistanceUnit.self, forKey: .customDistance) ?? fallback.customDistance
        customTemperature = try container.decodeIfPresent(TemperatureUnit.self, forKey: .customTemperature) ?? fallback.customTemperature
        windSpeed = try container.decodeIfPresent(WindSpeedUnit.self, forKey: .windSpeed) ?? fallback.windSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case mode, customDepth, customDistance, customTemperature, windSpeed
    }

    public static let metric = UnitPreference(mode: .metric)
    public static let imperial = UnitPreference(
        mode: .imperial,
        customDepth: .feet,
        customDistance: .imperial,
        customTemperature: .fahrenheit,
        windSpeed: .mph
    )

    /// Effective depth unit for the current mode.
    public var depth: DepthUnit {
        switch mode {
        case .metric: return .meters
        case .imperial: return .feet
        case .custom: return customDepth
        }
    }

    /// Effective distance unit for the current mode.
    public var distance: DistanceUnit {
        switch mode {
        case .metric: return .metric
        case .imperial: return .imperial
        case .custom: return customDistance
        }
    }

    /// Effective temperature unit for the current mode.
    public var temperature: TemperatureUnit {
        switch mode {
        case .metric: return .celsius
        case .imperial: return .fahrenheit
        case .custom: return customTemperature
        }
    }
}

public extension UnitPreference {
    /// `UserDefaults`/`@AppStorage` keys, one per dimension plus the mode.
    enum Key {
        public static let mode = "unitMode"
        public static let depth = "unitDepth"
        public static let distance = "unitDistance"
        public static let temperature = "unitTemperature"
        public static let windSpeed = "unitWindSpeed"
    }

    /// The default before the user has chosen, inferred from device region:
    /// US → imperial, everywhere else → metric.
    static var regionDefault: UnitPreference {
        Locale.current.measurementSystem == .us ? .imperial : .metric
    }

    /// Current preference from `UserDefaults.standard`, falling back to the
    /// region default for any unset dimension.
    static var current: UnitPreference { read(from: .standard) }

    /// Reads a preference from `defaults`, filling unset dimensions from the
    /// region default. Each dimension is stored independently so the `custom`
    /// pickers can be `@AppStorage`-bound directly.
    static func read(from defaults: UserDefaults) -> UnitPreference {
        let fallback = regionDefault
        return UnitPreference(
            mode: defaults.string(forKey: Key.mode).flatMap(UnitMode.init) ?? fallback.mode,
            customDepth: defaults.string(forKey: Key.depth).flatMap(DepthUnit.init) ?? fallback.customDepth,
            customDistance: defaults.string(forKey: Key.distance).flatMap(DistanceUnit.init) ?? fallback.customDistance,
            customTemperature: defaults.string(forKey: Key.temperature).flatMap(TemperatureUnit.init) ?? fallback.customTemperature,
            windSpeed: defaults.string(forKey: Key.windSpeed).flatMap(WindSpeedUnit.init) ?? fallback.windSpeed
        )
    }

    /// Writes every dimension to `defaults` (round-trips exactly with `read`).
    /// Used to apply a preference synced from the iPhone on the watch.
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(customDepth.rawValue, forKey: Key.depth)
        defaults.set(customDistance.rawValue, forKey: Key.distance)
        defaults.set(customTemperature.rawValue, forKey: Key.temperature)
        defaults.set(windSpeed.rawValue, forKey: Key.windSpeed)
    }
}
