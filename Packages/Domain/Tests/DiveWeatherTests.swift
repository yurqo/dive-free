import Foundation
import Testing
@testable import Domain

@Suite("DiveWeather")
struct DiveWeatherTests {
    @Test("empty by default; any field makes it non-empty")
    func emptiness() {
        #expect(DiveWeather().isEmpty)
        #expect(!DiveWeather(weatherCode: 0).isEmpty)
        #expect(!DiveWeather(windDirectionDegrees: 90).isEmpty)
        #expect(!DiveWeather(waveHeightMeters: 0.5).isEmpty)
    }

    @Test("maps WMO codes to descriptions")
    func conditionDescriptions() throws {
        // Pin the English catalog so the assertions hold regardless of the host
        // language (a plain `tuist test` run inherits the machine's language;
        // without this the strings would resolve to e.g. Ukrainian and fail).
        let english = try #require(
            Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)),
            "Domain bundle is missing its en.lproj resources"
        )
        #expect(DiveWeather(weatherCode: 0).conditionDescription(bundle: english) == "Clear")
        #expect(DiveWeather(weatherCode: 3).conditionDescription(bundle: english) == "Overcast")
        #expect(DiveWeather(weatherCode: 63).conditionDescription(bundle: english) == "Rain")
        #expect(DiveWeather(weatherCode: 95).conditionDescription(bundle: english) == "Thunderstorm")
        #expect(DiveWeather(weatherCode: 1234).conditionDescription(bundle: english) == nil)
        #expect(DiveWeather().conditionDescription(bundle: english) == nil)
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let weather = DiveWeather(weatherCode: 2, windSpeedKmh: 12, windDirectionDegrees: 200, waveHeightMeters: 0.5)
        #expect(try JSONDecoder().decode(DiveWeather.self, from: JSONEncoder().encode(weather)) == weather)
    }

    @Test("legacy payload without wind direction decodes to nil")
    func legacyDecode() throws {
        let json = #"{"weatherCode":2,"windSpeedKmh":12,"waveHeightMeters":0.5}"#
        let decoded = try JSONDecoder().decode(DiveWeather.self, from: Data(json.utf8))
        #expect(decoded.windDirectionDegrees == nil)
        #expect(decoded.windSpeedKmh == 12)
    }

    @Test("session weather defaults to nil/not-fetched; legacy payload decodes")
    func sessionDefaults() throws {
        let session = DiveSession(startTime: Date(timeIntervalSince1970: 0))
        #expect(session.weather == nil)
        #expect(session.weatherFetched == false)

        let json = """
        {"id":"\(UUID().uuidString)","startTime":0,"dives":[],"markers":[]}
        """
        let decoded = try JSONDecoder().decode(DiveSession.self, from: Data(json.utf8))
        #expect(decoded.weather == nil)
        #expect(decoded.weatherFetched == false)
    }
}
