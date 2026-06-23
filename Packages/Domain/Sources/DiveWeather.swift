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
    /// Significant wave height in meters (marine API).
    public var waveHeightMeters: Double?

    public init(weatherCode: Int? = nil, windSpeedKmh: Double? = nil, waveHeightMeters: Double? = nil) {
        self.weatherCode = weatherCode
        self.windSpeedKmh = windSpeedKmh
        self.waveHeightMeters = waveHeightMeters
    }

    /// True when nothing useful was fetched.
    public var isEmpty: Bool {
        weatherCode == nil && windSpeedKmh == nil && waveHeightMeters == nil
    }

    /// Human-readable summary of the WMO weather code, or `nil` if absent/unknown.
    public var conditionDescription: String? {
        guard let weatherCode else { return nil }
        switch weatherCode {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default: return nil
        }
    }
}
