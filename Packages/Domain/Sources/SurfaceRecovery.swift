import Foundation

/// Pure, dependency-free helpers for the **surface-recovery indicator**: how long a
/// freediver should rest at the surface between dives, and how that rest maps to a
/// four-step UI tint + a one-shot "you're rested" haptic.
///
/// The rule of thumb this encodes: the recommended surface interval is
/// `multiplier × the last dive's duration` (commonly 2×–3×), with a floor so very
/// short dives still get a sensible minimum rest. The colour tiers scale with that
/// recommended target, so the indicator behaves the same for any multiplier.
///
/// > Important: This is a convenience **hint**, not safety advice. DiveFree is a
/// > session logger, not a dive computer; real surface-interval planning depends on
/// > the diver, the discipline, and conditions. Never treat these tiers as a
/// > guarantee that a diver has fully recovered.
///
/// Everything here is deterministic and `Sendable` — no clock, no I/O — so it is
/// fully unit-testable and safe to call from any isolation domain.
public enum SurfaceRecovery {
    /// The recommended minimum surface interval (s): `max(minimum, lastDiveDuration × multiplier)`.
    ///
    /// - Parameters:
    ///   - lastDiveDuration: Duration (s) of the dive just completed.
    ///   - multiplier: Rest-to-dive ratio (commonly 2–3).
    ///   - minimum: Floor (s) applied so very short dives still get a sensible rest.
    /// - Returns: The larger of the floor and `lastDiveDuration × multiplier`.
    public static func recommendedInterval(
        lastDiveDuration: TimeInterval,
        multiplier: Double,
        minimum: TimeInterval
    ) -> TimeInterval {
        max(minimum, lastDiveDuration * multiplier)
    }

    /// Coarse recovery state for the surface timer's colour, from just-surfaced to
    /// fully rested. Bands scale with the recommended target so the same four steps
    /// apply regardless of the chosen multiplier.
    public enum RecoveryTier: Sendable, Equatable {
        /// Below `recommended/3` — just surfaced (red).
        case short
        /// `[recommended/3, 2·recommended/3)` — recovering (orange).
        case building
        /// `[2·recommended/3, recommended)` — almost there (yellow).
        case nearly
        /// At or beyond `recommended` — rested (green / ✓).
        case rested
    }

    /// Maps the elapsed surface interval to a ``RecoveryTier`` by comparing it against
    /// thirds of the recommended target `t`:
    /// `< t/3` → `.short`, `< 2t/3` → `.building`, `< t` → `.nearly`, `>= t` → `.rested`.
    ///
    /// A non-positive `recommended` (no meaningful target — e.g. no prior dive) is
    /// treated as already rested, so the indicator never sits stuck on red.
    public static func tier(
        surfaceInterval: TimeInterval,
        recommended: TimeInterval
    ) -> RecoveryTier {
        guard recommended > 0 else { return .rested }
        if surfaceInterval >= recommended { return .rested }
        if surfaceInterval >= recommended * 2 / 3 { return .nearly }
        if surfaceInterval >= recommended / 3 { return .building }
        return .short
    }

    /// Whether the diver has just reached (or passed) the recommended interval — the
    /// crossing that arms the one-shot "rested" haptic. False for a non-positive
    /// `recommended` (no target to reach).
    public static func hasReachedRecovery(
        surfaceInterval: TimeInterval,
        recommended: TimeInterval
    ) -> Bool {
        recommended > 0 && surfaceInterval >= recommended
    }
}
