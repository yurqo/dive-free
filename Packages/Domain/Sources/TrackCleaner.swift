import Foundation

/// Cleans surface GPS fixes without modifying the stored raw track.
///
/// Rejects invalid/duplicate fixes and isolated jumps, then applies an
/// accuracy-weighted constant-velocity smoother. Isolated outliers are checked
/// against conservative speed and acceleration bounds with uncertainty allowance;
/// sustained faster transit is retained rather than capped to swimming speed.
///
/// Stationary windows require enough history and no resolvable displacement
/// between several parts of the window. An entirely stationary recording collapses
/// to its weighted centre, including endpoints; moving tracks retain their valid
/// endpoints. Slow smoothed windows collapse only when the original fixes also
/// support stationarity, so low speed alone does not erase slow drift.
///
/// Reported horizontal accuracy supplies heuristic weights and tolerances, not
/// calibrated Gaussian variances. GPS alone cannot reliably separate very short
/// movements from correlated noise below its uncertainty. Defaults are tuning
/// parameters, not physiological limits or safety measurements.
///
/// The local metric projection unwraps longitude at the date line. Pure and
/// deterministic, applied on read (see `DiveSession.effectiveTrack`); live Watch
/// distance uses the same cleaner and may revise its estimate as fixes arrive.
public enum TrackCleaner {
    public struct Config: Sendable, Equatable {
        /// Hard-drop fixes whose horizontal accuracy is worse (larger) than this,
        /// in meters — only truly wild fixes. Marginal fixes below this stay and
        /// are down-weighted by the filter. Fixes with no known accuracy are kept.
        public var maxAccuracyMeters: Double
        /// Generous absolute speed gate for isolated jumps. A separate lower
        /// speed/acceleration check handles smaller outliers with GPS uncertainty.
        public var teleportSpeedMetersPerSecond: Double
        /// Assumed measurement accuracy (meters) for fixes with no reported
        /// horizontal accuracy — a middling value so they weigh neither best nor
        /// worst against neighbours that do report accuracy.
        public var defaultAccuracyMeters: Double
        /// Process-noise density (meters per second, per √second) — how much the
        /// diver's velocity is allowed to change between fixes. Higher tracks
        /// turns more crisply but smooths less; lower is smoother but rounds turns.
        public var processNoiseMetersPerSecond: Double
        /// Candidate stationary-run speed (m/s), judged after smoothing.
        /// Raw fixes must also show no resolvable progress before a run collapses.
        public var stationarySpeedMetersPerSecond: Double
        /// Conservative swim/drift bound for isolated outliers, not a ceiling on
        /// sustained transit. GPS uncertainty is added before judging each hop.
        public var swimmingSpeedMetersPerSecond: Double
        /// Isolated velocity changes above this (plus propagated GPS uncertainty)
        /// are rejected only when the neighbouring fixes form a plausible bridge.
        public var accelerationMetersPerSecondSquared: Double
        /// Enough history to distinguish stationary scatter from genuine progress.
        public var stationaryMinimumDuration: TimeInterval

        public init(
            maxAccuracyMeters: Double = 100,
            teleportSpeedMetersPerSecond: Double = 50,
            defaultAccuracyMeters: Double = 15,
            processNoiseMetersPerSecond: Double = 0.5,
            stationarySpeedMetersPerSecond: Double = 0.35,
            swimmingSpeedMetersPerSecond: Double = 4,
            accelerationMetersPerSecondSquared: Double = 2,
            stationaryMinimumDuration: TimeInterval = 10
        ) {
            self.maxAccuracyMeters = maxAccuracyMeters
            self.teleportSpeedMetersPerSecond = teleportSpeedMetersPerSecond
            self.defaultAccuracyMeters = defaultAccuracyMeters
            self.processNoiseMetersPerSecond = processNoiseMetersPerSecond
            self.stationarySpeedMetersPerSecond = stationarySpeedMetersPerSecond
            self.swimmingSpeedMetersPerSecond = swimmingSpeedMetersPerSecond
            self.accelerationMetersPerSecondSquared = accelerationMetersPerSecondSquared
            self.stationaryMinimumDuration = stationaryMinimumDuration
        }

        public static let `default` = Config()
    }

    /// Returns a time-ordered, cleaned copy of `track`.
    public static func clean(_ track: [TrackPoint], config: Config = .default) -> [TrackPoint] {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let gated = uniqueFixes(accuracyGate(ordered, max: config.maxAccuracyMeters))
        let dejumped = rejectTeleports(gated, maxSpeed: config.teleportSpeedMetersPerSecond)
        let plausible = rejectIsolatedMotionOutliers(dejumped, config: config)
        // Do not pin noisy endpoints when the whole recording contains no
        // resolvable movement: that alone can leave metres of false pool distance.
        if isStationary(plausible, config: config) { return collapsed(plausible, config: config) }
        let smoothed = smooth(plausible, config: config)
        return clampStationaryBySpeed(smoothed, evidence: plausible, config: config)
    }

