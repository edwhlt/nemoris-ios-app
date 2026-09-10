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

    /// `true` si l'utilisateur a un abonnement récurrent actif (mensuel/annuel) —
    /// PAS Lifetime, qui n'a rien à "changer". C'est ce qui bascule l'écran de
    /// "vendre l'offre" à "gérer sa formule".
    private var hasActiveSubscription: Bool {
        store.activeSubscriptionProductID != nil
    }

    /// Lifetime acheté EN PLUS d'un abonnement encore actif — StoreKit n'annule
    /// jamais automatiquement un abonnement d'un autre groupe/type quand on achète
    /// un non-consommable, donc rien ne le fait à la place de l'utilisateur.
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

    /// Sélection par défaut : la formule déjà active (pour "gérer sa formule" plutôt
    /// que revendre l'existant), sinon annuel (meilleur rapport qualité/prix).
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

    /// `nil` tant qu'aucune sélection ; sinon le produit correspondant à `selectedProductID`.
    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    /// La sélection pointe EXACTEMENT vers la formule déjà active — rien à faire.
    private var isSelectionCurrentPlan: Bool {
        selectedProductID != nil && selectedProductID == store.activeSubscriptionProductID
    }

    private var actionButtonTitle: String {
        guard let product = selectedProduct else { return "Continuer" }
        if isSelectionCurrentPlan { return "Formule actuelle" }
        // Changement de formule (mensuel ↔ annuel, ou vers Lifetime) : StoreKit
        // gère nativement la proratisation puisque mensuel et annuel partagent le
        // même groupe d'abonnement — le même appel `purchase(_:)` suffit, Apple
        // affiche sa propre confirmation de changement.
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

            // Erreur éventuelle
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

            // Déjà abonné : renvoi vers Apple pour résilier / changer de moyen de
            // paiement — StoreKit ne l'expose pas depuis l'app.
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
        // Calcule l'économie par rapport au mensuel × 12
        if let monthly = store.monthlyProduct {
            let yearlyMonthly = product.price / 12
            let savingDecimal = (1 - yearlyMonthly / monthly.price) * 100
            let rounded = Int((savingDecimal as NSDecimalNumber).doubleValue.rounded())
            if rounded > 0 { return "-\(rounded)%" }
        }
        return "Populaire"
    }

    /// StoreKit ne permet ni de résilier ni de changer de moyen de paiement depuis
    /// l'app — seule la page Réglages Apple le fait.
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
                        // Prend le pas sur le badge marketing (-17%, Populaire) :
                        // une fois qu'on l'a déjà, l'argument de vente n'a plus lieu d'être.
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

/// Superpose un écran de verrouillage sur la vue si l'utilisateur n'a pas accès
/// à la fonctionnalité. L'état est lu depuis `PurchaseManager.shared` via
/// l'environnement — impossible à contourner côté client.
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
    /// Verrouille la vue derrière un paywall si l'utilisateur n'a pas le niveau requis.
    func paywallOverlay(for feature: AppFeature) -> some View {
        modifier(PaywallOverlay(feature: feature))
    }
}

// MARK: - ProBadge

/// Petit badge "PRO" avec une couronne, à afficher à côté des fonctionnalités payantes.
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

/// Verrouille une action de `.toolbar` derrière le paywall.
///
/// `.paywallOverlay` ne suffit pas pour une action de toolbar : c'est un
/// `.overlay {}` posé sur le CONTENU, et les items de `.toolbar` (barre de
/// navigation) vivent dans une couche à part que cet overlay ne recouvre
/// jamais — ils restent tapables même quand l'écran affiche le cadenas.
/// Incident réel : le menu "⋯" d'Investissements et le "+" de
/// la Console SQL restaient pleinement fonctionnels derrière l'écran
/// verrouillé. Toujours passer une action de toolbar par ce wrapper plutôt
/// que de l'exposer nue à côté d'un `paywallOverlay` sur le contenu.
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
