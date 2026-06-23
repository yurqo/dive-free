import Foundation

/// Formats depth readings, accounting for the sensor's measurable ceiling and the
/// user's chosen depth unit (`UnitPreference`).
///
/// With the publicly-available Shallow Depth and Pressure entitlement the watch
/// can only measure to ~6 m; below that the true depth is unknown, so readings
/// at or beyond the ceiling are shown as "6+" / "20+" rather than a misleading
/// number.
public enum DepthFormat {
    /// Maximum depth the (shallow) submersion entitlement can measure, in meters.
    /// Readings at or beyond this are rendered with a trailing "+".
    public static let maxMeasurableMeters = 6.0

    static let feetPerMeter = 3.28084

    /// Depth as a number with unit, e.g. `"5.3 m"` / `"17 ft"`, or `"6+ m"` /
    /// `"20+ ft"` at the ceiling.
    public static func string(_ meters: Double, units: UnitPreference = .current) -> String {
        "\(value(meters, units: units)) \(unitLabel(units))"
    }

    /// Depth as a bare number (no unit), e.g. `"5.3"` / `"17"`, or `"6+"` / `"20+"`
    /// at the ceiling. Use where the caller supplies its own unit/affix.
    public static func value(_ meters: Double, units: UnitPreference = .current) -> String {
        let ceilingReached = meters >= maxMeasurableMeters
        let display = ceilingReached ? maxMeasurableMeters : meters
        switch units.depth {
        case .meters:
            let number = ceilingReached ? "\(Int(maxMeasurableMeters))" : String(format: "%.1f", display)
            return ceilingReached ? "\(number)+" : number
        case .feet:
            // Whole feet — 0.1 ft precision is meaningless for free-dive depths.
            let number = "\(Int((display * feetPerMeter).rounded()))"
            return ceilingReached ? "\(number)+" : number
        }
    }

    /// The depth unit symbol for the current preference (`"m"` / `"ft"`).
    public static func unitLabel(_ units: UnitPreference = .current) -> String {
        units.depth == .meters ? "m" : "ft"
    }

    /// Numeric depth in the display unit, for plotting on a chart axis.
    public static func displayDepth(_ meters: Double, units: UnitPreference = .current) -> Double {
        units.depth == .meters ? meters : meters * feetPerMeter
    }

    /// Chart axis caption for the current depth unit, e.g. `"Depth (m)"`.
    public static func axisLabel(_ units: UnitPreference = .current) -> String {
        "Depth (\(unitLabel(units)))"
    }
}

/// Formats surface distances in the user's chosen unit family: metric switches
/// whole meters → kilometers (1 decimal) at 1 km; imperial switches whole feet →
/// miles (1 decimal) at 1 mile. Shared by the watch and phone summaries and
/// segment detail screens.
public enum DistanceFormat {
    static let metersPerMile = 1609.344

    /// e.g. `"450 m"` / `"1.2 km"`, or `"1480 ft"` / `"1.4 mi"`.
    public static func string(_ meters: Double, units: UnitPreference = .current) -> String {
        switch units.distance {
        case .metric:
            return meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
        case .imperial:
            let feet = meters * DepthFormat.feetPerMeter
            return meters < metersPerMile ? "\(Int(feet.rounded())) ft" : String(format: "%.1f mi", meters / metersPerMile)
        }
    }

    /// A compact whole-number distance for small magnitudes (e.g. GPS accuracy),
    /// without the km/mi switchover: meters or feet per the distance unit.
    public static func compact(_ meters: Double, units: UnitPreference = .current) -> String {
        switch units.distance {
        case .metric: return "\(Int(meters.rounded())) m"
        case .imperial: return "\(Int((meters * DepthFormat.feetPerMeter).rounded())) ft"
        }
    }
}

/// Formats water/air temperatures (stored in °C) in the user's chosen unit.
public enum TemperatureFormat {
    /// Temperature as a number with unit, e.g. `"21°C"` / `"70°F"`.
    public static func string(_ celsius: Double, units: UnitPreference = .current) -> String {
        "\(value(celsius, units: units))\(unitLabel(units))"
    }

    /// Temperature as a bare whole number (no unit), converted to the display unit.
    public static func value(_ celsius: Double, units: UnitPreference = .current) -> String {
        "\(Int(displayValue(celsius, units: units).rounded()))"
    }

    /// Numeric temperature in the display unit, for plotting on a chart axis.
    public static func displayValue(_ celsius: Double, units: UnitPreference = .current) -> Double {
        units.temperature == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// The temperature unit symbol for the current preference (`"°C"` / `"°F"`).
    public static func unitLabel(_ units: UnitPreference = .current) -> String {
        units.temperature == .celsius ? "°C" : "°F"
    }
}