    // MARK: - Stage 1: soft accuracy gate

    /// Drop fixes reported less accurate than `max` meters (only truly wild
    /// fixes); keep fixes with no known accuracy (can't judge them). Marginal
    /// fixes below the cutoff survive and are down-weighted later by the filter.
    private static func accuracyGate(_ track: [TrackPoint], max: Double) -> [TrackPoint] {
        track.filter { point in
            guard point.timestamp.timeIntervalSinceReferenceDate.isFinite,
                  point.location.latitude.isFinite, point.location.longitude.isFinite,
                  (-90...90).contains(point.location.latitude),
                  (-180...180).contains(point.location.longitude) else { return false }
            guard let accuracy = point.location.horizontalAccuracy else { return true }
            return accuracy.isFinite && accuracy >= 0 && accuracy <= max
        }
    }

    /// A batched or duplicated fix must not create a zero-time velocity jump.
    private static func uniqueFixes(_ track: [TrackPoint]) -> [TrackPoint] {
        var result: [TrackPoint] = []
        for point in track {
            if let last = result.last, last.timestamp == point.timestamp {
                if (point.location.horizontalAccuracy ?? .infinity) < (last.location.horizontalAccuracy ?? .infinity) {
                    result[result.count - 1] = point
                }
            } else { result.append(point) }
        }
        return result
    }

    private static func accuracy(_ point: TrackPoint, config: Config) -> Double {
        max(1, point.location.horizontalAccuracy ?? config.defaultAccuracyMeters)
    }

    private static func rejectIsolatedMotionOutliers(_ track: [TrackPoint], config: Config) -> [TrackPoint] {
        guard track.count >= 3 else { return track }
        var keep = [Bool](repeating: true, count: track.count)
        func implausibleHop(_ a: TrackPoint, _ b: TrackPoint) -> Bool {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0 else { return false }
            return a.location.distance(to: b.location) > config.swimmingSpeedMetersPerSecond * dt
                + 2 * hypot(accuracy(a, config: config), accuracy(b, config: config))
        }
        if implausibleHop(track[0], track[1]), !implausibleHop(track[1], track[2]) { keep[0] = false }
        let end = track.count - 1
        if implausibleHop(track[end - 1], track[end]), !implausibleHop(track[end - 2], track[end - 1]) { keep[end] = false }
        for i in 1..<(track.count - 1) {
            let a = track[i - 1], b = track[i], c = track[i + 1]
            let dt0 = b.timestamp.timeIntervalSince(a.timestamp)
            let dt1 = c.timestamp.timeIntervalSince(b.timestamp)
            guard dt0 > 0, dt1 > 0 else { continue }
            let sa = accuracy(a, config: config), sb = accuracy(b, config: config), sc = accuracy(c, config: config)
            let bridgeSpeed = a.location.distance(to: c.location) / (dt0 + dt1)
            let bridgeLimit = config.swimmingSpeedMetersPerSecond + 2 * hypot(sa, sc) / (dt0 + dt1)
            // Sustained fast movement may be real transit, not faulty GPS.
            guard bridgeSpeed <= bridgeLimit else { continue }
            let inLimit = config.swimmingSpeedMetersPerSecond + 2 * hypot(sa, sb) / dt0
            let outLimit = config.swimmingSpeedMetersPerSecond + 2 * hypot(sb, sc) / dt1
            let tooFast = a.location.distance(to: b.location) / dt0 > inLimit
                && b.location.distance(to: c.location) / dt1 > outLimit
            let scale = metersPerDegree(atLatitude: b.location.latitude)
            let vx0 = longitudeOffset(b.location.longitude, from: a.location.longitude) * scale.lon / dt0
            let vy0 = (b.location.latitude - a.location.latitude) * scale.lat / dt0
            let vx1 = longitudeOffset(c.location.longitude, from: b.location.longitude) * scale.lon / dt1
            let vy1 = (c.location.latitude - b.location.latitude) * scale.lat / dt1
            let elapsed = (dt0 + dt1) / 2
            let acceleration = hypot(vx1 - vx0, vy1 - vy0) / elapsed
            let central = sb * (1 / dt0 + 1 / dt1)
            let accelerationError = sqrt(pow(sa / dt0, 2) + pow(central, 2) + pow(sc / dt1, 2)) / elapsed
            let tooAbrupt = acceleration > config.accelerationMetersPerSecondSquared + 2 * accelerationError
            let fraction = dt0 / (dt0 + dt1)
            let expected = GeoPoint(
                latitude: a.location.latitude + fraction * (c.location.latitude - a.location.latitude),
                longitude: normalizedLongitude(a.location.longitude + fraction * longitudeOffset(c.location.longitude, from: a.location.longitude))
            )
            let positionError = sqrt(sb * sb + pow((1 - fraction) * sa, 2) + pow(fraction * sc, 2))
            if (tooFast || tooAbrupt), b.location.distance(to: expected) > 2 * positionError { keep[i] = false }
        }
        return zip(track, keep).compactMap { $1 ? $0 : nil }
    }

