import Foundation
import StoreKit
import Observation
import WidgetKit

// MARK: - Access Level

/// Niveau d'accès de l'utilisateur, du plus bas au plus élevé.
/// Jamais stocké en UserDefaults — toujours dérivé des transactions StoreKit vérifiées
/// cryptographiquement. Un utilisateur ne peut pas tricher en modifiant les préférences.
enum AccessLevel: Int, Comparable {
    case free = 0
    case pro = 1
    case lifetime = 2

    static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .free:     return "Gratuit"
        case .pro:      return "Pro"
        case .lifetime: return "Lifetime"
        }
    }

    var badgeColor: String {
        switch self {
        case .free:     return "gray"
        case .pro:      return "blue"
        case .lifetime: return "yellow"
        }
    }
}

// MARK: - App Feature

/// Fonctionnalités de l'application pouvant être verrouillées derrière un niveau d'accès.
///
/// Doctrine : Transactions, Patrimoine, Investissements et Tricount sont
/// des modules GRATUITS dans leur ensemble — la promesse de base de chacun reste
/// utilisable sans payer. Seule leur couche "avancée / automatisée" est Pro
/// (`investmentsLiveSync`, `patrimoineProjection`), au même titre que l'analyse
/// filtrée au sein de Transactions (`filteredDashboard`). Budget et Console SQL
/// restent des murs complets : ce sont des modules "métier sérieux" où la promesse
/// claire (payer = tout le module) vend mieux qu'un accès bridé.
enum AppFeature: CaseIterable {
    case investmentsLiveSync
    case patrimoineProjection
    //case tricount
    case filteredDashboard
    case sqlConsole
    case budget

    /// Niveau minimum requis pour accéder à la fonctionnalité.
    var requiredLevel: AccessLevel { .pro }

    var title: String {
        switch self {
        case .investmentsLiveSync:  return "Live Sync"
        case .patrimoineProjection: return "Projection patrimoniale"
        //case .tricount:            return "Tricount"
        case .filteredDashboard:    return "Dashboard filtré"
        case .sqlConsole:           return "Console SQL"
        case .budget:               return "Budget & Prévisions"
        }
    }

    var description: String {
        switch self {
        case .investmentsLiveSync:  return "Synchronisation automatique de vos exchanges et wallets crypto"
        case .patrimoineProjection: return "Prévision de votre patrimoine net dans le temps"
        //case .tricount:            return "Partage de dépenses en groupe"
        case .filteredDashboard:    return "Analyses par période, compte ou catégorie"
        case .sqlConsole:           return "Requêtes SQL directes sur votre base de données"
        case .budget:               return "Prévisions, récurrents, enveloppes et calendrier"
        }
    }

    var icon: String {
        switch self {
        case .investmentsLiveSync:  return "arrow.triangle.2.circlepath"
        case .patrimoineProjection: return "chart.line.uptrend.xyaxis"
        //case .tricount:            return "person.2.fill"
        case .filteredDashboard:    return "line.3.horizontal.decrease.circle"
        case .sqlConsole:           return "terminal"
        case .budget:               return "chart.bar.fill"
        }
    }
}

// MARK: - Store Error

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        "La signature de l'achat n'a pas pu être vérifiée."
    }
}

// MARK: - PurchaseManager

/// Gestionnaire centralisé des achats in-app (StoreKit 2).
///
/// **Anti-triche** : le niveau d'accès (`accessLevel`) n'est JAMAIS persisté en
/// UserDefaults ni dans un fichier. Il est calculé à chaque lancement en interrogeant
/// `Transaction.currentEntitlements`, dont les reçus sont signés par Apple et
/// vérifiés cryptographiquement par `checkVerified(_:)`. Toute tentative de
/// manipulation locale (édition de plist, tweak jailbreak, etc.) est sans effet.
@Observable
@MainActor
final class PurchaseManager {
    static let shared = PurchaseManager()

    // MARK: State (read-only publiquement)

    private(set) var accessLevel: AccessLevel = .free
    /// ID du produit d'abonnement récurrent actif (mensuel/annuel), `nil` si aucun
    /// abonnement en cours (gratuit, ou Lifetime acheté sans abonnement en parallèle).
    /// Comme `accessLevel` : jamais persisté, recalculé à chaque `refreshEntitlements()`
    /// depuis `Transaction.currentEntitlements`. Sert à l'écran Paywall pour proposer
    /// un changement de formule (mensuel ↔ annuel) plutôt que de re-vendre l'offre déjà
    /// possédée.
    private(set) var activeSubscriptionProductID: String?
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var productsLoading = true
    private(set) var productsLoadFailed = false
    private(set) var purchaseError: String?

