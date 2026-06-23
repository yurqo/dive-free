import Foundation
import Testing
@testable import Domain

@Suite("DepthFormat")
struct DepthFormatTests {
    @Test("formats sub-ceiling depths with one decimal and a unit (metric)")
    func belowCeiling() {
        #expect(DepthFormat.string(0, units: .metric) == "0.0 m")
        #expect(DepthFormat.string(5.34, units: .metric) == "5.3 m")
        #expect(DepthFormat.value(3.0, units: .metric) == "3.0")
    }

    @Test("renders the ceiling and beyond as N+ (metric)")
    func atOrAboveCeiling() {
        #expect(DepthFormat.string(6.0, units: .metric) == "6+ m")
        #expect(DepthFormat.string(9.9, units: .metric) == "6+ m")
        #expect(DepthFormat.value(6.0, units: .metric) == "6+")
    }

    @Test("just below the ceiling still shows a number (metric)")
    func justBelowCeiling() {
        #expect(DepthFormat.string(5.9, units: .metric) == "5.9 m")
    }

    @Test("converts to whole feet, with the ceiling at 20+ ft (imperial)")
    func imperialDepth() {
        #expect(DepthFormat.string(0, units: .imperial) == "0 ft")
        #expect(DepthFormat.string(5.0, units: .imperial) == "16 ft") // 5 m ≈ 16.4 ft
        #expect(DepthFormat.string(6.0, units: .imperial) == "20+ ft") // 6 m ≈ 19.7 ft
        #expect(DepthFormat.string(9.9, units: .imperial) == "20+ ft")
    }
}

@Suite("DistanceFormat")
struct DistanceFormatTests {
    @Test("metric: meters under a km, kilometers above")
    func metric() {
        #expect(DistanceFormat.string(450, units: .metric) == "450 m")
        #expect(DistanceFormat.string(1200, units: .metric) == "1.2 km")
    }

    @Test("imperial: feet under a mile, miles above")
    func imperial() {
        #expect(DistanceFormat.string(100, units: .imperial) == "328 ft") // 100 m ≈ 328 ft
        #expect(DistanceFormat.string(3218.69, units: .imperial) == "2.0 mi") // ≈ 2 miles
    }

    @Test("compact never switches to km/mi (for small readouts like GPS accuracy)")
    func compact() {
        #expect(DistanceFormat.compact(8, units: .metric) == "8 m")
        #expect(DistanceFormat.compact(8, units: .imperial) == "26 ft") // 8 m ≈ 26.2 ft
    }
}

@Suite("TemperatureFormat")
struct TemperatureFormatTests {
    @Test("celsius is shown as whole degrees")
    func celsius() {
        #expect(TemperatureFormat.string(21.4, units: .metric) == "21°C")
        #expect(TemperatureFormat.value(21.4, units: .metric) == "21")
    }

    @Test("fahrenheit converts and rounds")
    func fahrenheit() {
        #expect(TemperatureFormat.string(0, units: .imperial) == "32°F")
        #expect(TemperatureFormat.string(21, units: .imperial) == "70°F") // 21°C = 69.8°F
    }
}
