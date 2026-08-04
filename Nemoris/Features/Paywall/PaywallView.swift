import SwiftUI
import StoreKit

// MARK: - PaywallView

struct PaywallView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(PurchaseManager.self) private var store

    @State private var selectedProductID: String? = nil

    var body: some View {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    featureListSection
                    productPickerSection
                    actionSection
                    legalFooter
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .paneChrome("Finance Pro", cancelLabel: "Fermer", onCancel: { dismiss() })
        .onAppear {
            // Sélection par défaut : annuel (meilleur rapport qualité/prix)
            selectedProductID = store.yearlyProduct?.id ?? store.products.first?.id
        }
        .onChange(of: store.products) { _, products in
            if selectedProductID == nil {
                selectedProductID = store.yearlyProduct?.id ?? products.first?.id
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color(hex: "FFD700"))
                .padding(.top, 8)

            Text("Passez à Finance Pro")
                .font(.title2)
                .fontWeight(.bold)

            Text("Débloquez toutes les fonctionnalités et gérez vos finances sans aucune limite.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var featureListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppFeature.allCases, id: \.self) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .frame(width: 26)
                        .foregroundStyle(AppTheme.Colors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title)
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
                        badge: badgeFor(product)
                    )
                    .onTapGesture { selectedProductID = product.id }
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            // Bouton d'achat principal
            Button {
                guard let id = selectedProductID,
                      let product = store.products.first(where: { $0.id == id }) else { return }
                Task { await store.purchase(product) }
            } label: {
                Group {
                    if store.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        let price = store.products.first(where: { $0.id == selectedProductID })?.displayPrice
                        Text(price.map { "Continuer · \($0)" } ?? "Continuer")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProductID == nil || store.isLoading || store.products.isEmpty)

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
}

// MARK: - ProductRowView

private struct ProductRowView: View {
    let product: Product
    let isSelected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(product.displayName)
                        .font(.headline)
                    if let badge {
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
                    Text(feature.title)
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
/// Incident réel (2026-08-01) : le menu "⋯" d'Investissements et le "+" de
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
