import Foundation

/// Formats depth readings, accounting for the sensor's measurable ceiling.
///
/// With the publicly-available Shallow Depth and Pressure entitlement the watch
/// can only measure to ~6 m; below that the true depth is unknown, so readings
/// at or beyond the ceiling are shown as "6+" rather than a misleading number.
public enum DepthFormat {
    /// Maximum depth the (shallow) submersion entitlement can measure, in meters.
    /// Readings at or beyond this are rendered with a trailing "+".
    public static let maxMeasurableMeters = 6.0

    /// Depth as a number with unit, e.g. `"5.3 m"` or `"6+ m"` at the ceiling.
    public static func string(_ meters: Double) -> String {
        "\(value(meters)) m"
    }

    /// Depth as a bare number (no unit), e.g. `"5.3"` or `"6+"` at the ceiling.
    /// Use where the caller supplies its own unit/affix.
    public static func value(_ meters: Double) -> String {
        if meters >= maxMeasurableMeters {
            return "\(Int(maxMeasurableMeters))+"
        }
        return String(format: "%.1f", meters)
    }
}

/// Formats surface distances: whole meters under a kilometer, switching to
/// kilometers with one decimal at/above 1 km. Shared by the watch and phone
/// summaries and segment detail screens.
public enum DistanceFormat {
    /// e.g. `"450 m"` or `"1.2 km"`.
    public static func string(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
    }
}
