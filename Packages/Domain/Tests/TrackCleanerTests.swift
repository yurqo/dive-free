import Foundation
import Testing
@testable import Domain

@Suite("TrackCleaner")
struct TrackCleanerTests {
    /// A track point at `(lat, lon)`, `t` seconds in, with optional accuracy.
    private func pt(_ lat: Double, _ lon: Double, t: Double, acc: Double? = nil) -> TrackPoint {
        TrackPoint(
            timestamp: Date(timeIntervalSince1970: t),
            location: GeoPoint(latitude: lat, longitude: lon, horizontalAccuracy: acc)
        )
    }

    /// No smoothing, default gates — isolates outlier rejection.
    private let rejectOnly = TrackCleaner.Config(maxAccuracyMeters: 50, maxSpeedMetersPerSecond: 3, smoothingWindow: 1)

    @Test("empty / single / pair pass through (too few to judge spikes)")
    func tooFewPoints() {
        #expect(TrackCleaner.clean([], config: rejectOnly).isEmpty)
        #expect(TrackCleaner.clean([pt(0, 0, t: 0)], config: rejectOnly).count == 1)
        #expect(TrackCleaner.clean([pt(0, 0, t: 0), pt(0, 1.0, t: 1)], config: rejectOnly).count == 2)
    }

    @Test("drops fixes worse than the accuracy cutoff, keeps unknown accuracy")
    func accuracyGate() {
        let track = [pt(0, 0, t: 0, acc: 10), pt(0, 0.00002, t: 1, acc: 200), pt(0, 0.00004, t: 2, acc: 10)]
        let cleaned = TrackCleaner.clean(track, config: rejectOnly)
        #expect(cleaned.count == 2) // the 200 m-accuracy fix is dropped
        #expect(cleaned.allSatisfy { ($0.location.horizontalAccuracy ?? 0) <= 50 })
    }

    @Test("rejects a mid-track teleport, keeping the neighbours")
    func midTrackTeleport() {
        let track = [
            pt(0, 0, t: 0),
            pt(0, 0.00002, t: 1),  // ~2.2 m
            pt(0, 1.0, t: 2),      // ~111 km jump — spike
            pt(0, 0.00004, t: 3),
            pt(0, 0.00006, t: 4),
        ]
        let cleaned = TrackCleaner.clean(track, config: rejectOnly)
        #expect(cleaned.count == 4)
        #expect(!cleaned.contains { $0.location.longitude > 0.5 })
    }

    @Test("rejects a teleport at the start")
    func teleportAtStart() {
        let track = [
            pt(0, 1.0, t: 0),      // spike
            pt(0, 0, t: 1),
            pt(0, 0.00002, t: 2),
            pt(0, 0.00004, t: 3),
        ]
        let cleaned = TrackCleaner.clean(track, config: rejectOnly)
        #expect(cleaned.count == 3)
        #expect(cleaned.first?.location.longitude ?? 1 < 0.5)
    }

    @Test("rejects a teleport at the end")
    func teleportAtEnd() {
        let track = [
            pt(0, 0, t: 0),
            pt(0, 0.00002, t: 1),
            pt(0, 0.00004, t: 2),
            pt(0, 1.0, t: 3),      // spike
        ]
        let cleaned = TrackCleaner.clean(track, config: rejectOnly)
        #expect(cleaned.count == 3)
        #expect(cleaned.last?.location.longitude ?? 1 < 0.5)
    }

    @Test("preserves a normal surface swim (no over-rejection)")
    func preservesNormalSwimming() {
        let track = (0..<6).map { pt(0, Double($0) * 0.00002, t: Double($0)) } // ~2.2 m/s
        #expect(TrackCleaner.clean(track, config: rejectOnly).count == 6)
    }

    @Test("smoothing reduces wobble; window 1 is a no-op for distance")
    func smoothing() {
        // A zigzag wobbling ±1 m around a straight eastward line.
        let track = (0..<7).map { i in
            pt((i % 2 == 0) ? 0.00001 : -0.00001, Double(i) * 0.00002, t: Double(i))
        }
        let raw = track.surfaceDistanceMeters
        let fast = TrackCleaner.Config(maxAccuracyMeters: 50, maxSpeedMetersPerSecond: 100, smoothingWindow: 3)
        let smoothed = TrackCleaner.clean(track, config: fast).surfaceDistanceMeters
        let noop = TrackCleaner.clean(track, config: TrackCleaner.Config(maxAccuracyMeters: 50, maxSpeedMetersPerSecond: 100, smoothingWindow: 1)).surfaceDistanceMeters
        #expect(smoothed < raw)
        #expect(abs(noop - raw) < 0.001)
    }
}

@Suite("DiveSession.smoothTrack")
struct DiveSessionSmoothTrackTests {
    private func pt(_ lat: Double, _ lon: Double, t: Double) -> TrackPoint {
        TrackPoint(timestamp: Date(timeIntervalSince1970: t), location: GeoPoint(latitude: lat, longitude: lon))
    }

    private func sessionWithTeleport(smooth: Bool) -> DiveSession {
        let track = [
            pt(0, 0, t: 0),
            pt(0, 0.00002, t: 1),
            pt(0, 1.0, t: 2),     // teleport
            pt(0, 0.00004, t: 3),
            pt(0, 0.00006, t: 4),
        ]
        return DiveSession(startTime: Date(timeIntervalSince1970: 0), track: track, smoothTrack: smooth)
    }

    @Test("smoothing excludes a teleport from the distance; raw includes it")
    func distanceRespectsToggle() {
        let smoothedDistance = sessionWithTeleport(smooth: true).surfaceDistanceMeters
        let rawDistance = sessionWithTeleport(smooth: false).surfaceDistanceMeters
        #expect(rawDistance > 100_000) // the ~111 km teleport dominates
        #expect(smoothedDistance < 100)  // a few metres of real swimming
    }

    @Test("smoothTrack defaults to on and survives a JSON round trip")
    func codable() throws {
        var session = sessionWithTeleport(smooth: false)
        session.smoothTrack = true
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(DiveSession.self, from: data).smoothTrack == true)

        // A payload predating the field defaults to on.
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "smoothTrack")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        #expect(try JSONDecoder().decode(DiveSession.self, from: legacy).smoothTrack == true)
    }
}
