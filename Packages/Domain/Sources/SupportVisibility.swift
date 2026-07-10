import Foundation

/// Pure visibility decision for the optional "Support DiveFree" tip jar, kept in
/// dependency-free `Domain` (no StoreKit) so the gating can be reasoned about and
/// unit-tested in isolation. The app feeds it the two runtime gates plus whether
/// the diver already has recorded purchases.
///
/// The feature ships **dark**: it self-activates only when BOTH gates pass —
/// (1) the App Store Connect products are available (`Product.products(for:)`
/// returns the configured ids) and (2) the remote kill-switch (`/app-config`)
/// says `supportEnabled: true`. Once a diver has bought anything, their Passport
/// badges stay visible even if the feature is later switched off — a past
/// supporter keeps their badge.
public struct SupportVisibility: Equatable, Sendable {
    /// Whether the purchase UI (Settings "Support DiveFree" section + screen, the
    /// User Guide chapter) should be shown. Both gates must pass.
    public let showPurchaseUI: Bool

    /// Whether the Passport supporter badge + Coffee/Supporter achievements should
    /// be shown. Shown when the gates pass OR the diver already has purchases, so a
    /// past supporter never loses their badge.
    public let showPassportSupport: Bool

    public init(productsAvailable: Bool, remoteEnabled: Bool, hasPastPurchases: Bool) {
        let gatesPass = productsAvailable && remoteEnabled
        self.showPurchaseUI = gatesPass
        self.showPassportSupport = gatesPass || hasPastPurchases
    }
}

/// Pure counters for the tip-jar achievements — no StoreKit, so they're testable
/// in `Domain`. Consumables grant no StoreKit entitlement, so the coffee tally is
/// kept locally; supporter months are counted from the subscription's transaction
/// history (one transaction per billed period) rather than an accounting ledger.
public enum SupportCounters {
    /// Next coffee count after a verified consumable purchase. Clamps a corrupt
    /// negative stored value to 0 first.
    public static func incrementedCoffeeCount(_ current: Int) -> Int {
        max(0, current) + 1
    }

    /// Whole supporter months = the number of monthly-subscription transactions in
    /// the account's StoreKit history, kept monotonic with the stored high-water
    /// mark so a lapsed supporter never loses the achievement.
    ///
    /// StoreKit records ONE transaction per billed period. Counting them counts only
    /// the months actually paid — unlike deriving months from the subscription's
    /// `originalPurchaseDate`, which StoreKit keeps across a resubscription in the
    /// same group and so would also count the GAP months of a
    /// subscribe → lapse → resubscribe supporter.
    ///
    /// - Parameters:
    ///   - productIDs: the product id of every verified transaction in the history
    ///     (coffee / other ids are ignored).
    ///   - monthlyProductID: the monthly-subscription product id to tally.
    ///   - highWaterMark: the previously stored month count (never decreased).
    public static func supporterMonths(
        from productIDs: [String],
        monthlyProductID: String,
        highWaterMark: Int
    ) -> Int {
        let billed = productIDs.filter { $0 == monthlyProductID }.count
        return max(highWaterMark, billed)
    }

    /// Records a consumable coffee transaction id in the bounded "seen" set,
    /// reporting whether it was NEWLY seen — so redelivery via `Transaction.updates`,
    /// a cross-device purchase, or a late Ask-to-Buy approval each bump the tally
    /// exactly once.
    ///
    /// Bounded to the most recent `limit` ids (oldest trimmed, same pattern as the
    /// deletion tombstones): only recent re-deliveries are a real double-count risk,
    /// so the set needn't grow without end.
    ///
    /// - Returns: `isNew` — whether the tally should be incremented for this id — and
    ///   the updated (trimmed) seen set to persist.
    public static func recordCoffeeTransaction(
        _ id: String,
        seen: [String],
        limit: Int = 200
    ) -> (isNew: Bool, seen: [String]) {
        guard !seen.contains(id) else { return (false, seen) }
        var updated = seen
        updated.append(id)
        if updated.count > limit { updated.removeFirst(updated.count - limit) }
        return (true, updated)
    }
}
