import Foundation
import Testing
@testable import Sensors

@Suite("makeDepthSample")
struct WaterSubmersionDepthProviderTests {
    @Test("passes through a depth already expressed in meters")
    func metersRoundtrip() {
        let date = Date(timeIntervalSince1970: 1_000)
        let sample = makeDepthSample(depth: Measurement(value: 12.5, unit: .meters), date: date)
        #expect(sample.depthMeters == 12.5)
        #expect(sample.timestamp == date)
    }

    @Test("converts feet to meters (10 ft → 3.048 m)")
    func feetToMeters() {
        let sample = makeDepthSample(depth: Measurement(value: 10.0, unit: .feet), date: Date())
        #expect(abs(sample.depthMeters - 3.048) < 0.0001)
    }

    @Test("makeDepthProvider returns MockDepthProvider when sensor is unavailable")
    func fallbackProvider() {
        // Test target runs on iOS — no water-submersion sensor — so the mock
        // path is exercised here.
        let provider = makeDepthProvider()
        #expect(provider is MockDepthProvider)
    }
}
