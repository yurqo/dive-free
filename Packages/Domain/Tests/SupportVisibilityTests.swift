import Foundation
import Testing
@testable import Domain

@Suite("Support tip-jar visibility gating")
struct SupportVisibilityTests {
    // MARK: - Purchase UI (both gates must pass)

    @Test("purchase UI hidden by default (both gates off)")
    func hiddenByDefault() {
        let v = SupportVisibility(productsAvailable: false, remoteEnabled: false, hasPastPurchases: false)
        #expect(v.showPurchaseUI == false)
        #expect(v.showPassportSupport == false)
    }

    @Test("products available but remote off keeps the purchase UI hidden")
    func remoteGateBlocks() {
        let v = SupportVisibility(productsAvailable: true, remoteEnabled: false, hasPastPurchases: false)
        #expect(v.showPurchaseUI == false)
    }

    @Test("remote on but products unavailable keeps the purchase UI hidden")
    func productGateBlocks() {
        let v = SupportVisibility(productsAvailable: false, remoteEnabled: true, hasPastPurchases: false)
        #expect(v.showPurchaseUI == false)
    }

    @Test("purchase UI shown only when BOTH gates pass")
    func bothGatesReveal() {
        let v = SupportVisibility(productsAvailable: true, remoteEnabled: true, hasPastPurchases: false)
        #expect(v.showPurchaseUI == true)
        #expect(v.showPassportSupport == true)
    }

    // MARK: - Passport (past purchases keep the badge)

    @Test("a past supporter keeps Passport badges even when the feature is disabled")
    func pastPurchaseKeepsBadge() {
        let v = SupportVisibility(productsAvailable: false, remoteEnabled: false, hasPastPurchases: true)
        #expect(v.showPurchaseUI == false)       // can't buy again while dark
        #expect(v.showPassportSupport == true)   // ...but the badge stays
    }

    // MARK: - Counters

    @Test("coffee count increments and clamps a corrupt negative")
    func coffeeCounter() {
        #expect(SupportCounters.incrementedCoffeeCount(0) == 1)
        #expect(SupportCounters.incrementedCoffeeCount(4) == 5)
        #expect(SupportCounters.incrementedCoffeeCount(-3) == 1)
    }

    @Test("supporter months = count of monthly transactions, ignoring other ids")
    func supporterMonthsCountsBilledPeriods() {
        let monthly = "monthly"
        // One period paid → 1 month; coffee / other transactions don't count.
        #expect(SupportCounters.supporterMonths(
            from: [monthly, "coffee", "coffee"],
            monthlyProductID: monthly,
            highWaterMark: 0
        ) == 1)
        // Three billed periods → 3 months.
        #expect(SupportCounters.supporterMonths(
            from: [monthly, monthly, monthly],
            monthlyProductID: monthly,
            highWaterMark: 0
        ) == 3)
    }

    @Test("subscribe → lapse → resubscribe counts only the two paid months, not the gap")
    func supporterMonthsIgnoresLapseGap() {
        // A supporter who paid one month, lapsed for several billing cycles, then
        // resubscribed for one more has exactly TWO transactions — regardless of how
        // long the gap was. Deriving from the (retained) original purchase date would
        // instead count every gap month; counting transactions does not.
        let monthly = "monthly"
        #expect(SupportCounters.supporterMonths(
            from: [monthly, monthly],
            monthlyProductID: monthly,
            highWaterMark: 0
        ) == 2)
    }

    @Test("supporter months stay monotonic with the high-water mark")
    func supporterMonthsMonotonic() {
        let monthly = "monthly"
        // A fully-lapsed supporter (no transactions returned) keeps the stored badge.
        #expect(SupportCounters.supporterMonths(
            from: [],
            monthlyProductID: monthly,
            highWaterMark: 5
        ) == 5)
        // A fresh, higher count wins.
        #expect(SupportCounters.supporterMonths(
            from: [monthly, monthly, monthly],
            monthlyProductID: monthly,
            highWaterMark: 2
        ) == 3)
    }

    // MARK: - Coffee transaction dedupe

    @Test("a coffee transaction counts once per unique id; redelivery is a no-op")
    func coffeeDedupe() {
        let first = SupportCounters.recordCoffeeTransaction("tx-1", seen: [])
        #expect(first.isNew == true)
        #expect(first.seen == ["tx-1"])

        // Same id again (listener redelivery / cross-device) — not counted again.
        let repeated = SupportCounters.recordCoffeeTransaction("tx-1", seen: first.seen)
        #expect(repeated.isNew == false)
        #expect(repeated.seen == ["tx-1"])

        // A different id counts.
        let second = SupportCounters.recordCoffeeTransaction("tx-2", seen: first.seen)
        #expect(second.isNew == true)
        #expect(second.seen == ["tx-1", "tx-2"])
    }

    @Test("the seen set is bounded, trimming the oldest ids past the limit")
    func coffeeDedupeBounded() {
        let existing = (0..<5).map { "tx-\($0)" }
        let result = SupportCounters.recordCoffeeTransaction("tx-new", seen: existing, limit: 5)
        #expect(result.isNew == true)
        #expect(result.seen.count == 5)
        #expect(result.seen.first == "tx-1")   // "tx-0" trimmed
        #expect(result.seen.last == "tx-new")
    }
}
