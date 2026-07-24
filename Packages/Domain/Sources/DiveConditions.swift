import Foundation

/// Underwater visibility, as a coarse category (distance-based grading is a
/// future refinement). Named `WaterVisibility` to avoid clashing with SwiftUI's
/// `Visibility`.
public enum WaterVisibility: String, Codable, CaseIterable, Sendable {
    case poor, fair, good, excellent

    /// Localized display label. Resolved against `Bundle.module` (Domain's own
    /// catalog); a bare `String(localized:)` in a framework would resolve against
    /// the main app bundle. Key scheme: `conditions.visibility.<case>`, with an
    /// English `defaultValue` matching the previous `rawValue.capitalized`.
    public var label: String {
        switch self {
        case .poor: String(localized: "conditions.visibility.poor", defaultValue: "Poor", bundle: .module)
        case .fair: String(localized: "conditions.visibility.fair", defaultValue: "Fair", bundle: .module)
        case .good: String(localized: "conditions.visibility.good", defaultValue: "Good", bundle: .module)
        case .excellent: String(localized: "conditions.visibility.excellent", defaultValue: "Excellent", bundle: .module)
        }
    }
}

/// Strength of the water current.
public enum WaterCurrent: String, Codable, CaseIterable, Sendable {
    case none, light, moderate, strong

    /// Localized display label. Key scheme: `conditions.current.<case>`.
    public var label: String {
        switch self {
        case .none: String(localized: "conditions.current.none", defaultValue: "None", bundle: .module)
        case .light: String(localized: "conditions.current.light", defaultValue: "Light", bundle: .module)
        case .moderate: String(localized: "conditions.current.moderate", defaultValue: "Moderate", bundle: .module)
        case .strong: String(localized: "conditions.current.strong", defaultValue: "Strong", bundle: .module)
        }
    }
}

/// Surface state.
public enum SurfaceCondition: String, Codable, CaseIterable, Sendable {
    case calm, choppy, rough

    /// Localized display label. Key scheme: `conditions.surface.<case>`.
    public var label: String {
        switch self {
        case .calm: String(localized: "conditions.surface.calm", defaultValue: "Calm", bundle: .module)
        case .choppy: String(localized: "conditions.surface.choppy", defaultValue: "Choppy", bundle: .module)
        case .rough: String(localized: "conditions.surface.rough", defaultValue: "Rough", bundle: .module)
        }
    }
}

/// Tide stage at the time of the dive.
public enum TideStage: String, Codable, CaseIterable, Sendable {
    case low, incoming, high, outgoing

    /// Localized display label. Key scheme: `conditions.tide.<case>`.
    public var label: String {
        switch self {
        case .low: String(localized: "conditions.tide.low", defaultValue: "Low", bundle: .module)
        case .incoming: String(localized: "conditions.tide.incoming", defaultValue: "Incoming", bundle: .module)
        case .high: String(localized: "conditions.tide.high", defaultValue: "High", bundle: .module)
        case .outgoing: String(localized: "conditions.tide.outgoing", defaultValue: "Outgoing", bundle: .module)
        }
    }
}

/// Manually-entered dive conditions for a session. All fields optional; an
/// all-nil value is treated as "no conditions logged" (`isEmpty`). Temperatures
/// are stored in °C and formatted per the user's `UnitPreference`. Auto-weather
/// (#108) may pre-fill some fields; manual entry overrides.
public struct DiveConditions: Codable, Sendable, Equatable {
    public var visibility: WaterVisibility?
    public var current: WaterCurrent?
    public var surface: SurfaceCondition?
    public var tide: TideStage?
    /// Manual water temperature (°C) — useful on watches without the Ultra sensor.
    public var waterTemperatureCelsius: Double?
    /// Manual air temperature (°C).
    public var airTemperatureCelsius: Double?

    public init(
        visibility: WaterVisibility? = nil,
        current: WaterCurrent? = nil,
        surface: SurfaceCondition? = nil,
        tide: TideStage? = nil,
        waterTemperatureCelsius: Double? = nil,
        airTemperatureCelsius: Double? = nil
    ) {
        self.visibility = visibility
        self.current = current
        self.surface = surface
        self.tide = tide
        self.waterTemperatureCelsius = waterTemperatureCelsius
        self.airTemperatureCelsius = airTemperatureCelsius
    }

    /// True when nothing has been logged.
    public var isEmpty: Bool {
        visibility == nil && current == nil && surface == nil && tide == nil
            && waterTemperatureCelsius == nil && airTemperatureCelsius == nil
    }
}
