import Foundation

/// Cleans a raw GPS surface track into a Strava/Apple-Fitness-class path: drops
/// only physically-impossible teleports, then runs an accuracy-weighted,
/// velocity-aware smoother that stays tight on straights, turns crisply, and
/// down-weights poor fixes instead of letting them drag their neighbours. Idle
/// "treading water" jitter collapses to a single point so it doesn't accrete a
/// fuzzy blob or inflate distance.
///
/// The design deliberately separates three things that a single implied-speed
/// threshold used to conflate: **genuine teleports** (kilometres in a second),
/// **ordinary GPS jitter** (a few metres), and **real slow movement**. Teleports
/// are *deleted* by an absolute-speed gate so high it can only mean a bad fix;
/// ordinary jitter is *smoothed* (down-weighted, not deleted — more Strava-like)
/// by the Kalman filter; stationarity is judged from the *smoothed* speed so it
/// can be fooled neither by jitter (which the filter averages out to the true
/// ~2 m/s of a swim) nor by a teleport (already removed upstream).
///
/// Pipeline (all shipped together, staged internally):
///  1. **Soft accuracy gate** — hard-drop only truly wild fixes (accuracy worse
///     than `maxAccuracyMeters`, a generous cutoff). Marginal fixes stay but
///     get down-weighted by the filter via their reported accuracy.
///  2. **Teleport rejection** — drop physically-impossible "teleport" fixes
///     whose implied speed exceeds `teleportSpeedMetersPerSecond` (a very high
///     absolute cutoff no swimmer, boat, vehicle, or drift transit reaches —
///     only a physically-impossible GPS glitch). Ordinary jitter is *not*
///     touched here — it's left for the smoother to down-weight.
///  3. **Accuracy-weighted Kalman smoother** — a 1-D-per-axis constant-velocity
///     Kalman filter run forward then backward (RTS-style two-pass) over the
///     time-ordered fixes, using each fix's `horizontalAccuracy` as the
///     measurement variance (unknown accuracy → `defaultAccuracyMeters`). This
///     keeps position + velocity state, so it tracks straights and turns while
///     down-weighting a bad fix rather than smearing it into its neighbours.
///  4. **Stationary clamp (by smoothed speed)** — collapse maximal *interior*
///     runs whose consecutive smoothed-position speed is below
///     `stationarySpeedMetersPerSecond` to their mean position. Working from the
///     smoothed velocity (which integrates over time) makes this robust: a
///     2 m/s swim reads ~2 m/s regardless of jitter amplitude (not clamped),
///     while treading water reads ~0 (clamped). Endpoints are never moved.
///
/// **Axis choice:** the Kalman filter runs directly on latitude/longitude, with
/// the longitude measurement variance scaled by `cos(latitude)` so a metre of
/// error costs the same on both axes. At surface-swim scales (tens to hundreds of
/// metres, small angles) a flat lat/lon plane is indistinguishable from a proper
/// ENU projection, and staying in degrees keeps the filter dependency-free and
/// the endpoints exactly on their raw coordinates.
///
/// Pure and deterministic, so it is fully unit-testable. Applied **on read** —
/// the raw track is always retained (see `DiveSession.effectiveTrack`); live
/// in-session indicators keep using the raw track.
public enum TrackCleaner {
    public struct Config: Sendable, Equatable {
        /// Hard-drop fixes whose horizontal accuracy is worse (larger) than this,
        /// in meters — only truly wild fixes. Marginal fixes below this stay and
        /// are down-weighted by the filter. Fixes with no known accuracy are kept.
        public var maxAccuracyMeters: Double
        /// Drop a fix as a teleport when the implied speed to a neighbour exceeds
        /// this (m/s) — a deliberately *high* absolute cutoff that only catches
        /// physically-impossible GPS glitches, never real transit. A "forgot to
        /// stop" recording can include a real travel leg to/from the dive spot at
        /// speed-boat or vehicle pace; at 50 m/s (≈ 180 km/h) this cutoff sits
        /// safely above any boat, vehicle, swim, or drift transit, yet a GPS
        /// teleport glitch (hundreds to thousands of m/s over a kilometre-scale
        /// jump in one second) blows straight past it. Deleting real transit fixes
        /// would corrupt the map and inflate/deflate distance, so the bar is set
        /// where only a bad fix can cross it. This is only for teleports: ordinary
        /// few-metre jitter is left for the Kalman smoother to down-weight rather
        /// than delete (more Strava-like).
        public var teleportSpeedMetersPerSecond: Double
        /// Assumed measurement accuracy (meters) for fixes with no reported
        /// horizontal accuracy — a middling value so they weigh neither best nor
        /// worst against neighbours that do report accuracy.
        public var defaultAccuracyMeters: Double
        /// Process-noise density (meters per second, per √second) — how much the
        /// diver's velocity is allowed to change between fixes. Higher tracks
        /// turns more crisply but smooths less; lower is smoother but rounds turns.
        public var processNoiseMetersPerSecond: Double
        /// Speed threshold (m/s) below which a run of consecutive *smoothed* fixes
        /// counts as stationary and collapses to its mean position. Judged on the
        /// Kalman-smoothed positions, whose velocity integrates over time, so
        /// jitter can't inflate it and a real slow swim isn't clamped. Default
        /// 0.35 m/s (≈ 1.26 km/h) sits below any real swim or drift.
        public var stationarySpeedMetersPerSecond: Double

