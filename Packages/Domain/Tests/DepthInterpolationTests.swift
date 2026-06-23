import Foundation
import Testing
@testable import Domain

@Suite("DepthSample interpolation")
struct DepthInterpolationTests {
    /// Samples one second apart from the given depths.
    private func samples(_ depths: [Double]) -> [DepthSample] {
        depths.enumerated().map {
            DepthSample(timestamp: Date(timeIntervalSince1970: Double($0.offset)), depthMeters: $0.element)
        }
    }

    @Test("interpolates linearly between samples")
    func midpoint() {
        #expect(samples([0, 10]).interpolatedDepth(at: Date(timeIntervalSince1970: 0.5)) == 5)
    }

    @Test("returns the exact sample depth at a sample's timestamp")
    func exact() {
        #expect(samples([2, 4, 6]).interpolatedDepth(at: Date(timeIntervalSince1970: 1)) == 4)
    }

    @Test("clamps to the first/last sample outside the range")
    func clamps() {
        let s = samples([2, 4, 6])
        #expect(s.interpolatedDepth(at: Date(timeIntervalSince1970: -10)) == 2)
        #expect(s.interpolatedDepth(at: Date(timeIntervalSince1970: 100)) == 6)
    }

    @Test("nil for empty; the lone value (clamped both sides) for a single sample")
    func edges() {
        #expect([DepthSample]().interpolatedDepth(at: Date(timeIntervalSince1970: 0)) == nil)
        let one = samples([5])
        #expect(one.interpolatedDepth(at: Date(timeIntervalSince1970: 0)) == 5)
        #expect(one.interpolatedDepth(at: Date(timeIntervalSince1970: 99)) == 5)
    }

    @Test("duplicate timestamps don't divide by zero")
    func duplicateTimestamps() {
        let t = Date(timeIntervalSince1970: 5)
        let s = [DepthSample(timestamp: t, depthMeters: 3), DepthSample(timestamp: t, depthMeters: 7)]
        let depth = s.interpolatedDepth(at: t)
        #expect(depth == 3 || depth == 7)
    }

    @Test("Dive.interpolatedDepth delegates and now clamps within the window")
    func diveDelegates() {
        let dive = Dive(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 2),
            maxDepthMeters: 6,
            samples: samples([2, 4, 6])
        )
        #expect(dive.interpolatedDepth(at: Date(timeIntervalSince1970: 0.5)) == 3)
        #expect(dive.interpolatedDepth(at: Date(timeIntervalSince1970: 100)) == 6)
    }
}
