import Foundation

/// Auto-fetched weather/marine extras for a session (from Open-Meteo), beyond the
/// air/water temperatures, which pre-fill the manual `DiveConditions`. Stored once
/// the fetch has run; `DiveSession.weatherFetched` records whether it was
/// attempted so the deferred pass doesn't refetch.
public struct DiveWeather: Codable, Sendable, Equatable {
    /// WMO weather interpretation code (0 = clear … 95+ = thunderstorm).
    public var weatherCode: Int?
    /// Wind speed in km/h (Open-Meteo's default unit).
    public var windSpeedKmh: Double?
    /// Meteorological wind direction in degrees (the heading the wind blows
    /// *from*); rendered as a compass point next to the speed.
    public var windDirectionDegrees: Double?
    /// Significant wave height in meters (marine API).
    public var waveHeightMeters: Double?

    public init(
        weatherCode: Int? = nil,
        windSpeedKmh: Double? = nil,
        windDirectionDegrees: Double? = nil,
        waveHeightMeters: Double? = nil
    ) {
        self.weatherCode = weatherCode
        self.windSpeedKmh = windSpeedKmh
        self.windDirectionDegrees = windDirectionDegrees
        self.waveHeightMeters = waveHeightMeters
    }

    /// True when nothing useful was fetched.
    public var isEmpty: Bool {
        weatherCode == nil && windSpeedKmh == nil && windDirectionDegrees == nil && waveHeightMeters == nil
    }

    /// Human-readable summary of the WMO weather code, or `nil` if absent/unknown.
    /// A display string (never persisted or synced — only `weatherCode` is
    /// stored), so it's localized against `Bundle.module` (Domain's own bundle).
    public var conditionDescription: String? {
        conditionDescription(bundle: .module)
    }

    /// Testing seam: resolves the description against an explicit bundle so unit
    /// tests can pin a known localization (e.g. `en.lproj`) regardless of the
    /// host app's language. Production callers use the parameterless property.
    func conditionDescription(bundle: Bundle) -> String? {
        guard let weatherCode else { return nil }
        switch weatherCode {
        case 0: return String(localized: "Clear", bundle: bundle)
        case 1: return String(localized: "Mainly clear", bundle: bundle)
        case 2: return String(localized: "Partly cloudy", bundle: bundle)
        case 3: return String(localized: "Overcast", bundle: bundle)
        case 45, 48: return String(localized: "Fog", bundle: bundle)
        case 51, 53, 55, 56, 57: return String(localized: "Drizzle", bundle: bundle)
        case 61, 63, 65, 66, 67: return String(localized: "Rain", bundle: bundle)
        case 71, 73, 75, 77: return String(localized: "Snow", bundle: bundle)
        case 80, 81, 82: return String(localized: "Rain showers", bundle: bundle)
        case 85, 86: return String(localized: "Snow showers", bundle: bundle)
        case 95: return String(localized: "Thunderstorm", bundle: bundle)
        case 96, 99: return String(localized: "Thunderstorm, hail", bundle: bundle)
        default: return nil
        }
    }
}
