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

    /// Meters per degree at the equator (the fixtures sit at lat 0), for turning
    /// tolerances into lat/lon deltas and back.
    private let mPerDeg = 111_320.0

    // MARK: - Outlier rejection (spike / accuracy gates)

    @Test("empty / single / pair pass through (too few to judge spikes)")
    func tooFewPoints() {
        #expect(TrackCleaner.clean([]).isEmpty)
        #expect(TrackCleaner.clean([pt(0, 0, t: 0)]).count == 1)
        #expect(TrackCleaner.clean([pt(0, 0, t: 0), pt(0, 1.0, t: 1)]).count == 2)
    }

    @Test("hard-drops truly wild fixes, keeps marginal + unknown accuracy")
    func accuracyGate() {
        // 200 m accuracy is wild (default cutoff 100 m) → dropped; 60 m is
        // marginal (kept, down-weighted); nil accuracy is kept.
        let track = [
            pt(0, 0, t: 0, acc: 10),
            pt(0, 0.00002, t: 1, acc: 60),
            pt(0, 0.00004, t: 2, acc: 200),
            pt(0, 0.00006, t: 3, acc: 10),
        ]
        let cleaned = TrackCleaner.clean(track)
        #expect(cleaned.count == 3) // only the 200 m fix is dropped
        #expect(cleaned.allSatisfy { ($0.location.horizontalAccuracy ?? 0) <= 100 })
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
        let cleaned = TrackCleaner.clean(track)
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
        let cleaned = TrackCleaner.clean(track)
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
        let cleaned = TrackCleaner.clean(track)
        #expect(cleaned.count == 3)
        #expect(cleaned.last?.location.longitude ?? 1 < 0.5)
    }

    @Test("preserves a normal surface swim (no over-rejection)")
    func preservesNormalSwimming() {
        let track = (0..<6).map { pt(0, Double($0) * 0.00002, t: Double($0)) } // ~2.2 m/s
        #expect(TrackCleaner.clean(track).count == 6)
    }

    @Test("keeps a fast real transit leg (fast boat, below the teleport cutoff)")
    func retainsFastTransitLeg() {
        // A genuine ~20 m/s transit leg (fast boat to/from the dive spot): fast
        // enough to swamp any swim speed, but far below the 50 m/s teleport gate,
        // so it must be RETAINED — deleting it would corrupt the map and distance.
        // 10 consecutive fixes, straight east, steady 20 m/s, good ~5 m accuracy.
        let step = 20.0 / mPerDeg // 20 m east per second
        let track = (0..<10).map { pt(0, Double($0) * step, t: Double($0), acc: 5) }
        let cleaned = TrackCleaner.clean(track)
        // Nothing is dropped as a teleport — count is preserved.
        #expect(cleaned.count == track.count)
        // Endpoints stay pinned to their raw coordinates.
        #expect(cleaned.first?.location == track.first?.location)
        #expect(cleaned.last?.location == track.last?.location)
    }

    // MARK: - Kalman smoother: straights, turns, bad fixes

    @Test("a jittery straight line smooths to near-straight")
    func straightLineWithJitter() {
        // A path heading due east at ~2 m/s, jittered ±3 m in latitude.
        let jitterDeg = 3.0 / mPerDeg
        let track = (0..<21).map { i -> TrackPoint in
            let lon = Double(i) * (2.0 / mPerDeg)              // 2 m east per second
            let lat = (i % 2 == 0 ? 1.0 : -1.0) * jitterDeg    // ±3 m wobble
            return pt(lat, lon, t: Double(i), acc: 5)
        }
        let cleaned = TrackCleaner.clean(track)
        // Interior points should sit close to the y = 0 straight line.
        let maxDevMeters = cleaned.dropFirst().dropLast()
            .map { abs($0.location.latitude) * mPerDeg }
            .max() ?? 0
        #expect(maxDevMeters < 2.0) // ±3 m jitter pulled inside ±2 m
    }

    @Test("a sharp genuine turn is preserved (not rounded away)")
    func sharpTurnPreserved() {
        // 10 points east, then 10 points north — a hard 90° corner. No jitter, so
        // any deviation at the corner is the filter rounding a real turn.
        let step = 3.0 / mPerDeg // 3 m per second
        var track: [TrackPoint] = []
        for i in 0..<10 { track.append(pt(0, Double(i) * step, t: Double(i), acc: 5)) }
        let cornerLon = Double(9) * step
        for i in 1...10 { track.append(pt(Double(i) * step, cornerLon, t: Double(9 + i), acc: 5)) }

        let cleaned = TrackCleaner.clean(track)
        // The corner vertex (index 9, the easternmost point) must stay near the
        // real corner: it should not be pulled far off the true (cornerLon, 0).
        let corner = cleaned[9].location
        let offMeters = corner.distance(to: GeoPoint(latitude: 0, longitude: cornerLon))
        #expect(offMeters < 4.0)
    }

    @Test("a single bad-accuracy fix is pulled back and doesn't drag neighbours")
    func badFixDownWeighted() {
        // A straight eastward line at 2 m/s; the middle fix is offset 20 m north
        // but reports poor accuracy (80 m), so the filter should distrust it.
        let step = 2.0 / mPerDeg
        var track = (0..<11).map { pt(0, Double($0) * step, t: Double($0), acc: 5) }
        track[5] = pt(20.0 / mPerDeg, Double(5) * step, t: 5, acc: 80) // bad fix

        let cleaned = TrackCleaner.clean(track)
        // The bad fix is pulled well back toward the line (from 20 m off).
        let badOff = abs(cleaned[5].location.latitude) * mPerDeg
        #expect(badOff < 8.0)
        // Its immediate neighbours stay near the line (not dragged north).
        let leftOff = abs(cleaned[4].location.latitude) * mPerDeg
        let rightOff = abs(cleaned[6].location.latitude) * mPerDeg
        #expect(leftOff < 4.0)
        #expect(rightOff < 4.0)
    }

    @Test("a stationary burst collapses to ~one location")
    func stationaryBurstCollapses() {
        // 8 fixes jittering ±5 m around a fixed point (treading water), acc 10 m.
        let jitter = 5.0 / mPerDeg
        let track = (0..<8).map { i -> TrackPoint in
            let dlat = (i % 2 == 0 ? 1.0 : -1.0) * jitter
            let dlon = (i % 3 == 0 ? 1.0 : -1.0) * jitter
            return pt(dlat, dlon, t: Double(i), acc: 10)
        }
        let cleaned = TrackCleaner.clean(track)
        // The clamp collapses jitter (it must not delete it): all 8 points survive.
        #expect(cleaned.count == 8)
        // Interior points should collapse to essentially the centroid — spread
        // among them shrinks well below the raw ±5 m jitter.
        let interior = Array(cleaned.dropFirst().dropLast())
        #expect(!interior.isEmpty)
        let lat = interior.map(\.location.latitude)
        let lon = interior.map(\.location.longitude)
        let latSpread = (lat.max() ?? 0) - (lat.min() ?? 0)
        let lonSpread = (lon.max() ?? 0) - (lon.min() ?? 0)
        let spread = (latSpread + lonSpread) * mPerDeg
        #expect(spread < 3.0)
    }

    @Test("a slow straight leg is NOT collapsed as stationary")
    func slowStraightNotClamped() {
        // A steady straight swim due east at ~1 m/s (well below the 3 m/s spike
        // threshold), no jitter, over 15 points → 14 m of real travel. Net ≈ path,
        // so it must NOT be mistaken for treading water and clamped to a point.
        let step = 1.0 / mPerDeg // 1 m east per second
        let track = (0..<15).map { pt(0, Double($0) * step, t: Double($0), acc: 6) }
        let expected = 14.0 // 14 hops × 1 m
        let cleaned = TrackCleaner.clean(track)
        // Point count and endpoints are untouched.
        #expect(cleaned.count == 15)
        #expect(cleaned.first?.location == track.first?.location)
        #expect(cleaned.last?.location == track.last?.location)
        // The real length survives — it is not clamped down toward zero.
        #expect(abs(cleaned.surfaceDistanceMeters - expected) < 2.0)
    }

    // MARK: - Distance: never inflated

    @Test("cleaning a jittery track does not inflate its distance")
    func distanceNotInflated() {
        let jitterDeg = 4.0 / mPerDeg
        let track = (0..<30).map { i -> TrackPoint in
            let lon = Double(i) * (2.0 / mPerDeg)
            let lat = (i % 2 == 0 ? 1.0 : -1.0) * jitterDeg
            return pt(lat, lon, t: Double(i), acc: 6)
        }
        let raw = track.surfaceDistanceMeters
        let cleaned = TrackCleaner.clean(track).surfaceDistanceMeters
        #expect(cleaned <= raw) // smoothing reduces or holds the distance
    }

    @Test("a clean synthetic path keeps its distance within tolerance")
    func cleanPathDistancePreserved() {
        // 100 m due east over 50 s, no jitter, good accuracy.
        let track = (0..<51).map { pt(0, Double($0) * (2.0 / mPerDeg), t: Double($0), acc: 3) }
        let expected = 100.0
        let cleaned = TrackCleaner.clean(track).surfaceDistanceMeters
        #expect(abs(cleaned - expected) < 3.0)
    }

    // MARK: - Endpoints pinned

    @Test("first and last coordinates equal the raw endpoints")
    func endpointsPinned() {
        let jitterDeg = 5.0 / mPerDeg
        let track = (0..<15).map { i -> TrackPoint in
            let lon = Double(i) * (2.0 / mPerDeg)
            let lat = (i % 2 == 0 ? 1.0 : -1.0) * jitterDeg
            return pt(lat, lon, t: Double(i), acc: 8)
        }
        let cleaned = TrackCleaner.clean(track)
        #expect(cleaned.first?.location == track.first?.location)
        #expect(cleaned.last?.location == track.last?.location)
    }

    // MARK: - Douglas–Peucker simplification

    @Test("collinear points collapse to just the endpoints")
    func simplifyCollinear() {
        let track = (0..<10).map { pt(0, Double($0) * (2.0 / mPerDeg), t: Double($0)) }
        let simplified = TrackCleaner.simplify(track, toleranceMeters: 2)
        #expect(simplified.count == 2)
        #expect(simplified.first?.location == track.first?.location)
        #expect(simplified.last?.location == track.last?.location)
    }

    @Test("a within-tolerance wobble reduces point count, keeps endpoints")
    func simplifyReducesWithinTolerance() {
        // Straight line with tiny ±1 m wobble, simplified at 3 m tolerance.
        let wob = 1.0 / mPerDeg
        let track = (0..<20).map { i -> TrackPoint in
            pt((i % 2 == 0 ? 1.0 : -1.0) * wob, Double(i) * (2.0 / mPerDeg), t: Double(i))
        }
        let simplified = TrackCleaner.simplify(track, toleranceMeters: 3)
        #expect(simplified.count < track.count)
        #expect(simplified.first?.location == track.first?.location)
        #expect(simplified.last?.location == track.last?.location)
    }

    @Test("a point beyond tolerance is retained")
    func simplifyRetainsBeyondTolerance() {
        // A clear spike 20 m off a short straight line — must survive a 5 m DP.
        let track = [
            pt(0, 0, t: 0),
            pt(20.0 / mPerDeg, 0.00002, t: 1), // 20 m north bump
            pt(0, 0.00004, t: 2),
        ]
        let simplified = TrackCleaner.simplify(track, toleranceMeters: 5)
        #expect(simplified.count == 3)
    }

    @Test("simplify handles empty / single / two-point tracks")
    func simplifyDegenerate() {
        #expect(TrackCleaner.simplify([] as [TrackPoint], toleranceMeters: 3).isEmpty)
        let one = [pt(0, 0, t: 0)]
        #expect(TrackCleaner.simplify(one, toleranceMeters: 3).count == 1)
        let two = [pt(0, 0, t: 0), pt(0, 0.001, t: 1)]
        #expect(TrackCleaner.simplify(two, toleranceMeters: 3).count == 2)
    }

    @Test("simplify does not change effective distance (render-only)")
    func simplifyIsRenderOnly() {
        // Simplifying is cosmetic: the GeoPoint overload matches, and it operates
        // on a copy — the caller's distance uses the un-simplified track.
        let track = (0..<10).map { pt(0, Double($0) * (2.0 / mPerDeg), t: Double($0)) }
        let points = track.map(\.location)
        let simplified = TrackCleaner.simplify(points, toleranceMeters: 2)
        #expect(simplified.count == 2)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
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
