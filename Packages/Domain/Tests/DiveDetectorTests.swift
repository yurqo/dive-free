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

    @Test("ignores a shallow, brief bob")
    func ignoresShallowNoise() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Above the surface threshold but under the depth bar, spanning ~1s.
        let dives = detector.detectDives(from: samples([0, 1.2, 1.3, 0]))

        #expect(dives.isEmpty)
    }

    @Test("ignores a long shallow bob that never reaches the depth bar")
    func ignoresLongShallowBob() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Wrist under the surface threshold for ~6s but never past 1.5 m — under
        // the old depth-OR-duration rule this counted; under depth-AND-duration it
        // must not.
        let dives = detector.detectDives(from: samples([0, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 0]))

        #expect(dives.isEmpty)
    }

    @Test("ignores a brief deep spike shorter than the minimum duration")
    func ignoresBriefDeepSpike() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // Reaches 4 m but spans only ~1s (two samples) — too brief to be a dive.
        let dives = detector.detectDives(from: samples([0, 4, 4, 0]))

        #expect(dives.isEmpty)
    }

    @Test("counts a genuine dive that is both deep enough and long enough")
    func countsGenuineDive() {
        let detector = DiveDetector(
            config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3)
        )
        // ≥1.5 m and ≥3 s.
        let dives = detector.detectDives(from: samples([0, 2, 4, 5, 4, 2, 0]))

        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 5)
    }
}
