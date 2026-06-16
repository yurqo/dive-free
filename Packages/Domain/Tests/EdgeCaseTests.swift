import Foundation
import Testing
@testable import Domain

@Suite("Domain edge cases")
struct DomainEdgeCaseTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test("detector returns no dives for an empty sample set")
    func emptySamples() {
        #expect(DiveDetector().detectDives(from: []).isEmpty)
    }

    @Test("detector ignores a single momentary sample (zero duration)")
    func singleSample() {
        let detector = DiveDetector(config: DiveDetectionConfig(minimumDiveDepthMeters: 0.5, minimumDiveDuration: 1))
        // A lone deep reading has zero time span; even though it clears the depth
        // bar, the zero-duration floor rejects it (no phantom dive from noise).
        let dives = detector.detectDives(from: [DepthSample(timestamp: t0, depthMeters: 9)])
        #expect(dives.isEmpty)
    }

    @Test("a dive with no samples still reports duration and an empty profile")
    func zeroSampleDive() {
        let dive = Dive(startTime: t0, endTime: t0.addingTimeInterval(30), maxDepthMeters: 5)
        #expect(dive.duration == 30)
        #expect(dive.samples.isEmpty)
        #expect(dive.depthProfile.isEmpty)
    }

    @Test("a single-dive session reports that dive's depth and no surface interval")
    func singleDiveSession() {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(120),
            dives: [Dive(startTime: t0.addingTimeInterval(10), endTime: t0.addingTimeInterval(40), maxDepthMeters: 11)]
        )
        #expect(session.diveCount == 1)
        #expect(session.maxDepthMeters == 11)
        #expect(session.averageSurfaceInterval == nil)
        #expect(session.totalDuration == 120)
    }

    @Test("event kinds expose emoji + label and no longer include a generic custom")
    func eventKindMetadata() {
        #expect(EventKind.allCases.count == 4)
        #expect(EventKind(rawValue: "custom") == nil)
        #expect(EventKind.wildlife.emoji == "🐠")
        #expect(EventKind.hazard.emoji == "⚠️")
        #expect(EventKind.note.label == "Note")
        #expect(EventKind.photo.label == "Photo")
    }

    @Test("decoding an unknown/legacy kind falls back to note")
    func decodesUnknownKindAsNote() throws {
        let legacy = try JSONDecoder().decode(EventKind.self, from: Data("\"custom\"".utf8))
        #expect(legacy == .note)
        let wildlife = try JSONDecoder().decode(EventKind.self, from: Data("\"wildlife\"".utf8))
        #expect(wildlife == .wildlife)  // known values still decode normally
    }

    @Test("an empty session has zero depth, no dives, and no markers")
    func emptySession() {
        let session = DiveSession(startTime: t0)
        #expect(session.maxDepthMeters == 0)
        #expect(session.diveCount == 0)
        #expect(session.totalDuration == 0)        // no endTime
        #expect(session.markerCountsByKind.isEmpty)
    }
}
