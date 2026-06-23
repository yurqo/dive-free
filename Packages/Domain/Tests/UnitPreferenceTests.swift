import Foundation
import Testing
@testable import Domain

@Suite("UnitPreference")
struct UnitPreferenceTests {
    @Test("metric and imperial modes resolve every dimension")
    func presetModes() {
        #expect(UnitPreference.metric.depth == .meters)
        #expect(UnitPreference.metric.distance == .metric)
        #expect(UnitPreference.metric.temperature == .celsius)

        #expect(UnitPreference.imperial.depth == .feet)
        #expect(UnitPreference.imperial.distance == .imperial)
        #expect(UnitPreference.imperial.temperature == .fahrenheit)

        #expect(UnitPreference.metric.windSpeed == .kmh)
        #expect(UnitPreference.imperial.windSpeed == .mph)
    }

    @Test("wind speed is taken as-is regardless of the mode")
    func windSpeedIndependentOfMode() {
        #expect(UnitPreference(mode: .metric, windSpeed: .ms).windSpeed == .ms)
        #expect(UnitPreference(mode: .imperial, windSpeed: .knots).windSpeed == .knots)
    }

    @Test("custom mode honours each per-dimension override")
    func customMode() {
        // The freediver case: meters depth, imperial distance/temperature.
        let pref = UnitPreference(
            mode: .custom,
            customDepth: .meters,
            customDistance: .imperial,
            customTemperature: .fahrenheit
        )
        #expect(pref.depth == .meters)
        #expect(pref.distance == .imperial)
        #expect(pref.temperature == .fahrenheit)
    }

    @Test("preset modes ignore stale custom overrides")
    func presetIgnoresOverrides() {
        let pref = UnitPreference(
            mode: .metric,
            customDepth: .feet,
            customDistance: .imperial,
            customTemperature: .fahrenheit
        )
        #expect(pref.depth == .meters)
        #expect(pref.distance == .metric)
        #expect(pref.temperature == .celsius)
    }

    @Test("store then read round-trips every dimension")
    func roundTrip() {
        let defaults = UserDefaults(suiteName: "UnitPreferenceTests.roundTrip")!
        defaults.removePersistentDomain(forName: "UnitPreferenceTests.roundTrip")
        let pref = UnitPreference(
            mode: .custom,
            customDepth: .feet,
            customDistance: .metric,
            customTemperature: .fahrenheit,
            windSpeed: .knots
        )
        pref.store(in: defaults)
        #expect(UnitPreference.read(from: defaults) == pref)
    }

    @Test("unset keys fall back to the region default")
    func emptyFallsBackToRegionDefault() {
        let defaults = UserDefaults(suiteName: "UnitPreferenceTests.empty")!
        defaults.removePersistentDomain(forName: "UnitPreferenceTests.empty")
        #expect(UnitPreference.read(from: defaults) == .regionDefault)
    }

    @Test("Codable round-trips for sync")
    func codable() throws {
        let pref = UnitPreference(mode: .custom, customDepth: .feet, customDistance: .imperial, customTemperature: .celsius, windSpeed: .ms)
        let data = try JSONEncoder().encode(pref)
        #expect(try JSONDecoder().decode(UnitPreference.self, from: data) == pref)
    }

    @Test("decode tolerates a payload missing newer fields (cross-device skew)")
    func lenientDecode() throws {
        // An older build's payload predates the windSpeed key.
        let json = #"{"mode":"imperial","customDepth":"feet","customDistance":"imperial","customTemperature":"fahrenheit"}"#
        let pref = try JSONDecoder().decode(UnitPreference.self, from: Data(json.utf8))
        #expect(pref.mode == .imperial)
        #expect(pref.windSpeed == UnitPreference.regionDefault.windSpeed)
    }
}
