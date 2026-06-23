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
            customTemperature: .fahrenheit
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
        let pref = UnitPreference(mode: .custom, customDepth: .feet, customDistance: .imperial, customTemperature: .celsius)
        let data = try JSONEncoder().encode(pref)
        #expect(try JSONDecoder().decode(UnitPreference.self, from: data) == pref)
    }
}