        public init(
            maxAccuracyMeters: Double = 100,
            teleportSpeedMetersPerSecond: Double = 50,
            defaultAccuracyMeters: Double = 15,
            processNoiseMetersPerSecond: Double = 0.5,
            stationarySpeedMetersPerSecond: Double = 0.35
        ) {
            self.maxAccuracyMeters = maxAccuracyMeters
            self.teleportSpeedMetersPerSecond = teleportSpeedMetersPerSecond
            self.defaultAccuracyMeters = defaultAccuracyMeters
            self.processNoiseMetersPerSecond = processNoiseMetersPerSecond
            self.stationarySpeedMetersPerSecond = stationarySpeedMetersPerSecond
        }

        public static let `default` = Config()
    }

    /// Returns a time-ordered, cleaned copy of `track`.
    public static func clean(_ track: [TrackPoint], config: Config = .default) -> [TrackPoint] {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let gated = accuracyGate(ordered, max: config.maxAccuracyMeters)
        let dejumped = rejectTeleports(gated, maxSpeed: config.teleportSpeedMetersPerSecond)
        let smoothed = smooth(dejumped, config: config)
        return clampStationaryBySpeed(smoothed, config: config)
    }

    // MARK: - Stage 1: soft accuracy gate

    /// Drop fixes reported less accurate than `max` meters (only truly wild
    /// fixes); keep fixes with no known accuracy (can't judge them). Marginal
    /// fixes below the cutoff survive and are down-weighted later by the filter.
    private static func accuracyGate(_ track: [TrackPoint], max: Double) -> [TrackPoint] {
        track.filter { point in
            guard let accuracy = point.location.horizontalAccuracy else { return true }
            return accuracy <= max
        }
    }

    // MARK: - Stage 2: teleport rejection

