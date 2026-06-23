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

    // MARK: - Manual dive segments (#115)

    @Test("a manual segment defines a dive even when depth never crossed the bar")
    func manualShallowDive() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 3))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0.5, 0.8, 0.6, 0.4], start: start) // all shallow → auto finds nothing
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(3))])
        #expect(dives.count == 1)
        #expect(dives.first?.startTime == start)
    }

    @Test("a manual segment pre-empts an overlapping auto dive (no double count)")
    func manualPreemptsAuto() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0, 4, 8, 5, 0], start: start) // auto would find one dive
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(4))])
        #expect(dives.count == 1)
        #expect(dives.first?.maxDepthMeters == 8)
    }

    @Test("manual + non-overlapping auto dives are both kept, in time order")
    func manualPlusAuto() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let start = Date(timeIntervalSince1970: 0)
        let s = samples([0.5, 0.5, 0.5, 0, 0, 0, 4, 6, 0], start: start) // auto dive late, manual early
        let dives = detector.detectDives(from: s, manualSegments: [DateInterval(start: start, end: start.addingTimeInterval(2))])
        #expect(dives.count == 2)
        #expect(dives.map(\.startTime) == dives.map(\.startTime).sorted())
    }

    @Test("no manual segments behaves like plain detection")
    func noManualSegments() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 1.5, minimumDiveDuration: 0))
        let s = samples([0, 5, 8, 0])
        #expect(detector.detectDives(from: s, manualSegments: []).count == detector.detectDives(from: s).count)
    }
}
