import SwiftUI
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PaywallView

struct PaywallView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(PurchaseManager.self) private var store

    @State private var selectedProductID: String? = nil

    /// `true` if the user has an active recurring subscription (monthly/yearly) —
    /// NOT Lifetime, which has nothing to "change". This is what switches the screen
    /// from "selling the offer" to "managing your plan".
    private var hasActiveSubscription: Bool {
        store.activeSubscriptionProductID != nil
    }

    /// Lifetime bought IN ADDITION to a still-active subscription — StoreKit never
    /// automatically cancels a subscription from another group/type when a
    /// non-consumable is bought, so nothing does it in the user's place.
    private var hasRedundantSubscription: Bool {
        store.accessLevel == .lifetime && hasActiveSubscription
    }

    var body: some View {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    if hasRedundantSubscription { redundantSubscriptionWarning }
                    featureListSection
                    if store.accessLevel == .lifetime {
                        lifetimeConfirmationSection
                    } else {
                        productPickerSection
                        actionSection
                    }
                    legalFooter
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .paneChrome("Finance Pro", cancelLabel: "Fermer", onCancel: { dismiss() })
        .onAppear { selectDefaultProduct() }
        .onChange(of: store.products) { _, _ in selectDefaultProduct() }
    }

    /// The default selection: the already-active plan (for "manage your plan" rather
    /// than re-selling what's already owned), otherwise yearly (the best value).
    private func selectDefaultProduct() {
        guard selectedProductID == nil else { return }
        selectedProductID = store.activeSubscriptionProductID
            ?? store.yearlyProduct?.id
            ?? store.products.first?.id
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color(hex: "FFD700"))
                .padding(.top, 8)

            Text(headerTitle)
                .font(.title2)
                .fontWeight(.bold)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var headerTitle: String {
        switch store.accessLevel {
        case .free:     return "Passez à Finance Pro"
        case .pro:      return "Votre abonnement Finance Pro"
        case .lifetime: return "Vous avez l'accès à vie"
        }
    }

    private var headerSubtitle: String {
        switch store.accessLevel {
        case .free:
            return "Débloquez toutes les fonctionnalités et gérez vos finances sans aucune limite."
        case .pro:
            return "Changez de formule à tout moment — mensuel, annuel, ou passez à l'accès à vie."
        case .lifetime:
            return "Merci d'avoir choisi Finance à vie. Toutes les fonctionnalités Pro restent débloquées, pour toujours."
        }
    }

    private var redundantSubscriptionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Abonnement toujours actif", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.warning)
            Text("Vous avez l'accès à vie, mais un abonnement continue de se renouveler et de vous être facturé en plus. Annulez-le depuis les Réglages Apple pour ne payer qu'une fois.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Button("Gérer l'abonnement") { openAppleSubscriptionManagement() }
                .font(.caption.weight(.semibold))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var lifetimeConfirmationSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.Colors.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Formule Définitif")
                    .font(.subheadline.weight(.semibold))
                Text("Aucune échéance, aucune reconduction.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding()
        .background(AppTheme.Colors.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var featureListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppFeature.allCases, id: \.self) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .frame(width: 26)
                        .foregroundStyle(AppTheme.Colors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(feature.title))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.success)
                }
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var productPickerSection: some View {
        VStack(spacing: 10) {
            if store.productsLoading {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonPaywallProductCard()
                }
            } else if store.productsLoadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Impossible de charger les offres.\nVérifiez votre connexion.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await store.retryLoadProducts() }
                    } label: {
                        Label("Réessayer", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(store.products, id: \.id) { product in
                    ProductRowView(
                        product: product,
                        isSelected: selectedProductID == product.id,
                        isCurrentPlan: product.id == store.activeSubscriptionProductID,
                        badge: badgeFor(product)
                    )
                    .onTapGesture { selectedProductID = product.id }
                }
            }
        }
    }

    /// `nil` while nothing is selected; otherwise the product matching `selectedProductID`.
    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    /// The selection points EXACTLY to the already-active plan — nothing to do.
    private var isSelectionCurrentPlan: Bool {
        selectedProductID != nil && selectedProductID == store.activeSubscriptionProductID
    }

    private var actionButtonTitle: String {
        guard let product = selectedProduct else { return "Continuer" }
        if isSelectionCurrentPlan { return "Formule actuelle" }
        // Changing plans (monthly ↔ yearly, or to Lifetime): StoreKit
        // natively handles the proration since monthly and yearly share the
        // same subscription group — the same `purchase(_:)` call is enough, Apple
        // shows its own change-confirmation UI.
        if hasActiveSubscription {
            return "Changer pour ce plan · \(product.displayPrice)"
        }
        return "Continuer · \(product.displayPrice)"
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            // Bouton d'achat / changement de formule
            Button {
                guard let product = selectedProduct else { return }
                Task { await store.purchase(product) }
            } label: {
                Group {
                    if store.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(actionButtonTitle)
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProductID == nil || store.isLoading || store.products.isEmpty || isSelectionCurrentPlan)

            // A possible error
            if let error = store.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
                    .multilineTextAlignment(.center)
            }

            // Restauration
            Button("Restaurer les achats") {
                Task { await store.restorePurchases() }
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .disabled(store.isLoading)

            // Already subscribed: redirects to Apple to cancel / change the
            // payment method — StoreKit doesn't expose that from within the app.
            if hasActiveSubscription {
                Button("Gérer l'abonnement depuis les Réglages Apple") { openAppleSubscriptionManagement() }
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Link("Politique de confidentialité", destination: AppConstants.Legal.privacyPolicyURL)
                Link("Conditions d'utilisation", destination: AppConstants.Legal.termsOfUseURL)
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.Colors.textSecondary)

            Text("Les abonnements se renouvellent automatiquement jusqu'à résiliation. Vous pouvez gérer ou annuler votre abonnement à tout moment depuis les Réglages de votre iPhone > Identifiant Apple > Abonnements.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helpers

    private func badgeFor(_ product: Product) -> String? {
        guard product.id == AppConstants.Store.yearlyID else { return nil }
        // Computes the savings vs. monthly × 12
        if let monthly = store.monthlyProduct {
            let yearlyMonthly = product.price / 12
            let savingDecimal = (1 - yearlyMonthly / monthly.price) * 100
            let rounded = Int((savingDecimal as NSDecimalNumber).doubleValue.rounded())
            if rounded > 0 { return "-\(rounded)%" }
        }
        return "Populaire"
    }

    /// StoreKit allows neither canceling nor changing the payment method from
    /// within the app — only Apple's own Settings page can do that.
    private func openAppleSubscriptionManagement() {
        let url = AppConstants.Store.manageSubscriptionsURL
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - ProductRowView

private struct ProductRowView: View {
    let product: Product
    let isSelected: Bool
    var isCurrentPlan: Bool = false
    let badge: String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(product.displayName)
                        .font(.headline)
                    if isCurrentPlan {
                        // Takes priority over the marketing badge (-17%, Popular):
                        // once it's already owned, the sales pitch no longer applies.
                        Text("Formule actuelle")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.success, in: Capsule())
                    } else if let badge {
                        Text(badge)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue, in: Capsule())
                    }
                }
                Text(priceDescription)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .secondary)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? AppTheme.Colors.accent.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary.opacity(0.25),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
    }

    private var priceDescription: String {
        if product.type == .nonConsumable {
            return "\(product.displayPrice) · accès à vie, paiement unique"
        }
        guard let sub = product.subscription else { return product.displayPrice }
        let period = sub.subscriptionPeriod
        switch period.unit {
        case .month: return "\(product.displayPrice) / mois"
        case .year:  return "\(product.displayPrice) / an"
        default:     return product.displayPrice
        }
    }
}

