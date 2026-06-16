import Foundation
import Testing
@testable import Domain

@Suite("DiveDetector")
struct DiveDetectorTests {
    /// Builds samples spaced one second apart from a depth profile.
    private func samples(_ depths: [Double], start: Date = Date(timeIntervalSince1970: 0)) -> [DepthSample] {
        depths.enumerated().map { index, depth in
            DepthSample(timestamp: start.addingTimeInterval(Double(index)), depthMeters: depth)
        }
    }

    @Test("detects a single dive from one descent/ascent")
    func detectsSingleDive() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0)
        )
        let dives = detector.detectDives(from: samples([0, 0, 2, 5, 8, 5, 2, 0, 0]))

        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 8)
    }

    @Test("detects two separate dives across a surface interval")
    func detectsTwoDives() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0)
        )
        let dives = detector.detectDives(from: samples([0, 4, 6, 0, 0, 3, 9, 2, 0]))

        #expect(dives.count == 2)
        #expect(dives.map(\.maxDepthMeters) == [6, 9])
    }

    @Test("ignores a shallow, brief bob that fails both thresholds")
    func ignoresShallowNoise() {
        // Under OR semantics a dip is only dropped when it's both too shallow and
        // too brief, so give it a real duration bar to clear.
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 5)
        )
        let dives = detector.detectDives(from: samples([0, 0.5, 1.2, 0.3, 0]))

        #expect(dives.isEmpty)
    }
}
