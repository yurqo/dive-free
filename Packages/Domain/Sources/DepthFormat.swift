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

    /// Exact depth string for a **selectable** value (a settings/threshold label),
    /// never the ceiling "+": e.g. `"6 m"` / `"20 ft"` / `"1.5 m"`. Unlike `string`,
    /// values at or beyond the ceiling render plainly — the caller is labelling a
    /// chosen threshold, not a measured reading, so "6+ m" (which reads as "beyond
    /// 6 m") would be wrong. A whole number drops its trailing decimal the locale-
    /// aware way.
    public static func exact(_ meters: Double, units: UnitPreference = .current) -> String {
        "\(exactValue(meters, units: units)) \(unitLabel(units))"
    }

    /// Bare number for `exact` (no unit): whole meters drop the trailing ".0"
    /// (`"6"`), fractional keep one decimal (`"1.5"`); feet are always whole.
    public static func exactValue(_ meters: Double, units: UnitPreference = .current) -> String {
        switch units.depth {
        case .meters:
            return meters.formatted(.number.precision(.fractionLength(0...1)))
        case .feet:
            return "\(Int((meters * feetPerMeter).rounded()))"
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

    /// Converts a value entered in the display unit back to °C for storage.
    public static func celsius(fromDisplay value: Double, units: UnitPreference = .current) -> Double {
        units.temperature == .celsius ? value : (value - 32) * 5 / 9
    }

    /// The temperature unit symbol for the current preference (`"°C"` / `"°F"`).
    public static func unitLabel(_ units: UnitPreference = .current) -> String {
        units.temperature == .celsius ? "°C" : "°F"
    }
}

/// Formats wind: speed (stored in km/h, Open-Meteo's default) in the user's chosen
/// `WindSpeedUnit`, plus a compass heading from meteorological degrees. `summary`
/// combines them into one line, e.g. `"NE, 10 km/h"`.
public enum WindSpeedFormat {
    static let mphPerKmh = 0.621371
    static let knotsPerKmh = 0.539957
    static let msPerKmh = 1.0 / 3.6

    /// Wind speed with unit, e.g. `"10 km/h"` / `"2.8 m/s"` / `"6 mph"` / `"5 kn"`.
    public static func string(_ kmh: Double, units: UnitPreference = .current) -> String {
        "\(value(kmh, units: units)) \(unitLabel(units))"
    }

    /// Bare wind-speed number in the display unit (whole, except m/s → 1 decimal,
    /// since metres-per-second values for wind are small).
    public static func value(_ kmh: Double, units: UnitPreference = .current) -> String {
        switch units.windSpeed {
        case .kmh: return "\(Int(kmh.rounded()))"
        case .ms: return String(format: "%.1f", kmh * msPerKmh)
        case .mph: return "\(Int((kmh * mphPerKmh).rounded()))"
        case .knots: return "\(Int((kmh * knotsPerKmh).rounded()))"
        }
    }

    /// The wind-speed unit symbol (`"km/h"` / `"m/s"` / `"mph"` / `"kn"`).
    public static func unitLabel(_ units: UnitPreference = .current) -> String {
        switch units.windSpeed {
        case .kmh: return "km/h"
        case .ms: return "m/s"
        case .mph: return "mph"
        case .knots: return "kn"
        }
    }

    /// 16-point compass abbreviation for a meteorological wind direction (the
    /// heading the wind blows *from*), e.g. 45° → `"NE"`. `nil` when absent.
    public static func compass(_ degrees: Double?) -> String? {
        guard let degrees else { return nil }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let index = Int((positive / 22.5).rounded()) % 16
        return points[index]
    }

    /// One-line wind summary, e.g. `"NE, 10 km/h"` (direction prepended when
    /// known). `nil` when there's no wind speed to show.
    public static func summary(speedKmh: Double?, directionDegrees: Double?, units: UnitPreference = .current) -> String? {
        guard let speedKmh else { return nil }
        let speed = string(speedKmh, units: units)
        guard let direction = compass(directionDegrees) else { return speed }
        return "\(direction), \(speed)"
    }
}
