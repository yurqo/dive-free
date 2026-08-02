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
    ///
    /// - Note: `.rested` says the target has been *reached*, not that the "rested"
    ///   highlight is still showing — that highlight expires; see
    ///   ``isRestedHighlightActive(surfaceInterval:recommended:multiplier:)``.
    public enum RecoveryTier: Sendable, Equatable {
        /// Below `recommended/3` — just surfaced (red).
        case short
        /// `[recommended/3, 2·recommended/3)` — recovering (orange).
        case building
        /// `[2·recommended/3, recommended)` — almost there (yellow).
        case nearly
        /// At or beyond `recommended` — rested (green / ✓ while the highlight lasts).
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

    // MARK: - The expiring "rested" highlight

    /// How long the "rested" highlight (green tint + ✓) stays up once the recommended
    /// interval is reached: `recommended / multiplier`.
    ///
    /// One formula covers both shapes of `recommended`, and self-scales with whatever
    /// multiplier the diver configured — no extra constant to keep in sync:
    /// - Above the floor (`recommended == multiplier × diveDuration`) it collapses to
    ///   **the dive's own duration** — a 40 s dive earns 40 s of green, at any multiplier.
    /// - On the floor (a short dive pinned to the 60 s minimum) it is a proportionate
    ///   share of that floor — 20 s at 3×, 30 s at 2×.
    ///
    /// The highlight has to expire because it means "you're rested **now**"; left up it
    /// would still read green minutes later, when the diver has long since drifted out
    /// of the state it was reporting.
    ///
    /// Degenerate input is clamped rather than propagated, so the dwell is always
    /// finite and never outlives the recovery period itself:
    /// - a multiplier below 1 (including 0 and negatives) or non-finite is treated as
    ///   `1`, capping the dwell at `recommended`;
    /// - a non-positive or non-finite `recommended` (no meaningful target) yields `0`.
    ///
    /// A multiplier of exactly 1 legitimately gives `dwell == recommended` — green for
    /// as long as the rest it required. That is the natural consequence of the rule and
    /// is fine; it still terminates.
    ///
    /// - Parameters:
    ///   - recommended: The recommended surface interval (s) — see ``recommendedInterval(lastDiveDuration:multiplier:minimum:)``.
    ///   - multiplier: The rest-to-dive ratio the target was built from.
    /// - Returns: The highlight's duration (s): `0` when there is no target, otherwise a
    ///   positive value no greater than `recommended`.
    public static func restedHighlightDwell(
        recommended: TimeInterval,
        multiplier: Double
    ) -> TimeInterval {
        guard recommended.isFinite, recommended > 0 else { return 0 }
        // Clamp at 1 so the dwell can never exceed `recommended` (and never divide by
        // zero, go negative, or come back NaN). Real multipliers are clamped to
        // [1.5, 5.0] by `DiveDetectionConfig.sanitized()`, so this only catches
        // corrupt or hand-built values.
        let ratio = (multiplier.isFinite && multiplier > 1) ? multiplier : 1
        return recommended / ratio
    }

    /// Whether the "rested" highlight should be showing right now: the diver has
    /// reached the recommended interval **and** is still inside the
    /// ``restedHighlightDwell(recommended:multiplier:)`` window that follows it.
    ///
    /// Active over `[recommended, recommended + dwell)` — the closing boundary is
    /// exclusive, matching ``tier(surfaceInterval:recommended:)``'s "at the boundary it
    /// steps up" convention. After that the surface timer drops back to its untinted
    /// state, exactly as before the first dive.
    ///
    /// Kept separate from ``tier(surfaceInterval:recommended:)`` on purpose: the tier
    /// bands are a pure function of *how far through the target* the diver is, and stay
    /// a four-step ladder that any caller can switch over exhaustively. Only the
    /// highlight needs the multiplier, so only the highlight takes it.
    public static func isRestedHighlightActive(
        surfaceInterval: TimeInterval,
        recommended: TimeInterval,
        multiplier: Double
    ) -> Bool {
        guard hasReachedRecovery(surfaceInterval: surfaceInterval, recommended: recommended) else { return false }
        return surfaceInterval < recommended + restedHighlightDwell(recommended: recommended, multiplier: multiplier)
    }
}