    /// Drop isolated teleports: an interior fix that jumps impossibly fast both
    /// *in* (from the previous fix) and *out* (to the next), or an endpoint that
    /// jumps to a neighbour which is itself consistent with the rest of the track
    /// (so the endpoint, not the neighbour, is the outlier). `maxSpeed` is a very
    /// high absolute cutoff, so this only ever catches genuine teleports —
    /// ordinary few-metre jitter stays and is handled by the smoother. Uses
    /// original adjacency, which is enough for the lone-spike case this targets.
    private static func rejectTeleports(_ track: [TrackPoint], maxSpeed: Double) -> [TrackPoint] {
        guard track.count >= 3 else { return track }

        func speed(_ a: Int, _ b: Int) -> Double {
            let dt = track[b].timestamp.timeIntervalSince(track[a].timestamp)
            guard dt > 0 else { return 0 } // can't judge a zero/negative gap
            return track[a].location.distance(to: track[b].location) / dt
        }

        let last = track.count - 1
        var keep = [Bool](repeating: true, count: track.count)
        for i in track.indices {
            let inSpeed = i > 0 ? speed(i - 1, i) : nil
            let outSpeed = i < last ? speed(i, i + 1) : nil
            switch (inSpeed, outSpeed) {
            case let (.some(s0), .some(s1)):
                if s0 > maxSpeed && s1 > maxSpeed { keep[i] = false }
            case let (nil, .some(s1)):
                // Start: drop if it jumps to point 1 and point 1 is consistent.
                if s1 > maxSpeed && speed(1, 2) <= maxSpeed { keep[i] = false }
            case let (.some(s0), nil):
                // End: symmetric.
                if s0 > maxSpeed && speed(last - 2, last - 1) <= maxSpeed { keep[i] = false }
            case (nil, nil):
                break
            }
        }
        return zip(track, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Stage 4: stationary clamp (by smoothed speed)

    /// Collapse idle "treading water" jitter to a single spot so it doesn't
    /// wander or inflate distance — judged on the *smoothed* track, after the
    /// Kalman pass. For each interior gap we compute the smoothed-position speed
    /// (distance between consecutive smoothed points / dt); a maximal contiguous
    /// run of interior points whose bounding gaps are all below
    /// `stationarySpeedMetersPerSecond` is collapsed to the run's mean position.
    ///
    /// Working from smoothed velocity is what makes this robust where the old
    /// displacement/path-length heuristic failed: the Kalman velocity integrates
    /// over time, so a 2 m/s straight swim with ±5 m jitter still reads ~2 m/s
    /// (not clamped), while treading water reads ~0 (clamped) — jitter amplitude
    /// no longer decides the outcome, and a teleport (already removed upstream)
    /// can't drag a whole window to a centroid. The first and last points are
    /// never part of a run, so endpoints stay pinned to their raw coordinates.
    /// Timestamps/ids/accuracy are preserved and no points are dropped (a
    /// collapsed run keeps every point, moved to the shared mean).
    private static func clampStationaryBySpeed(_ track: [TrackPoint], config: Config) -> [TrackPoint] {
        guard track.count >= 3 else { return track }
        let threshold = config.stationarySpeedMetersPerSecond

        // gapSpeed[i] is the smoothed speed from point i-1 to point i (i in 1..<n).
        // A point is "slow" iff both its bounding gaps are slow — i.e. it's moving
        // slowly whether measured from its predecessor or its successor.
        func gapSpeed(_ i: Int) -> Double {
            let dt = track[i].timestamp.timeIntervalSince(track[i - 1].timestamp)
            guard dt > 0 else { return 0 } // coincident timestamps → treat as still
            return track[i - 1].location.distance(to: track[i].location) / dt
        }

        let last = track.count - 1
        // Interior points only (1..<last); an interior point is stationary when
        // both the hop into it and the hop out of it are below threshold.
        var stationary = [Bool](repeating: false, count: track.count)
        for i in 1..<last {
            if gapSpeed(i) < threshold && gapSpeed(i + 1) < threshold {
                stationary[i] = true
            }
        }

        // Average each maximal stationary run to its mean position (count preserved).
        var result = track
        var i = 1
        while i < last {
            guard stationary[i] else { i += 1; continue }
            var j = i
            while j < last && stationary[j] { j += 1 }
            let run = i..<j
            let count = Double(run.count)
            let lat = run.reduce(0.0) { $0 + track[$1].location.latitude } / count
            let lon = run.reduce(0.0) { $0 + track[$1].location.longitude } / count
            for k in run {
                result[k] = TrackPoint(
                    id: track[k].id,
                    timestamp: track[k].timestamp,
                    location: GeoPoint(
                        latitude: lat, longitude: lon,
                        horizontalAccuracy: track[k].location.horizontalAccuracy
                    )
                )
            }
            i = j
        }
        return result
    }

    // MARK: - Stage 3: accuracy-weighted Kalman smoother

    /// Constant-velocity Kalman filter run per axis (latitude, longitude) in a
    /// forward pass then a backward pass, blending the two so the estimate uses
    /// both past and future fixes (a symmetric, RTS-style two-pass smoother). The
    /// measurement variance is each fix's reported accuracy squared (unknown →
    /// `defaultAccuracyMeters`), so a poor fix is trusted less and pulled toward
    /// the model rather than dragging its neighbours. Distances are worked in
    /// meters (degrees × meters-per-degree, longitude scaled by `cos(lat)`) so
    /// the noise parameters are physical, then converted back to degrees.
    ///
    /// The first and last points are kept fixed so the track's extent — and the
    /// dive submersion/surfacing positions placed along it — aren't pulled inward.
    private static func smooth(_ track: [TrackPoint], config: Config) -> [TrackPoint] {
        guard track.count > 2 else { return track }

        // Reference latitude for the longitude scale (mid-track; the swim spans
        // far too little latitude for this to drift meaningfully).
        let refLat = track[track.count / 2].location.latitude
        let (metersPerDegLat, metersPerDegLon) = metersPerDegree(atLatitude: refLat)
        // At the poles (±90°) `metersPerDegLon` collapses to 0: longitude carries
        // no metric information there and a reverse conversion would divide by
        // zero → NaN/Inf. In that (degenerate) case skip the longitude filter
        // entirely and leave each point's longitude at its raw value; latitude is
        // still smoothed normally. `1e-9` guards against tiny-but-nonzero values.
        let longitudeMetric = metersPerDegLon > 1e-9

        // Per-axis measurements in meters, relative to the first fix (keeps the
        // numbers small and the filter well-conditioned).
        let lat0 = track[0].location.latitude
        let lon0 = track[0].location.longitude
        let latMeters = track.map { ($0.location.latitude - lat0) * metersPerDegLat }

        // Time gaps between consecutive fixes (seconds), floored so a zero/negative
        // gap doesn't stall the model.
        let dts: [Double] = (1..<track.count).map {
            Swift.max(0.001, track[$0].timestamp.timeIntervalSince(track[$0 - 1].timestamp))
        }

        // Measurement variance per fix (meters²): reported accuracy, or default.
        let measVar = track.map { point -> Double in
            let acc = point.location.horizontalAccuracy ?? config.defaultAccuracyMeters
            return Swift.max(1, acc * acc)
        }

        let q = config.processNoiseMetersPerSecond * config.processNoiseMetersPerSecond

        let smoothedLat = kalmanSmooth1D(latMeters, dts: dts, measVar: measVar, q: q)
        // Skip the longitude filter at the poles (see `longitudeMetric` above).
        let smoothedLon: [Double] = longitudeMetric
            ? kalmanSmooth1D(track.map { ($0.location.longitude - lon0) * metersPerDegLon }, dts: dts, measVar: measVar, q: q)
            : []

        let last = track.count - 1
        return track.enumerated().map { index, point in
            // Pin the endpoints to their raw coordinates.
            guard index > 0, index < last else { return point }
            let lat = lat0 + smoothedLat[index] / metersPerDegLat
            // Near a pole, longitude is left at its raw value (never divide by 0).
            let lon = longitudeMetric ? lon0 + smoothedLon[index] / metersPerDegLon : point.location.longitude
            return TrackPoint(
                id: point.id,
                timestamp: point.timestamp,
                location: GeoPoint(latitude: lat, longitude: lon, horizontalAccuracy: point.location.horizontalAccuracy)
            )
        }
    }

    /// One axis of the constant-velocity Kalman smoother. State is `[position,
    /// velocity]`; `z` are the position measurements (meters), `dts[i]` the gap
    /// from `z[i]` to `z[i+1]`, `measVar[i]` the measurement variance of `z[i]`,
    /// `q` the process-noise density. Returns the smoothed positions.
    ///
    /// Forward pass: standard scalar-measurement Kalman update. Backward pass:
    /// the same filter run over the reversed series; the two position estimates
    /// are then combined by inverse-variance weighting, which approximates the
    /// optimal fixed-interval (RTS) smoother while staying trivially deterministic.
    private static func kalmanSmooth1D(_ z: [Double], dts: [Double], measVar: [Double], q: Double) -> [Double] {
        let n = z.count
        guard n > 0 else { return [] }

        // Forward gaps: gapBefore[i] is the interval from i-1 to i.
        let gapBefore: [Double] = [0] + dts

        func run(_ z: [Double], _ measVar: [Double], _ gaps: [Double]) -> (pos: [Double], variance: [Double]) {
            var pos = [Double](repeating: 0, count: n)
            var posVar = [Double](repeating: 0, count: n)

            // State: position x, velocity v. Covariance P (2×2, symmetric).
            var x = z[0]
            var v = 0.0
            var p00 = measVar[0]
            var p01 = 0.0
            var p10 = 0.0
            var p11 = q == 0 ? 1.0 : q // seed velocity uncertainty
            pos[0] = x
            posVar[0] = p00

            for i in 1..<n {
                let dt = gaps[i]
                // Predict: x += v·dt; add process noise to velocity, propagate.
                x += v * dt
                // P = F P Fᵀ + Q, F = [[1, dt],[0,1]], Q on the velocity term.
                let np00 = p00 + dt * (p10 + p01) + dt * dt * p11
                let np01 = p01 + dt * p11
                let np10 = p10 + dt * p11
                let np11 = p11 + q * dt
                p00 = np00; p01 = np01; p10 = np10; p11 = np11

                // Update with measurement z[i].
                let s = p00 + measVar[i]        // innovation variance
                let k0 = p00 / s                // Kalman gain (position)
                let k1 = p10 / s                // Kalman gain (velocity)
                let y = z[i] - x                // innovation
                x += k0 * y
                v += k1 * y
                // P = (I - K H) P, H = [1, 0].
                let up00 = (1 - k0) * p00
                let up01 = (1 - k0) * p01
                let up10 = p10 - k1 * p00
                let up11 = p11 - k1 * p01
                p00 = up00; p01 = up01; p10 = up10; p11 = up11

                pos[i] = x
                posVar[i] = p00
            }
            return (pos, posVar)
        }

        let forward = run(z, measVar, gapBefore)

        // Backward pass over the reversed series (reverse gaps too).
        let zRev = Array(z.reversed())
        let mvRev = Array(measVar.reversed())
        let gapsRev: [Double] = [0] + Array(dts.reversed())
        let back = run(zRev, mvRev, gapsRev)
        let backPos = Array(back.pos.reversed())
        let backVar = Array(back.variance.reversed())

        // Inverse-variance blend of the two passes.
        return (0..<n).map { i in
            let wf = 1 / Swift.max(1e-9, forward.variance[i])
            let wb = 1 / Swift.max(1e-9, backVar[i])
            return (forward.pos[i] * wf + backPos[i] * wb) / (wf + wb)
        }
    }

    // MARK: - Stage 5: render-time simplification (Douglas–Peucker)

    /// Douglas–Peucker line simplification for the *drawn* polyline only: returns
    /// a subset of `track` (same `TrackPoint`s, never new ones) that stays within
    /// `toleranceMeters` of the full path, always keeping the first and last
    /// points. Purely cosmetic — do **not** feed this into distance, marker, or
    /// dive-anchor math, which must use the full cleaned track.
    public static func simplify(_ track: [TrackPoint], toleranceMeters: Double) -> [TrackPoint] {
        let keep = simplifyMask(track.map(\.location), toleranceMeters: toleranceMeters)
        return zip(track, keep).compactMap { $1 ? $0 : nil }
    }

    /// Douglas–Peucker over a bare coordinate list, for callers that already hold
    /// `GeoPoint`s. Same contract as the `TrackPoint` overload.
    public static func simplify(_ points: [GeoPoint], toleranceMeters: Double) -> [GeoPoint] {
        let keep = simplifyMask(points, toleranceMeters: toleranceMeters)
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Coordinate-based Douglas–Peucker core shared by both `simplify` overloads:
    /// returns a per-point keep mask (`true` for retained points) rather than
    /// allocating any points, so each overload can select its own original
    /// elements (preserving `TrackPoint` ids/timestamps). Always keeps the first
    /// and last points; empty / 1- / 2-point inputs, and a non-positive
    /// tolerance, keep everything.
    private static func simplifyMask(_ points: [GeoPoint], toleranceMeters: Double) -> [Bool] {
        guard points.count > 2, toleranceMeters > 0 else {
            return [Bool](repeating: true, count: points.count)
        }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifyRange(points, 0, points.count - 1, toleranceMeters, &keep)
        return keep
    }

    /// Recursive Douglas–Peucker: find the point in `lo..<hi` farthest from the
    /// `lo`→`hi` chord; if it exceeds `tolerance`, keep it and recurse each half.
    private static func simplifyRange(
        _ points: [GeoPoint], _ lo: Int, _ hi: Int, _ tolerance: Double, _ keep: inout [Bool]
    ) {
        guard hi > lo + 1 else { return }
        var farthest = lo
        var maxDist = 0.0
        for i in (lo + 1)..<hi {
            let d = perpendicularDistance(points[i], points[lo], points[hi])
            if d > maxDist { maxDist = d; farthest = i }
        }
        if maxDist > tolerance {
            keep[farthest] = true
            simplifyRange(points, lo, farthest, tolerance, &keep)
            simplifyRange(points, farthest, hi, tolerance, &keep)
        }
    }

    /// Meters per degree of latitude and of longitude at `latitude`, for the
    /// local flat-Earth projections used throughout (Kalman axes, DP distance).
    /// Latitude is a constant; longitude scales by `cos(latitude)` and therefore
    /// collapses to 0 at the poles (±90°) — callers must guard against a zero
    /// `lon` before dividing by it (near a pole, longitude carries no metric
    /// information and a reverse conversion would yield NaN/Inf).
    private static func metersPerDegree(atLatitude latitude: Double) -> (lat: Double, lon: Double) {
        let lat = 111_320.0
        return (lat, lat * Foundation.cos(latitude * .pi / 180))
    }

    /// Perpendicular distance (meters) from `p` to the segment `a`→`b`, worked on
    /// a local flat-Earth meter plane (small scales, small angles → negligible
    /// error). Degenerate segment (a == b) falls back to the point distance.
    private static func perpendicularDistance(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> Double {
        let (metersPerDegLat, metersPerDegLon) = metersPerDegree(atLatitude: a.latitude)
        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * metersPerDegLon
        let by = (b.latitude - a.latitude) * metersPerDegLat
        let px = (p.longitude - a.longitude) * metersPerDegLon
        let py = (p.latitude - a.latitude) * metersPerDegLat
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return sqrt(px * px + py * py) }
        // Cross-product magnitude / segment length = perpendicular distance to the
        // infinite line; for DP the line (not the clamped segment) is the right
        // measure, since both endpoints are always retained.
        let cross = abs(px * dy - py * dx)
        return cross / sqrt(lenSq)
    }
}