// MARK: - Paywall Overlay Modifier

/// Overlays a lock screen on the view if the user doesn't have access
/// to the feature. The state is read from `PurchaseManager.shared` via
/// the environment — impossible to bypass client-side.
struct PaywallOverlay: ViewModifier {
    let feature: AppFeature
    @Environment(PurchaseManager.self) private var store
    @State private var showPaywall = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if !store.isUnlocked(feature) {
                    lockedOverlay
                }
            }
            .adaptivePane(isPresented: $showPaywall) {
                PaywallView()
                    .environment(store)
            }
    }

    private var lockedOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                VStack(spacing: 4) {
                    Text(LocalizedStringKey(feature.title))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(feature.description)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    showPaywall = true
                } label: {
                    Label("Voir les offres Pro", systemImage: "crown.fill")
                        .font(.headline)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Colors.accent)
            }
        }
    }
}

extension View {
    /// Locks the view behind a paywall if the user doesn't have the required level.
    func paywallOverlay(for feature: AppFeature) -> some View {
        modifier(PaywallOverlay(feature: feature))
    }
}

// MARK: - ProBadge

/// A small "PRO" badge with a crown, to show next to paid features.
struct ProBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "crown.fill")
                .font(.system(size: 8, weight: .bold))
            Text("PRO")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.accent, in: Capsule())
    }
}

// MARK: - ToolbarPaywallGate

/// Locks a `.toolbar` action behind the paywall.
///
/// `.paywallOverlay` isn't enough for a toolbar action: it's an
/// `.overlay {}` set on the CONTENT, and `.toolbar` items (the
/// navigation bar) live in a separate layer this overlay never
/// covers — they stay tappable even when the screen shows the padlock.
/// A real incident: Investments' "⋯" menu and the SQL Console's "+"
/// stayed fully functional behind the locked screen. Always route a
/// toolbar action through this wrapper rather than exposing it bare
/// next to a `paywallOverlay` on the content.
struct ToolbarPaywallGate<Content: View>: View {
    let feature: AppFeature
    @Environment(PurchaseManager.self) private var store
    @State private var showPaywall = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if store.isUnlocked(feature) {
            content()
        } else {
            Button {
                showPaywall = true
            } label: {
                Image(systemName: "lock.fill")
            }
            .adaptivePane(isPresented: $showPaywall) {
                PaywallView()
                    .environment(store)
            }
        }
    }
}
