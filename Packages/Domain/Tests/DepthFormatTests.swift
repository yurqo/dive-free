import Foundation
import Testing
@testable import Domain

@Suite("DepthFormat")
struct DepthFormatTests {
    @Test("formats sub-ceiling depths with one decimal and a unit")
    func belowCeiling() {
        #expect(DepthFormat.string(0) == "0.0 m")
        #expect(DepthFormat.string(5.34) == "5.3 m")
        #expect(DepthFormat.value(3.0) == "3.0")
    }

    @Test("renders the ceiling and beyond as N+")
    func atOrAboveCeiling() {
        #expect(DepthFormat.string(6.0) == "6+ m")
        #expect(DepthFormat.string(9.9) == "6+ m")
        #expect(DepthFormat.value(6.0) == "6+")
    }

    @Test("just below the ceiling still shows a number")
    func justBelowCeiling() {
        #expect(DepthFormat.string(5.9) == "5.9 m")
    }
}
