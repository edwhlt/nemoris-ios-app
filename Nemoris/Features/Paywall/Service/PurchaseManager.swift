import Foundation
import StoreKit
import Observation
import WidgetKit

// MARK: - Access Level

/// The user's access level, from lowest to highest.
/// Never stored in UserDefaults — always derived from cryptographically
/// verified StoreKit transactions. A user can't cheat by editing preferences.
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

/// App features that can be locked behind an access level.
///
/// Doctrine: Transactions, Patrimoine, Investments and Tricount are
/// FREE modules as a whole — each one's core promise stays
/// usable without paying. Only their "advanced/automated" layer is Pro
/// (`investmentsLiveSync`, `patrimoineProjection`), on the same footing as
/// filtered analysis within Transactions (`filteredDashboard`). Budget and the SQL
/// Console stay full walls: they're "serious business" modules where a
/// clear promise (pay = the whole module) sells better than a throttled access.
enum AppFeature: CaseIterable {
    case investmentsLiveSync
    case patrimoineProjection
    //case tricount
    case filteredDashboard
    case sqlConsole
    case budget

    /// The minimum level required to access the feature.
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
        //case .tricount:            return "Group expense sharing"
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

/// A centralized manager for in-app purchases (StoreKit 2).
///
/// **Anti-cheat**: the access level (`accessLevel`) is NEVER persisted in
/// UserDefaults or a file. It's computed on every launch by querying
/// `Transaction.currentEntitlements`, whose receipts are signed by Apple and
/// cryptographically verified by `checkVerified(_:)`. Any local
/// manipulation attempt (editing a plist, a jailbreak tweak, etc.) has no effect.
@Observable
@MainActor
final class PurchaseManager {
    static let shared = PurchaseManager()

    // MARK: State (read-only publiquement)

    private(set) var accessLevel: AccessLevel = .free
    /// The ID of the active recurring subscription product (monthly/yearly), `nil` if there's no
    /// ongoing subscription (free, or Lifetime bought with no subscription running in parallel).
    /// Like `accessLevel`: never persisted, recomputed on every `refreshEntitlements()`
    /// from `Transaction.currentEntitlements`. Used by the Paywall screen to offer
    /// a plan change (monthly ↔ yearly) instead of re-selling an offer already owned.
    private(set) var activeSubscriptionProductID: String?
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var productsLoading = true
    private(set) var productsLoadFailed = false
    private(set) var purchaseError: String?

    #if DEBUG
    /// A developer override: forces Lifetime access with no real purchase.
    /// Never compiled in production (Release).
    /// A STORED property (no custom get/set): `@Observable` only instruments
    /// stored properties, otherwise SettingsView's Toggle would never refresh.
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

    /// Call at app launch via `.task`: loads the products and
    /// starts listening for transactions.
    ///
    /// The intended order:
    /// 1. Listening for transactions (instant).
    /// 2. `refreshEntitlements`: LOCAL (the iOS StoreKit cache), near-instant →
    ///    lets the right `accessLevel` be ready before the 1st UI render.
    /// 3. `loadProducts`: NETWORK, can take 1-3s. Only affects
    ///    the Paywall's content, not already-active features' access state.
    func initialize() async {
        startTransactionListener()
        await refreshEntitlements()
        await loadProducts()
    }

    /// Starts purchasing the selected product.
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

    /// Restores previous purchases (non-consumables + active subscriptions).
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

    /// Returns `true` if the user has access to the given feature.
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

    /// The active subscription product (monthly or yearly), if there is one.
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
            // Products not found = not configured in ASC (missing metadata)
            if fetched.isEmpty { productsLoadFailed = true }
        } catch {
            productsLoadFailed = true
        }
    }

    func retryLoadProducts() async {
        await loadProducts()
    }

    /// Recomputes `accessLevel` from currently Apple-verified transactions.
    /// Never persisted — called on every launch and every transaction update.
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

        // 1. Cryptographically verified StoreKit transactions (anti-cheat)
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

        // The Budget widget reads its own Pro access via `Transaction.currentEntitlements`
        // in the extension (see `WidgetAccessGate`), but only recomputes it when
        // WidgetKit relaunches its timeline — never spontaneously after a purchase/a
        // restore. Without this reload, an already-placed widget stayed locked (or
        // unlocked) until its next scheduled refresh (30 min).
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Listens for real-time updates (automatic renewals, revocations).
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

    /// Verifies the cryptographic signature of an Apple receipt.
    /// Throws `StoreError.failedVerification` if the receipt is tampered with.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }
}
