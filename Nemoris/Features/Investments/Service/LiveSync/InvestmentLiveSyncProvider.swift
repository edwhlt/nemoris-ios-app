import Foundation

// MARK: - Protocol + shared types for live sync providers
//
// Every provider (Binance CEX, EVM/BTC/SOL wallets) implements this protocol.
// They are read-only: an external account's state is read, never written.
//
// Credentials strategy:
//   - values are entered by the user in a form generated dynamically from
//     `credentialFields`
//   - stored encrypted in the iOS Keychain via `InvestmentCredentialStore`
//   - NEVER sent to a Nemoris server (there is no Nemoris server at all)
//
// Config strategy (per provider):
//   - some providers need non-sensitive metadata (e.g. the chosen EVM chain,
//     a wallet's public address). Stored in SQLite (`config_json`).

// MARK: - Champ de credential (form dynamique)

/// Describes a field to fill in the provider's credentials form.
/// The settings form generates the matching TextFields automatically.
struct LiveSyncCredentialField: Identifiable, Hashable, Sendable {
    let key: String              // ID interne stable (ex: "apiKey", "apiSecret", "address")
    let label: String            // Displayed label ("API key", "Public address")
    let isSecret: Bool           // true → SecureField, false → TextField
    let placeholder: String?
    let helpText: String?        // Help shown under the field
    let validation: ValidationRule

    var id: String { key }

    enum ValidationRule: Hashable, Sendable {
        case nonEmpty
        case minLength(Int)
        case hexAddress           // 0x... 40 hex chars (EVM)
        case bitcoinAddress       // bc1... | 1... | 3...
        case solanaAddress        // base58, 32-44 chars
        case anyString            // accepts anything (used for optional fields)
    }

    /// True if the value passes the rule. No custom error message — the UI just
    /// shows "Invalid value" on failure.
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

// MARK: - Sync result: positions + transactions

/// A position returned by a provider after a sync.
/// Mapped to `investment_positions` by `LiveSyncRegistry.applySync`.
struct LiveSyncPosition: Hashable {
    let assetType: String           // "crypto" (may be extended later)
    let assetName: String           // "Ethereum", "USD Coin"
    let ticker: String              // "ETH", "USDC"
    let quantity: Double            // Current quantity in the wallet/exchange
    let currentValueEUR: Double?    // nil = price not found via CoinGecko
    let metadata: [String: String]  // Ex: ["contractAddress": "0x...", "chain": "polygon"]
}

/// A historical transaction returned by a provider.
/// Mapped to `investment_orders` (crypto buy/sell/dividend) or ignored if irrelevant.
struct LiveSyncTransaction: Hashable {
    /// Stable external ID (e.g. a blockchain txHash or a Binance tradeId) — lets
    /// the next sync deduplicate without recreating the same operation.
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

    /// Each branch goes through `AppLocalization.string(...)`, so the message
    /// follows the app's language. `msg` (the only parameter already localized
    /// by the caller, see `LiveSyncRegistry`) must remain a SEPARATE fragment in
    /// the interpolation — never concatenated BEFORE the call to
    /// `AppLocalization.string`, otherwise the lookup key changes with every
    /// value of `msg` and never matches the table.
    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return AppLocalization.string("Credentials manquants ou incomplets.")
        case .invalidCredentials:
            return AppLocalization.string("Credentials invalides ou révoqués.")
        case .rateLimited(let r):
            if let r { return AppLocalization.string("Limite de taux atteinte. Réessayez dans \(Int(r))s.") }
            return AppLocalization.string("Limite de taux atteinte. Réessayez plus tard.")
        case .networkError(let msg):
            return AppLocalization.string("Erreur réseau : \(msg)")
        case .parseError(let msg):
            return AppLocalization.string("Erreur de lecture des données : \(msg)")
        case .providerNotImplemented:
            return AppLocalization.string("Provider pas encore disponible (à venir).")
        }
    }
}

// MARK: - Protocol provider

/// Every live sync provider conforms to this protocol. `Sendable` so they can
/// be used from any actor without Swift 6 concurrency warnings.
protocol InvestmentLiveSyncProvider: Sendable {

    /// Argument-less init, required to instantiate from a metatype
    /// (e.g. `providerType.init()` in the Registry).
    init()

    /// The provider's stable internal ID (e.g. "binance", "evm_wallet").
    /// Used as the key in `investment_live_sync.provider_id` and in the Keychain.
    static var id: String { get }

    /// Label shown to the user (e.g. "Binance", "EVM wallet").
    static var displayName: String { get }

    /// SF Symbol representing the provider (e.g. "bitcoinsign.circle", "link").
    static var iconName: String { get }

    /// Short description shown in the add picker.
    static var description: String { get }

    /// Credential fields to ask the user for (apiKey, address, etc.).
    /// The settings form generates the TextFields dynamically.
    static var credentialFields: [LiveSyncCredentialField] { get }

    /// If true, the user is also asked to pick a chain (e.g. EVM).
    /// The form then shows a Picker of the supported chains.
    static var supportsChainSelection: Bool { get }

    /// Supported chains (when `supportsChainSelection == true`).
    /// The tag is stored in `config_json` under the "chain" key.
    static var supportedChains: [LiveSyncChainOption] { get }

    /// Tests the credentials without changing any state (minimal validation
    /// endpoint). Throws `LiveSyncError` on a problem.
    func validate(credentials: [String: String], config: [String: String]) async throws

    /// Fetches current positions. Must apply the EUR conversion via
    /// `PriceResolver` if the provider doesn't already return EUR prices.
    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition]

    /// Fetches historical transactions. `since` limits the range (incremental
    /// sync). If nil → the whole current year by default.
    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction]
}

/// A chain supported by an EVM/multi-chain provider.
struct LiveSyncChainOption: Identifiable, Hashable, Sendable {
    let id: String           // ID interne ("eth", "polygon", "bsc", "arbitrum"...)
    let displayName: String  // "Ethereum", "Polygon"
    let icon: String         // SF Symbol
    let nativeCurrency: String // "ETH", "MATIC", "BNB"
    let chainIdHex: String?  // For EVM: 0x1, 0x89, etc. nil for non-EVM
}

// MARK: - Character helpers for hex validation

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) ||
        ("a"..."f").contains(self) ||
        ("A"..."F").contains(self)
    }
}