    private static func centroid(_ track: [TrackPoint], config: Config) -> (location: GeoPoint, error: Double) {
        let reference = track[0].location.longitude
        var weight = 0.0, lat = 0.0, lon = 0.0
        for point in track {
            let w = 1 / pow(accuracy(point, config: config), 2)
            weight += w
            lat += w * point.location.latitude
            lon += w * longitudeOffset(point.location.longitude, from: reference)
        }
        // Neighbouring GPS errors are correlated. Do not treat a burst of fixes
        // as independent evidence; allow at most one effective fix per five seconds.
        let span = track.last!.timestamp.timeIntervalSince(track[0].timestamp)
        let effectiveCount = min(Double(track.count), max(1, 1 + span / 5))
        let error = sqrt(Double(track.count) / (weight * effectiveCount))
        return (GeoPoint(latitude: lat / weight, longitude: normalizedLongitude(reference + lon / weight)), error)
    }

    private static func isStationary(_ track: [TrackPoint], config: Config) -> Bool {
        guard track.count >= 5,
              track.last!.timestamp.timeIntervalSince(track[0].timestamp) >= config.stationaryMinimumDuration else { return false }
        let centre = centroid(track, config: config).location
        guard track.allSatisfy({ $0.location.distance(to: centre) <= max(2, 2 * accuracy($0, config: config)) }) else { return false }
        // Compare multiple parts of the window, not just its endpoints: a pool
        // lap returning to its start is still real movement. Slow, sustained
        // displacement beyond the uncertainty also stays intact.
        var groups: [[TrackPoint]] = Array(repeating: [], count: 4)
        let start = track[0].timestamp
        let span = track.last!.timestamp.timeIntervalSince(start)
        for point in track {
            let index = min(3, Int(4 * point.timestamp.timeIntervalSince(start) / span))
            groups[index].append(point)
        }
        let centres = groups.filter { !$0.isEmpty }.map { centroid($0, config: config) }
        for i in centres.indices {
            for j in centres.indices where j > i {
                if centres[i].location.distance(to: centres[j].location) > max(1.5, 1.5 * hypot(centres[i].error, centres[j].error)) { return false }
            }
        }
        return true
    }

    private static func collapsed(_ track: [TrackPoint], config: Config) -> [TrackPoint] {
        let centre = centroid(track, config: config).location
        return track.map { point in
            TrackPoint(id: point.id, timestamp: point.timestamp,
                location: GeoPoint(latitude: centre.latitude, longitude: centre.longitude,
                                   horizontalAccuracy: point.location.horizontalAccuracy))
        }
    }

    private static func longitudeOffset(_ longitude: Double, from reference: Double) -> Double {
        var delta = (longitude - reference).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        longitudeOffset(longitude, from: 0)
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

    /// Low smoothed speed selects candidate interior windows; collapse only
    /// when their corresponding unsmoothed fixes support stationarity too.
    private static func clampStationaryBySpeed(_ track: [TrackPoint], evidence: [TrackPoint], config: Config) -> [TrackPoint] {
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
            // A low speed alone cannot distinguish resting from a slow drift.
            // Require no resolvable progress in the original interval as well.
            guard isStationary(Array(evidence[run]), config: config) else { i = j; continue }
            let clustered = collapsed(Array(track[run]), config: config)
            for (offset, k) in run.enumerated() { result[k] = clustered[offset] }
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
            ? kalmanSmooth1D(track.map { longitudeOffset($0.location.longitude, from: lon0) * metersPerDegLon }, dts: dts, measVar: measVar, q: q)
            : []

        let last = track.count - 1
        return track.enumerated().map { index, point in
            // Pin the endpoints to their raw coordinates.
            guard index > 0, index < last else { return point }
            let lat = lat0 + smoothedLat[index] / metersPerDegLat
            // Near a pole, longitude is left at its raw value (never divide by 0).
            let lon = longitudeMetric ? normalizedLongitude(lon0 + smoothedLon[index] / metersPerDegLon) : point.location.longitude
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
