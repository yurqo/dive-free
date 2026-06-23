import Foundation

/// Underwater visibility, as a coarse category (distance-based grading is a
/// future refinement). Named `WaterVisibility` to avoid clashing with SwiftUI's
/// `Visibility`.
public enum WaterVisibility: String, Codable, CaseIterable, Sendable {
    case poor, fair, good, excellent

    public var label: String { rawValue.capitalized }
}

/// Strength of the water current.
public enum WaterCurrent: String, Codable, CaseIterable, Sendable {
    case none, light, moderate, strong

    public var label: String { rawValue.capitalized }
}

/// Surface state.
public enum SurfaceCondition: String, Codable, CaseIterable, Sendable {
    case calm, choppy, rough

    public var label: String { rawValue.capitalized }
}

/// Tide stage at the time of the dive.
public enum TideStage: String, Codable, CaseIterable, Sendable {
    case low, incoming, high, outgoing

    public var label: String { rawValue.capitalized }
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