    #if DEBUG
    /// Override développeur : force l'accès Lifetime sans achat réel.
    /// Jamais compilé en production (Release).
    /// Propriété STOCKÉE (pas de get/set custom) : `@Observable` n'instrumente que
    /// les propriétés stockées, sinon le Toggle de SettingsView ne se rafraîchit jamais.
    var devOverrideEnabled: Bool = UserDefaults.standard.bool(forKey: "devOverride") {
        didSet {
            UserDefaults.standard.set(devOverrideEnabled, forKey: "devOverride")
            accessLevel = devOverrideEnabled ? .lifetime : .free
        }
    }
    #endif

    // MARK: Init

    private nonisolated init() {}

    // MARK: - Public API

    /// À appeler au lancement de l'app via `.task` : charge les produits et
    /// démarre l'écoute des transactions.
    ///
    /// Ordre voulu :
    /// 1. Écoute des transactions (instantané).
    /// 2. `refreshEntitlements` : LOCAL (cache StoreKit iOS), quasi-instantané →
    ///    permet d'avoir le bon `accessLevel` avant le 1er rendu UI.
    /// 3. `loadProducts` : RÉSEAU, peut prendre 1-3 s. Concerne uniquement le
    ///    contenu de la Paywall, pas l'état d'accès des features déjà activées.
    func initialize() async {
        startTransactionListener()
        await refreshEntitlements()
        await loadProducts()
    }

    /// Lance l'achat du produit sélectionné.
    func purchase(_ product: Product) async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Restaure les achats précédents (non-consommables + abonnements actifs).
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Retourne `true` si l'utilisateur a accès à la fonctionnalité donnée.
    func isUnlocked(_ feature: AppFeature) -> Bool {
        accessLevel >= feature.requiredLevel
    }

    // MARK: - Produits conveniences

    var monthlyProduct: Product? {
        products.first { $0.id == AppConstants.Store.monthlyID }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == AppConstants.Store.yearlyID }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == AppConstants.Store.lifetimeID }
    }

    /// Le produit d'abonnement actif (mensuel ou annuel), s'il y en a un.
    var activeSubscriptionProduct: Product? {
        guard let id = activeSubscriptionProductID else { return nil }
        return products.first { $0.id == id }
    }

    // MARK: - Private

    private func loadProducts() async {
        productsLoading = true
        productsLoadFailed = false
        defer { productsLoading = false }
        do {
            let ids: Set<String> = [
                AppConstants.Store.monthlyID,
                AppConstants.Store.yearlyID,
                AppConstants.Store.lifetimeID
            ]
            let fetched = try await Product.products(for: ids)
            products = fetched.sorted { $0.price < $1.price }
            // Produits introuvables = non configurés dans ASC (métadonnées manquantes)
            if fetched.isEmpty { productsLoadFailed = true }
        } catch {
            productsLoadFailed = true
        }
    }

    func retryLoadProducts() async {
        await loadProducts()
    }

    /// Recalcule `accessLevel` à partir des transactions actuelles vérifiées par Apple.
    /// Jamais persisté — appelé à chaque lancement et à chaque mise à jour de transaction.
    func refreshEntitlements() async {
        #if DEBUG
        if devOverrideEnabled {
            accessLevel = .lifetime
            activeSubscriptionProductID = nil
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        #endif
        var highest = AccessLevel.free
        var subscriptionID: String?

        // 1. Transactions StoreKit vérifiées cryptographiquement (anti-triche)
        for await result in Transaction.currentEntitlements {
            guard let tx = try? checkVerified(result) else { continue }
            guard tx.revocationDate == nil else { continue }

            switch tx.productID {
            case AppConstants.Store.lifetimeID:
                highest = .lifetime
            case AppConstants.Store.monthlyID, AppConstants.Store.yearlyID:
                if highest < .pro { highest = .pro }
                subscriptionID = tx.productID
            default:
                break
            }
        }
        activeSubscriptionProductID = subscriptionID

        let changed = accessLevel != highest
        accessLevel = highest

        // Le widget Budget lit son propre accès Pro via `Transaction.currentEntitlements`
        // dans l'extension (cf. `WidgetAccessGate`), mais ne le recalcule que quand
        // WidgetKit relance sa timeline — jamais spontanément après un achat/une
        // restauration. Sans ce reload, un widget déjà posé restait verrouillé (ou
        // déverrouillé) jusqu'à sa prochaine actualisation planifiée (30 min).
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Écoute les mises à jour en temps réel (renouvellements automatiques, révocations).
    private func startTransactionListener() {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let tx = try? self.checkVerified(result) {
                    await tx.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    /// Vérifie la signature cryptographique du reçu Apple.
    /// Lance `StoreError.failedVerification` si le reçu est altéré.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }
}
