import Foundation

/// A periodic underwater time cue (#178): a subtle "minor" blip at a short cadence
/// and a more prominent "major" cue at a longer one, so a diver gets hands-free,
/// eyes-free awareness of elapsed dive time. Purely time-based awareness — not a
/// dive timer or a safety feature.
public enum DiveTimeCue: Sendable, Equatable {
    case minor
    case major
}

/// The cue (if any) to play at a given whole-second of elapsed dive time.
///
/// A second that is a multiple of both intervals yields `.major` — the major cue
/// takes precedence, so the two never sound at once. Returns `nil` when the second
/// isn't on a boundary or the relevant tier is disabled (interval `0`).
///
/// Pure and side-effect-free so the cadence is unit-testable without a timer.
///
/// - Parameters:
///   - elapsedSeconds: whole seconds since the current dive began (reset each dive).
///   - minorInterval: seconds between minor cues; `0` disables minor cues.
///   - majorInterval: seconds between major cues; `0` disables major cues.
public func diveTimeCue(elapsedSeconds: Int, minorInterval: Int, majorInterval: Int) -> DiveTimeCue? {
    guard elapsedSeconds > 0 else { return nil }
    if majorInterval > 0, elapsedSeconds % majorInterval == 0 { return .major }
    if minorInterval > 0, elapsedSeconds % minorInterval == 0 { return .minor }
    return nil
}
