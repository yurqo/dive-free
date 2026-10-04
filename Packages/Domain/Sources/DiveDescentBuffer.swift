import Foundation

/// Retains the shallow beginning of a descent before automatic detection opens.
/// Surface waits, stale readings and abandoned descents never extend a later dive.
public struct DiveDescentBuffer: Sendable {
    public private(set) var samples: [DepthSample] = []
    private var lastIncrease: Date?

    public init() {}

    public mutating func reset() {
        samples = []
        lastIncrease = nil
    }

    public mutating func append(_ sample: DepthSample, dwell: TimeInterval) {
        let previous = samples.last
        let gap = previous.map { sample.timestamp.timeIntervalSince($0.timestamp) } ?? 0
        if sample.depthMeters <= DiveDetectionConfig.surfaceExitDepthMeters
            || gap > max(3, dwell)
            || (previous.map { sample.depthMeters < $0.depthMeters - 0.05 } ?? false) {
            samples = [sample]
            lastIncrease = sample.timestamp
            return
        }
        if let previous, sample.depthMeters > previous.depthMeters + 0.01 {
            lastIncrease = sample.timestamp
        } else if let lastIncrease, sample.timestamp.timeIntervalSince(lastIncrease) >= max(1, dwell) {
            samples = [sample]
            self.lastIncrease = sample.timestamp
            return
        }
        samples.append(sample)
        if lastIncrease == nil { lastIncrease = sample.timestamp }
    }
}
