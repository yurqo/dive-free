import Foundation
import Observation
import StoreKit
import os
import Domain

/// Product identifiers for the optional "Support DiveFree" tip jar.
///
/// IMPORTANT: App Store Connect MUST use these EXACT ids — the app fetches them by
/// string, and the whole feature self-activates only when `Product.products(for:)`
/// returns them (see `SupportStore.loadProducts`). Changing an id here without
/// matching ASC (or vice-versa) silently keeps the feature dark.
enum SupportProduct {
    /// "Buy me a coffee" — a **consumable** tip, repeatable (buy any number). Grants
    /// no StoreKit entitlement, so its tally is counted locally.
    static let coffee = "org.yurko.divefree.support.coffee"
    /// "Monthly snack" — an **auto-renewable subscription** (group "Supporter").
    /// Drives the active Supporter badge.
    static let monthly = "org.yurko.divefree.support.monthly"

    static let all = [coffee, monthly]
}

/// Owns the StoreKit 2 side of the tip jar: product fetch, purchase flows,
/// transaction/renewal listening, subscription entitlement, and the local
/// achievement counters. `@MainActor @Observable` so SwiftUI tracks it directly.
///
/// Gating: the UI reads `visibility`, which ANDs the cached product availability
/// with the cached remote kill-switch (`AppConfig.supportEnabled`), OR-ed with
/// "already has purchases" for the Passport badge. Both cached values default to
/// hidden and are only ever flipped ON by a successful signal — a transient
/// offline launch keeps the last-seen value rather than flapping the UI, and a
/// fetch failure never reveals the feature.
///
/// No SwiftData schema changes: coffee count and supporter months live in
/// `UserDefaults`.
@MainActor
@Observable
final class SupportStore {
    /// Loaded products (empty until fetched / on failure), sorted for a stable UI.
    private(set) var products: [Product] = []
    /// Whether the auto-renewable Supporter subscription is currently active.
    private(set) var isSupporter = false
    /// Product id of an in-flight purchase, for a per-row spinner (nil when idle).
    private(set) var purchasingProductID: String?
    /// Brief, user-facing message from the last `restore()` (nil when none). Cleared
    /// on the next action or auto-cleared after a few seconds.
    private(set) var restoreMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remoteConfig: AppConfigProviding
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var restoreClearTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "org.yurko.divefree", category: "Support")

    enum Key {
        static let coffeeCount = "support.coffeeCount"
        static let supporterMonths = "support.supporterMonths"
        static let productsAvailable = "support.productsAvailable"
        static let remoteEnabled = "support.remoteEnabled"
        static let seenCoffeeTransactions = "support.seenCoffeeTransactions"
    }

    // MARK: - Counters (local; consumables aren't StoreKit-derivable cheaply)
    //
    // These are OBSERVED STORED properties (not computed over UserDefaults) so that
    // SwiftUI observation fires on every change — a UserDefaults-backed computed
    // getter is invisible to `@Observable`, so gate flips and counter bumps would
    // never invalidate the views that read them. Seeded from UserDefaults in `init`
    // (which doesn't trigger `didSet`) and written through on every mutation.

    /// Coffees bought (each verified consumable purchase bumps this).
    private(set) var coffeeCount: Int {
        didSet { defaults.set(coffeeCount, forKey: Key.coffeeCount) }
    }
    /// Highest month count ever seen while subscribed (kept so a lapsed supporter
    /// retains the achievement).
    private(set) var supporterMonths: Int {
        didSet { defaults.set(supporterMonths, forKey: Key.supporterMonths) }
    }

    // MARK: - Visibility gates (cached, default hidden)

    /// Last-seen product availability from a *successful* fetch. Default hidden; a
    /// failed fetch never sets this true (so a fetch failure can't reveal the UI),
    /// and a failure leaves it untouched (so a transient offline launch keeps the
    /// last-seen value instead of flapping).
    private var productsAvailable: Bool {
        didSet { defaults.set(productsAvailable, forKey: Key.productsAvailable) }
    }
    /// Last-seen remote kill-switch. Default off; failures keep the cached value.
    private var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Key.remoteEnabled) }
    }

    init(defaults: UserDefaults = .standard, remoteConfig: AppConfigProviding = WorkerAppConfig()) {
        self.defaults = defaults
        self.remoteConfig = remoteConfig
        // Seed observed state from the cache. Assignment inside `init` does NOT fire
        // `didSet`, so this read-back doesn't re-write what we just read.
        self.coffeeCount = defaults.integer(forKey: Key.coffeeCount)
        self.supporterMonths = defaults.integer(forKey: Key.supporterMonths)
        self.productsAvailable = defaults.bool(forKey: Key.productsAvailable)
        self.remoteEnabled = defaults.bool(forKey: Key.remoteEnabled)
    }

    /// Whether the diver has any recorded purchase — keeps their Passport badge
    /// even if the feature is later switched off.
    private var hasPastPurchases: Bool {
        coffeeCount > 0 || supporterMonths > 0 || isSupporter
    }

    /// The pure UI decision (see `Domain.SupportVisibility`).
    var visibility: SupportVisibility {
        SupportVisibility(
            productsAvailable: productsAvailable,
            remoteEnabled: remoteEnabled,
            hasPastPurchases: hasPastPurchases
        )
    }

    // MARK: - Lifecycle

    /// Runs at launch (background priority — see the caller). Fetches the remote
    /// flag, starts the transaction listener, loads products, reconciles the
    /// subscription entitlement, and recounts the supporter-months tally. Every step
    /// is best-effort and degrades to the cached state; nothing here can block or
    /// crash launch.
    func start() async {
        listenForTransactions()
        await refreshRemoteFlag()
        await loadProducts()
        await refreshEntitlements()
        await recountSupporterMonths()
    }

    /// Refreshes the remote kill-switch, caching a successful result. A failure
    /// leaves the cached value in place (default off).
    private func refreshRemoteFlag() async {
        guard let config = await remoteConfig.fetch() else { return }
        remoteEnabled = config.supportEnabled
    }

    /// Fetches the configured products and updates the cached availability.
    ///
    /// Sets availability = true only when the fetch succeeds AND returns BOTH ids
    /// (self-activation once ASC goes live); = false when it succeeds but the ids
    /// are missing (feature genuinely withdrawn). On a THROWN failure it leaves the
    /// cache untouched — a transient offline blip keeps the last-seen value rather
    /// than hiding the UI from someone who legitimately had it.
    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: SupportProduct.all)
            products = fetched.sorted { $0.id < $1.id }
            let available = Set(fetched.map(\.id)).isSuperset(of: SupportProduct.all)
            productsAvailable = available
        } catch {
            log.error("Product fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Purchase

    /// Runs the StoreKit 2 purchase flow for `product`, verifying the transaction,
    /// applying its perk, and finishing it. Cancellations/pending are no-ops.
    func purchase(_ product: Product) async {
        // Reentrancy guard: the OTHER row's button stays tappable while one purchase
        // is in flight; a `defer`-based reset would corrupt the spinner state if a
        // second purchase resolved first. Bail instead of overlapping.
        guard purchasingProductID == nil else { return }
        setRestoreMessage(nil)
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard let transaction = verified(verification) else {
                    log.error("Purchase returned an UNVERIFIED transaction; ignoring.")
                    return
                }
                await applyPurchase(transaction)
                await transaction.finish()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            log.error("Purchase failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Grants the perk for a freshly-purchased, verified transaction. Coffee counts
    /// through the shared dedupe path (so an id already applied by the listener isn't
    /// double-counted, and vice versa); a subscription purchase re-reconciles the
    /// entitlement and recounts the months tally.
    private func applyPurchase(_ transaction: Transaction) async {
        if transaction.productID == SupportProduct.coffee {
            countCoffeeIfNew(transaction.id)
        } else if transaction.productID == SupportProduct.monthly {
            await refreshEntitlements()
            await recountSupporterMonths()
        }
    }

    /// Counts a consumable coffee transaction exactly once, deduped by a bounded,
    /// persisted set of seen transaction ids. Both the interactive `purchase()` path
    /// and the out-of-band `Transaction.updates` listener route through here, so an
    /// id applied by one can't be re-applied by the other (redelivery, cross-device,
    /// or a crash between charge and apply). All on the main actor — the
    /// read-check-write is atomic (no `await` inside), so no double-count race.
    private func countCoffeeIfNew(_ transactionID: UInt64) {
        let seen = defaults.stringArray(forKey: Key.seenCoffeeTransactions) ?? []
        let result = SupportCounters.recordCoffeeTransaction(String(transactionID), seen: seen)
        guard result.isNew else { return }
        defaults.set(result.seen, forKey: Key.seenCoffeeTransactions)
        coffeeCount = SupportCounters.incrementedCoffeeCount(coffeeCount)
    }

    /// Restores purchases by syncing the App Store account. Subscription state and
    /// the months tally are re-derived afterwards. (Consumable coffee counts are
    /// local and can't be restored — expected for a tip.) A sync failure surfaces a
    /// brief inline message for the view.
    func restore() async {
        setRestoreMessage(nil)
        do {
            try await AppStore.sync()
        } catch {
            log.error("Restore (AppStore.sync) failed: \(String(describing: error), privacy: .public)")
            setRestoreMessage(String(localized: "Couldn't reach the App Store to restore. Please try again."))
            return
        }
        await refreshEntitlements()
        await recountSupporterMonths()
    }

    /// Sets (or clears) the transient restore message and schedules an auto-clear a
    /// few seconds out. Passing `nil` clears any pending timer.
    private func setRestoreMessage(_ message: String?) {
        restoreMessage = message
        restoreClearTask?.cancel()
        guard message != nil else { return }
        restoreClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.restoreMessage = nil
        }
    }

    // MARK: - Entitlements & renewals

    /// Recomputes `isSupporter` from current entitlements (an active, un-revoked
    /// monthly subscription). The months TALLY is handled separately by
    /// `recountSupporterMonths` — see FIX 1: deriving it from a single entitlement's
    /// `originalPurchaseDate` overcounts across a subscribe → lapse → resubscribe.
    func refreshEntitlements() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = verified(entitlement) else { continue }
            guard transaction.productID == SupportProduct.monthly, transaction.revocationDate == nil else { continue }
            active = true
        }
        isSupporter = active
    }

    /// Recounts the supporter-months high-water mark = the number of monthly
    /// transactions across the full StoreKit history (one per billed period). Walks
    /// `Transaction.all`, verifying each and hopping to the main actor to collect its
    /// product id, then defers the monotonic tally to `SupportCounters`. Counting
    /// transactions — rather than deriving from the retained `originalPurchaseDate` —
    /// is what excludes the gap months of a lapsed-then-resubscribed supporter.
    func recountSupporterMonths() async {
        var productIDs: [String] = []
        for await result in Transaction.all {
            guard let transaction = verified(result) else { continue }
            productIDs.append(transaction.productID)
        }
        let updated = SupportCounters.supporterMonths(
            from: productIDs,
            monthlyProductID: SupportProduct.monthly,
            highWaterMark: supporterMonths
        )
        if updated != supporterMonths { supporterMonths = updated }
    }

    /// Long-lived listener for transactions that arrive OUTSIDE `purchase()` —
    /// renewals, refunds/revocations, Ask-to-Buy approvals, and purchases made on
    /// another device. It counts any consumable coffee (deduped, so redelivery can't
    /// double-count), finishes each transaction, and re-reconciles the subscription
    /// state and months tally.
    private func listenForTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if let transaction = await self.verified(update) {
                    if transaction.productID == SupportProduct.coffee {
                        await self.countCoffeeIfNew(transaction.id)
                    }
                    await transaction.finish()
                }
                await self.refreshEntitlements()
                await self.recountSupporterMonths()
            }
        }
    }

    /// Unwraps a `VerificationResult`, returning the payload only when StoreKit
    /// verified its signature (nil otherwise — we never grant on an unverified one).
    private func verified<T>(_ result: VerificationResult<T>) -> T? {
        guard case .verified(let value) = result else { return nil }
        return value
    }
}
