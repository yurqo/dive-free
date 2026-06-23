import Foundation
import Domain

/// Result of an Open-Meteo fetch: the air/sea temperatures (which pre-fill the
/// manual `DiveConditions`) plus the weather extras (stored as `DiveWeather`).
public struct WeatherSnapshot: Sendable, Equatable {
    public var airTemperatureCelsius: Double?
    public var seaTemperatureCelsius: Double?
    public var weatherCode: Int?
    public var windSpeedKmh: Double?
    public var windDirectionDegrees: Double?
    public var waveHeightMeters: Double?

    public init(
        airTemperatureCelsius: Double? = nil,
        seaTemperatureCelsius: Double? = nil,
        weatherCode: Int? = nil,
        windSpeedKmh: Double? = nil,
        windDirectionDegrees: Double? = nil,
        waveHeightMeters: Double? = nil
    ) {
        self.airTemperatureCelsius = airTemperatureCelsius
        self.seaTemperatureCelsius = seaTemperatureCelsius
        self.weatherCode = weatherCode
        self.windSpeedKmh = windSpeedKmh
        self.windDirectionDegrees = windDirectionDegrees
        self.waveHeightMeters = waveHeightMeters
    }

    /// The persistable weather extras (everything except the temperatures).
    public var weather: DiveWeather {
        DiveWeather(
            weatherCode: weatherCode,
            windSpeedKmh: windSpeedKmh,
            windDirectionDegrees: windDirectionDegrees,
            waveHeightMeters: waveHeightMeters
        )
    }
}

/// Best-effort weather + marine lookup from Open-Meteo (free, no API key) for a
/// session's location and start time. Time-boxed so it never hangs the UI; the
/// caller treats `nil` as "fetch failed — retry later" and a non-nil result as
/// "fetched" (even if some fields are missing, e.g. an inland spot has no marine
/// data). The forecast endpoint with explicit dates covers recent dives.
public enum WeatherProvider {
    public static func fetch(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeout: Duration = .seconds(8),
        session: URLSession = .shared
    ) async -> WeatherSnapshot? {
        await withTaskGroup(of: WeatherSnapshot?.self) { group in
            group.addTask { await load(latitude: latitude, longitude: longitude, date: date, session: session) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func load(latitude: Double, longitude: Double, date: Date, session: URLSession) async -> WeatherSnapshot? {
        guard let weatherURL = weatherURL(latitude: latitude, longitude: longitude, date: date),
              let marineURL = marineURL(latitude: latitude, longitude: longitude, date: date) else { return nil }
        async let weather = try? session.data(from: weatherURL).0
        async let marine = try? session.data(from: marineURL).0
        return snapshot(weatherData: await weather, marineData: await marine, at: date)
    }

    // MARK: - Pure helpers (unit-tested)

    static func weatherURL(latitude: Double, longitude: Double, date: Date) -> URL? {
        url(
            base: "https://api.open-meteo.com/v1/forecast",
            latitude: latitude, longitude: longitude, date: date,
            hourly: "temperature_2m,weathercode,windspeed_10m,winddirection_10m"
        )
    }

    static func marineURL(latitude: Double, longitude: Double, date: Date) -> URL? {
        url(
            base: "https://marine-api.open-meteo.com/v1/marine",
            latitude: latitude, longitude: longitude, date: date,
            hourly: "sea_surface_temperature,wave_height"
        )
    }

    private static func url(base: String, latitude: Double, longitude: Double, date: Date, hourly: String) -> URL? {
        let day = isoDay(date)
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: hourly),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
            URLQueryItem(name: "timezone", value: "UTC"),
        ]
        return components?.url
    }

    /// Combines decoded weather + marine responses into a snapshot at the hour
    /// nearest `date`. Returns `nil` only when neither endpoint yielded usable data.
    static func snapshot(weatherData: Data?, marineData: Data?, at date: Date) -> WeatherSnapshot? {
        var snapshot = WeatherSnapshot()
        var any = false

        if let weatherData,
           let response = try? JSONDecoder().decode(WeatherResponse.self, from: weatherData),
           let hourly = response.hourly,
           let index = nearestIndex(times: hourly.time, to: date) {
            snapshot.airTemperatureCelsius = element(hourly.temperature_2m, at: index)
            snapshot.weatherCode = element(hourly.weathercode, at: index)
            snapshot.windSpeedKmh = element(hourly.windspeed_10m, at: index)
            snapshot.windDirectionDegrees = element(hourly.winddirection_10m, at: index)
            any = true
        }

        if let marineData,
           let response = try? JSONDecoder().decode(MarineResponse.self, from: marineData),
           let hourly = response.hourly,
           let index = nearestIndex(times: hourly.time, to: date) {
            snapshot.seaTemperatureCelsius = element(hourly.sea_surface_temperature, at: index)
            snapshot.waveHeightMeters = element(hourly.wave_height, at: index)
            any = true
        }

        return any ? snapshot : nil
    }

    /// Index of the hourly sample closest in time to `date` (times are UTC
    /// `yyyy-MM-dd'T'HH:mm`).
    static func nearestIndex(times: [String], to date: Date) -> Int? {
        var best: (index: Int, diff: TimeInterval)?
        for (index, value) in times.enumerated() {
            guard let parsed = hourFormatter.date(from: value) else { continue }
            let diff = abs(parsed.timeIntervalSince(date))
            if best == nil || diff < best!.diff { best = (index, diff) }
        }
        return best?.index
    }

    private static func element<T>(_ array: [T?]?, at index: Int) -> T? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    private static func isoDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Open-Meteo response shapes

private struct WeatherResponse: Decodable {
    let hourly: Hourly?
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]?
        let weathercode: [Int?]?
        let windspeed_10m: [Double?]?
        let winddirection_10m: [Double?]?
    }
}

private struct MarineResponse: Decodable {
    let hourly: Hourly?
    struct Hourly: Decodable {
        let time: [String]
        let sea_surface_temperature: [Double?]?
        let wave_height: [Double?]?
    }
}
