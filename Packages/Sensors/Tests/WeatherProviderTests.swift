import Foundation
import Testing
@testable import Sensors

@Suite("WeatherProvider")
struct WeatherProviderTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("builds Open-Meteo URLs with the dive's UTC day and hourly variables")
    func urls() {
        let date = utc(2024, 6, 20, 11, 0)
        let weather = WeatherProvider.weatherURL(latitude: 12.5, longitude: -70.0, date: date)?.absoluteString ?? ""
        #expect(weather.contains("api.open-meteo.com/v1/forecast"))
        #expect(weather.contains("latitude=12.5"))
        #expect(weather.contains("start_date=2024-06-20"))
        #expect(weather.contains("temperature_2m"))
        #expect(weather.contains("winddirection_10m"))

        let marine = WeatherProvider.marineURL(latitude: 12.5, longitude: -70.0, date: date)?.absoluteString ?? ""
        #expect(marine.contains("marine-api.open-meteo.com/v1/marine"))
        #expect(marine.contains("sea_surface_temperature"))
        #expect(marine.contains("wave_height"))
    }

    @Test("picks the hourly sample nearest the dive time")
    func nearestIndex() {
        let times = ["2024-06-20T10:00", "2024-06-20T11:00", "2024-06-20T12:00"]
        #expect(WeatherProvider.nearestIndex(times: times, to: utc(2024, 6, 20, 11, 20)) == 1)
        #expect(WeatherProvider.nearestIndex(times: times, to: utc(2024, 6, 20, 9, 0)) == 0)
        #expect(WeatherProvider.nearestIndex(times: times, to: utc(2024, 6, 20, 23, 0)) == 2)
        #expect(WeatherProvider.nearestIndex(times: [], to: utc(2024, 6, 20, 11, 0)) == nil)
    }

    @Test("combines weather + marine JSON into a snapshot at the nearest hour")
    func snapshot() throws {
        let weatherJSON = """
        {"hourly":{"time":["2024-06-20T10:00","2024-06-20T11:00","2024-06-20T12:00"],
        "temperature_2m":[20.0,21.5,23.0],"weathercode":[1,2,3],"windspeed_10m":[5.0,8.0,10.0],
        "winddirection_10m":[100.0,200.0,300.0]}}
        """
        let marineJSON = """
        {"hourly":{"time":["2024-06-20T10:00","2024-06-20T11:00","2024-06-20T12:00"],
        "sea_surface_temperature":[24.0,24.5,25.0],"wave_height":[0.4,0.5,0.6]}}
        """
        let snapshot = try #require(WeatherProvider.snapshot(
            weatherData: Data(weatherJSON.utf8),
            marineData: Data(marineJSON.utf8),
            at: utc(2024, 6, 20, 11, 20)
        ))
        #expect(snapshot.airTemperatureCelsius == 21.5)
        #expect(snapshot.weatherCode == 2)
        #expect(snapshot.windSpeedKmh == 8.0)
        #expect(snapshot.windDirectionDegrees == 200.0)
        #expect(snapshot.seaTemperatureCelsius == 24.5)
        #expect(snapshot.waveHeightMeters == 0.5)
    }

    @Test("a weather-only response (no marine, e.g. inland) still yields a snapshot")
    func weatherOnly() {
        let weatherJSON = """
        {"hourly":{"time":["2024-06-20T11:00"],"temperature_2m":[19.0],"weathercode":[0],"windspeed_10m":[3.0]}}
        """
        let snapshot = WeatherProvider.snapshot(weatherData: Data(weatherJSON.utf8), marineData: nil, at: utc(2024, 6, 20, 11, 0))
        #expect(snapshot?.airTemperatureCelsius == 19.0)
        #expect(snapshot?.seaTemperatureCelsius == nil)
    }

    @Test("no usable data returns nil (a failed fetch the caller retries)")
    func nothingUsable() {
        #expect(WeatherProvider.snapshot(weatherData: nil, marineData: nil, at: utc(2024, 6, 20, 11, 0)) == nil)
        #expect(WeatherProvider.snapshot(weatherData: Data("garbage".utf8), marineData: nil, at: utc(2024, 6, 20, 11, 0)) == nil)
    }
}
