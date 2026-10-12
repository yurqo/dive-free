import Foundation

public extension Dive {
    /// Display-only surface boundaries, including for older clipped profiles.
    /// Raw readings stay unchanged for persistence, statistics and exports.
    var chartDepthSamples: [DepthSample] {
        var points = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = points.first, let last = points.last else { return [] }
        let start = min(startTime, first.timestamp)
        let end = max(endTime, last.timestamp)
        if first.depthMeters != 0 || first.timestamp > start {
            points.insert(DepthSample(timestamp: start, depthMeters: 0), at: 0)
        }
        if last.depthMeters != 0 || last.timestamp < end {
            points.append(DepthSample(timestamp: end, depthMeters: 0))
        }
        return points
    }

    var chartDepthProfile: [DepthProfilePoint] {
        chartDepthSamples.enumerated().map { index, sample in
            DepthProfilePoint(id: index, secondsFromStart: sample.timestamp.timeIntervalSince(startTime),
                              depthMeters: sample.depthMeters)
        }
    }
}

public extension DiveSession {
    /// One continuous profile: every interval between dives remains at zero,
    /// as do the surface time before the first dive and after the last one.
    var chartDepthSamples: [DepthSample] {
        let points = dives.sorted { $0.startTime < $1.startTime }.flatMap(\.chartDepthSamples)
        guard let first = points.first, let last = points.last else { return [] }
        let start = min(startTime, first.timestamp)
        let end = max(endTime ?? last.timestamp, last.timestamp)
        return [DepthSample(timestamp: start, depthMeters: 0)] + points
            + [DepthSample(timestamp: end, depthMeters: 0)]
    }
}
