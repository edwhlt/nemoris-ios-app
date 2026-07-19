import Foundation
import StoreKit
import Observation

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
enum AppFeature: CaseIterable {
    case smartImport
    case investments
    //case tricount
    case filteredDashboard
    case sync
    case sqlConsole
    case budget

    /// Niveau minimum requis pour accéder à la fonctionnalité.
    var requiredLevel: AccessLevel { .pro }

    var title: String {
        switch self {
        case .smartImport:       return "Import intelligent"
        case .investments:       return "Investissements"
        //case .tricount:          return "Tricount"
        case .filteredDashboard: return "Dashboard filtré"
        case .sync:              return "Synchronisation"
        case .sqlConsole:        return "Console SQL"
        case .budget:            return "Budget & Prévisions"
        }
    }

    var description: String {
        switch self {
        case .smartImport:       return "Reconnaissance automatique des tiers par IA"
        case .investments:       return "Suivi de portefeuille et performance"
        //case .tricount:          return "Partage de dépenses en groupe"
        case .filteredDashboard: return "Analyses par période, compte ou catégorie"
        case .sync:              return "Sauvegarde automatique vers iCloud / OneDrive"
        case .sqlConsole:        return "Requêtes SQL directes sur votre base de données"
        case .budget:            return "Prévisions, récurrents, enveloppes et calendrier"
        }
    }

    var icon: String {
        switch self {
        case .smartImport:       return "wand.and.stars"
        case .investments:       return "chart.line.uptrend.xyaxis"
        //case .tricount:          return "person.2.fill"
        case .filteredDashboard: return "line.3.horizontal.decrease.circle"
        case .sync:              return "arrow.triangle.2.circlepath"
        case .sqlConsole:        return "terminal"
        case .budget:            return "chart.bar.fill"
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
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var productsLoading = true
    private(set) var productsLoadFailed = false
    private(set) var purchaseError: String?

    #if DEBUG
    /// Override développeur : force l'accès Lifetime sans achat réel.
    /// Jamais compilé en production (Release).
    var devOverrideEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "devOverride") }
        set {
            UserDefaults.standard.set(newValue, forKey: "devOverride")
            accessLevel = newValue ? .lifetime : .free
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
        if devOverrideEnabled { accessLevel = .lifetime; return }
        #endif
        var highest = AccessLevel.free

        // 1. Transactions StoreKit vérifiées cryptographiquement (anti-triche)
        for await result in Transaction.currentEntitlements {
            guard let tx = try? checkVerified(result) else { continue }
            guard tx.revocationDate == nil else { continue }

            switch tx.productID {
            case AppConstants.Store.lifetimeID:
                highest = .lifetime
            case AppConstants.Store.monthlyID, AppConstants.Store.yearlyID:
                if highest < .pro { highest = .pro }
            default:
                break
            }
        }

        accessLevel = highest
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
