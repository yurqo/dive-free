import Foundation

/// Cleans a raw GPS surface track: drops low-accuracy fixes and physically-
/// impossible "teleport" spikes, then lightly smooths the survivors.
///
/// Pure and deterministic, so it is fully unit-testable. Applied **on read** —
/// the raw track is always retained (see `DiveSession.effectiveTrack`); live
/// in-session indicators keep using the raw track.
public enum TrackCleaner {
    public struct Config: Sendable, Equatable {
        /// Drop fixes whose horizontal accuracy is worse (larger) than this, in
        /// meters. Fixes with no known accuracy (interpolated/legacy) are kept.
        public var maxAccuracyMeters: Double
        /// Flag a fix as a spike when the implied speed to a neighbour exceeds
        /// this (m/s) — faster than a human swims/drifts at the surface.
        /// ~3 m/s ≈ 10.8 km/h.
        public var maxSpeedMetersPerSecond: Double
        /// Centered moving-average window (in points) for smoothing; 1 disables
        /// it. Small/odd so it doesn't soften genuine movement.
        public var smoothingWindow: Int

        public init(
            maxAccuracyMeters: Double = 50,
            maxSpeedMetersPerSecond: Double = 3,
            smoothingWindow: Int = 3
        ) {
            self.maxAccuracyMeters = maxAccuracyMeters
            self.maxSpeedMetersPerSecond = maxSpeedMetersPerSecond
            self.smoothingWindow = smoothingWindow
        }

        public static let `default` = Config()
    }

    /// Returns a time-ordered, cleaned copy of `track`.
    public static func clean(_ track: [TrackPoint], config: Config = .default) -> [TrackPoint] {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let gated = accuracyGate(ordered, max: config.maxAccuracyMeters)
        let dejumped = rejectOutliers(gated, maxSpeed: config.maxSpeedMetersPerSecond)
        return smooth(dejumped, window: config.smoothingWindow)
    }

    /// Drop fixes reported less accurate than `max` meters; keep fixes with no
    /// known accuracy (can't judge them).
    private static func accuracyGate(_ track: [TrackPoint], max: Double) -> [TrackPoint] {
        track.filter { point in
            guard let accuracy = point.location.horizontalAccuracy else { return true }
            return accuracy <= max
        }
    }

    /// Drop isolated spikes: an interior fix that jumps impossibly fast both *in*
    /// (from the previous fix) and *out* (to the next), or an endpoint that jumps
    /// to a neighbour which is itself consistent with the rest of the track (so the
    /// endpoint, not the neighbour, is the outlier). Uses original adjacency, which
    /// is enough for the lone-spike case this targets.
    private static func rejectOutliers(_ track: [TrackPoint], maxSpeed: Double) -> [TrackPoint] {
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

    /// Centered moving average over `window` points (shrinking at the ends).
    /// Smooths position only; timestamps, ids, and accuracy are preserved. The
    /// first and last points are kept fixed so the track's extent — and the dive
    /// submersion/surfacing positions placed along it — aren't pulled inward.
    private static func smooth(_ track: [TrackPoint], window: Int) -> [TrackPoint] {
        guard window > 1, track.count > 2 else { return track }
        let half = window / 2
        let last = track.count - 1
        return track.enumerated().map { index, point in
            guard index > 0, index < last else { return point }
            let lo = Swift.max(0, index - half)
            let hi = Swift.min(last, index + half)
            let slice = track[lo...hi]
            let lat = slice.reduce(0.0) { $0 + $1.location.latitude } / Double(slice.count)
            let lon = slice.reduce(0.0) { $0 + $1.location.longitude } / Double(slice.count)
            return TrackPoint(
                id: point.id,
                timestamp: point.timestamp,
                location: GeoPoint(latitude: lat, longitude: lon, horizontalAccuracy: point.location.horizontalAccuracy)
            )
        }
    }
}
