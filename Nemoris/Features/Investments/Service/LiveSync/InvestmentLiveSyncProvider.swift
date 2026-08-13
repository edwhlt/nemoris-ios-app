import Foundation

// MARK: - AXE I Couche 0b — Protocol + types communs pour les providers de live sync
//
// Tous les providers (Binance CEX, wallets EVM/BTC/SOL) implémentent ce protocol.
// Ils sont read-only : on lit l'état d'un compte externe sans jamais y écrire.
//
// Stratégie credentials :
//   - les valeurs sont saisies par l'utilisateur dans un form généré dynamiquement depuis
//     `credentialFields`
//   - stockées chiffrées en Keychain iOS via `InvestmentCredentialStore`
//   - JAMAIS transmises à un serveur Nemoris (pas de serveur Nemoris du tout)
//
// Stratégie config (par provider) :
//   - certains providers ont besoin de metadata non-sensibles (ex: chaîne EVM choisie,
//     adresse publique d'un wallet). Stockées en SQLite (`config_json`).

// MARK: - Champ de credential (form dynamique)

/// Décrit un champ à remplir dans le formulaire de credentials du provider.
/// Le form Settings génère automatiquement les TextField correspondants.
struct LiveSyncCredentialField: Identifiable, Hashable, Sendable {
    let key: String              // ID interne stable (ex: "apiKey", "apiSecret", "address")
    let label: String            // Libellé affiché ("Clé API", "Adresse publique")
    let isSecret: Bool           // true → SecureField, false → TextField
    let placeholder: String?
    let helpText: String?        // Aide affichée sous le field
    let validation: ValidationRule

    var id: String { key }

    enum ValidationRule: Hashable, Sendable {
        case nonEmpty
        case minLength(Int)
        case hexAddress           // 0x... 40 hex chars (EVM)
        case bitcoinAddress       // bc1... | 1... | 3...
        case solanaAddress        // base58, 32-44 chars
        case anyString            // accepte tout (utilisé pour les champs optionnels)
    }

    /// True si la valeur passée respecte la règle. Pas d'erreur message custom
    /// — l'UI affiche juste "Valeur invalide" en cas d'échec.
    func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch validation {
        case .nonEmpty:
            return !trimmed.isEmpty
        case .minLength(let n):
            return trimmed.count >= n
        case .hexAddress:
            return trimmed.lowercased().hasPrefix("0x") && trimmed.count == 42 &&
                   trimmed.dropFirst(2).allSatisfy { $0.isHexDigit }
        case .bitcoinAddress:
            // Heuristique simple : bech32 (bc1...), P2SH (3...), legacy (1...)
            return (trimmed.hasPrefix("bc1") && trimmed.count >= 42) ||
                   (trimmed.hasPrefix("3") && trimmed.count >= 26) ||
                   (trimmed.hasPrefix("1") && trimmed.count >= 26)
        case .solanaAddress:
            // base58 : 32-44 chars, pas de 0/O/I/l
            let allowed = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            return trimmed.count >= 32 && trimmed.count <= 44 &&
                   trimmed.allSatisfy { allowed.contains($0) }
        case .anyString:
            return true
        }
    }
}

// MARK: - Résultat de sync : positions + transactions

/// Représente une position retournée par un provider après sync.
/// Mappée vers `investment_positions` par `LiveSyncRegistry.applySync`.
struct LiveSyncPosition: Hashable {
    let assetType: String           // "crypto" (peut s'étendre plus tard)
    let assetName: String           // "Ethereum", "USD Coin"
    let ticker: String              // "ETH", "USDC"
    let quantity: Double            // Quantité actuelle dans le wallet/exchange
    let currentValueEUR: Double?    // nil = prix non trouvé via CoinGecko
    let metadata: [String: String]  // Ex: ["contractAddress": "0x...", "chain": "polygon"]
}

