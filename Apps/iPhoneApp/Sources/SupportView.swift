import SwiftUI
import StoreKit
import Domain

/// The "Support DiveFree" tip jar (reached from Settings, and only shown when the
/// gates pass — see `SupportStore.visibility`). A warm, short pitch plus the two
/// optional ways to chip in: a repeatable "coffee" consumable and a monthly
/// subscription that lights up the Passport supporter badge. Everything no-ops
/// gracefully if products vanish.
struct SupportView: View {
    @Environment(SupportStore.self) private var store
    @State private var manageSubscriptions = false

    private var coffee: Product? { store.products.first { $0.id == SupportProduct.coffee } }
    private var monthly: Product? { store.products.first { $0.id == SupportProduct.monthly } }

    var body: some View {
        Form {
            Section {
                Text("DiveFree is free, and your dives stay yours. If it's earned a spot on your wrist, a small tip keeps the servers running and the developer caffeinated. Entirely optional — thank you either way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // The gates passed (or this screen wouldn't be reachable), but the product
            // fetch failed / hasn't landed. Offer a retry rather than a blank screen.
            if store.products.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Can't reach the App Store right now.")
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await store.loadProducts() }
                        }
                    }
                    .font(.subheadline)
                }
            }

            if let coffee {
                Section {
                    purchaseRow(
                        title: "Buy me a coffee",
                        subtitle: "A one-off thank-you. Buy as many as you like.",
                        systemImage: "cup.and.saucer.fill",
                        buttonLabel: coffee.displayPrice,
                        product: coffee
                    )
                } header: {
                    Text("One-off")
                } footer: {
                    if store.coffeeCount > 0 {
                        Text("You've bought \(store.coffeeCount) coffee\(store.coffeeCount == 1 ? "" : "s") — cheers! ☕️")
                    }
                }
            }

            if let monthly {
                Section {
                    purchaseRow(
                        title: "Monthly snack",
                        subtitle: "A little every month. Unlocks the Supporter badge in your Passport.",
                        systemImage: "heart.fill",
                        buttonLabel: store.isSupporter ? String(localized: "Active") : "\(monthly.displayPrice) / mo",
                        product: monthly,
                        disabled: store.isSupporter
                    )
                    if store.isSupporter {
                        Button("Manage subscription") { manageSubscriptions = true }
                    }
                } header: {
                    Text("Monthly")
                } footer: {
                    subscriptionFinePrint
                }
            }

            Section {
                Button("Restore Purchases") {
                    Task { await store.restore() }
                }
                if let restoreMessage = store.restoreMessage {
                    Text(restoreMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Restores your Supporter subscription on this device. Coffee tips are one-off and aren't restored.")
            }
        }
        .navigationTitle("Support DiveFree")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
    }

    @ViewBuilder
    private func purchaseRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        buttonLabel: String,
        product: Product,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.purchasingProductID == product.id {
                ProgressView()
            } else {
                // The price (or "Active") is the button label — always visible.
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    Text(buttonLabel)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(disabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var subscriptionFinePrint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monthly snack is an auto-renewing subscription. It renews each month at the price shown until you cancel. Payment is charged to your Apple Account at confirmation, and again each period unless you cancel at least 24 hours before it ends. Manage or cancel anytime in Settings.")
            HStack(spacing: 16) {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy", destination: URL(string: "https://divefree.software-engineer.ing/privacy")!)
            }
        }
        .font(.caption)
    }
}