/// Représente une transaction historique retournée par un provider.
/// Mappée vers `investment_orders` (achat/vente/dividende crypto) ou ignorée si pas pertinent.
struct LiveSyncTransaction: Hashable {
    /// ID externe stable (ex: txHash blockchain ou tradeId Binance) — permet de
    /// déduplique au prochain sync sans re-créer la même opération.
    let externalId: String
    let orderType: InvestmentOrderType
    let assetTicker: String
    let quantity: Double
    let unitPriceEUR: Double?
    let fees: Double
    let executedAt: Date
    let notes: String?
}

// MARK: - Erreurs de sync

enum LiveSyncError: LocalizedError, Sendable {
    case missingCredentials
    case invalidCredentials
    case rateLimited(retryAfter: TimeInterval?)
    case networkError(String)
    case parseError(String)
    case providerNotImplemented

    var errorDescription: String? {
        switch self {
        case .missingCredentials:     return "Credentials manquants ou incomplets."
        case .invalidCredentials:     return "Credentials invalides ou révoqués."
        case .rateLimited(let r):
            if let r { return "Limite de taux atteinte. Réessayez dans \(Int(r))s." }
            return "Limite de taux atteinte. Réessayez plus tard."
        case .networkError(let msg):  return "Erreur réseau : \(msg)"
        case .parseError(let msg):    return "Erreur de lecture des données : \(msg)"
        case .providerNotImplemented: return "Provider pas encore disponible (à venir)."
        }
    }
}

// MARK: - Protocol provider

/// Tous les providers de live sync conforment à ce protocol. `Sendable` pour pouvoir
/// les utiliser depuis n'importe quel acteur sans warning concurrency Swift 6.
protocol InvestmentLiveSyncProvider: Sendable {

    /// Init sans argument requis pour pouvoir instancier depuis un `metatype`
    /// (ex: `providerType.init()` dans le Registry).
    init()

    /// ID interne stable du provider (ex: "binance", "evm_wallet").
    /// Utilisé comme clé dans `investment_live_sync.provider_id` et Keychain.
    static var id: String { get }

    /// Libellé affiché à l'utilisateur (ex: "Binance", "Wallet EVM").
    static var displayName: String { get }

    /// SF Symbol représentant le provider (ex: "bitcoinsign.circle", "link").
    static var iconName: String { get }

    /// Description courte affichée dans le picker d'ajout.
    static var description: String { get }

    /// Champs de credentials à demander à l'utilisateur (apiKey, address, etc.).
    /// Le form Settings génère les TextField dynamiquement.
    static var credentialFields: [LiveSyncCredentialField] { get }

    /// Si true, on demande aussi à l'utilisateur de choisir une chaîne (ex: EVM).
    /// Le form affiche un Picker des chaînes supportées dans ce cas.
    static var supportsChainSelection: Bool { get }

    /// Liste des chaînes supportées (si `supportsChainSelection == true`).
    /// Le tag est stocké dans `config_json` sous la clé "chain".
    static var supportedChains: [LiveSyncChainOption] { get }

    /// Teste les credentials sans modifier d'état (endpoint minimal de validation).
    /// Throw `LiveSyncError` si problème.
    func validate(credentials: [String: String], config: [String: String]) async throws

    /// Récupère les positions actuelles. Doit appliquer la conversion EUR via
    /// `PriceResolver` si le provider ne renvoie pas déjà des prix EUR.
    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition]

    /// Récupère les transactions historiques. `since` permet de limiter (sync incrémentale).
    /// Si nil → toute l'année courante par défaut.
    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction]
}

/// Une chaîne supportée par un provider EVM/multi-chain.
struct LiveSyncChainOption: Identifiable, Hashable, Sendable {
    let id: String           // ID interne ("eth", "polygon", "bsc", "arbitrum"...)
    let displayName: String  // "Ethereum", "Polygon"
    let icon: String         // SF Symbol
    let nativeCurrency: String // "ETH", "MATIC", "BNB"
    let chainIdHex: String?  // Pour EVM : 0x1, 0x89, etc. nil pour non-EVM
}

// MARK: - Helpers Character pour validation hex

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) ||
        ("a"..."f").contains(self) ||
        ("A"..."F").contains(self)
    }
}
