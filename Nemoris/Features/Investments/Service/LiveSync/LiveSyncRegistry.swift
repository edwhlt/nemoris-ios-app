import Foundation

// MARK: - Provider orchestration registry
//
// Single entry point to:
//   - list the available providers (catalog shown in the add UI)
//   - dispatch a sync to a link's provider
//   - persist the result (positions + transactions) in the investments schema
//
// Each provider's static metadata (id, displayName, icon, fields) is declared
// at the bottom of this file; its network methods (validate/fetchPositions/
// fetchTransactions) live in an extension under `Providers/`.

@MainActor
final class LiveSyncRegistry {

    static let shared = LiveSyncRegistry()
    private init() {}

    private let repo = LiveSyncRepository.shared
    private let credentialStore = InvestmentCredentialStore.shared
    private let investmentRepo = InvestmentRepository()

    // MARK: - Catalogue providers disponibles

    /// Providers known to the app, wrapped in `LiveSyncProviderEntry` to be
    /// `Identifiable` (metatypes aren't, directly).
    static let availableProviders: [LiveSyncProviderEntry] = [
        LiveSyncProviderEntry(BinanceLiveSyncProvider.self),
        LiveSyncProviderEntry(EvmWalletLiveSyncProvider.self),
        LiveSyncProviderEntry(BitcoinWalletLiveSyncProvider.self),
        LiveSyncProviderEntry(SolanaWalletLiveSyncProvider.self)
    ]

    /// Resolves a provider by its ID (see `InvestmentLiveSyncProvider.id`).
    /// Returns nil for an unknown ID.
    static func provider(for id: String) -> InvestmentLiveSyncProvider.Type? {
        availableProviders.first(where: { $0.id == id })?.providerType
    }

    // MARK: - Sync orchestration

    /// Runs one link's sync. Updates `last_sync_*` afterwards.
    /// Returns nil on success, otherwise the user-friendly error message.
    ///
    /// Returns a `String` (not a `LocalizedStringResource`): this return value is
    /// only used for a toast shown immediately (same render pass, hence already
    /// in the right language — no risk of freezing a translation).
    /// `repo.updateSyncStatus`, on the other hand, PERSISTS the message — THAT
    /// path must stay a `LocalizedStringResource`.
    func syncLink(_ link: InvestmentLiveSyncLink) async -> String? {
        guard let providerType = Self.provider(for: link.providerId) else {
            let msg = LocalizedStringResource("Provider inconnu : \(link.providerId)")
            repo.updateSyncStatus(linkId: link.id, status: .error, message: msg)
            return String(localized: msg)
        }
        guard let creds = credentialStore.load(linkId: link.id, providerId: link.providerId) else {
            let msg = LocalizedStringResource("Credentials manquants pour ce lien.")
            repo.updateSyncStatus(linkId: link.id, status: .error, message: msg)
            return String(localized: msg)
        }

        // Mark as pending before the call (useful for the UI loader)
        repo.updateSyncStatus(linkId: link.id, status: .pending, message: nil, syncedAt: link.lastSyncAt ?? Date())

        let providerInstance = providerType.init()
        do {
            // Fetch the real positions
            let positions = try await providerInstance.fetchPositions(credentials: creds, config: link.config)
            // Persist to investment_positions.
            // Also returns the effective accountId (resolved OR created by
            // persistPositions) so it can be fed into persistTransactions below —
            // without it, on the first sync where the account is auto-created,
            // link.accountId stays nil locally and persistTransactions returns early,
            // skipping every trade.
            let (positionsSummary, resolvedAccountId) = try persistPositions(
                positions, link: link, providerType: providerType
            )
            // Rebuild a link with the up-to-date accountId for the next steps
            var linkWithAccount = link
            linkWithAccount.accountId = resolvedAccountId

            // Fetch + persist transactions/trades.
            // Only if the provider supports them (Binance for now — blockchain wallets
            // always return [] since their fetchTransactions aren't implemented).
            // Transactions are persisted in investment_orders with an external_id for
            // deduplication.
            var transactionsSummary: LocalizedStringResource?
            let transactions = (try? await providerInstance.fetchTransactions(
                credentials: creds, config: link.config, since: nil
            )) ?? []
            if !transactions.isEmpty {
                transactionsSummary = persistTransactions(transactions, link: linkWithAccount)
            }

            let msg = Self.joinLocalized([positionsSummary, transactionsSummary].compactMap { $0 }, separator: " · ")
            repo.updateSyncStatus(linkId: link.id, status: .ok, message: msg)
            return nil
        } catch let err as LiveSyncError {
            let msg = err.errorDescription.map { LocalizedStringResource(stringLiteral: $0) } ?? LocalizedStringResource("Erreur de sync.")
            repo.updateSyncStatus(linkId: link.id, status: .error, message: msg)
            return String(localized: msg)
        } catch {
            let msg = LocalizedStringResource(stringLiteral: error.localizedDescription)
            repo.updateSyncStatus(linkId: link.id, status: .error, message: msg)
            return error.localizedDescription
        }
    }

    /// Syncs every enabled link. Sequential, to respect the CoinGecko/Etherscan
    /// rate limits (no bursts). Returns a status per link (error = nil on success)
    /// so the caller (InvestmentAutoSyncService) can build its summary.
    @discardableResult
    func syncAll() async -> [(linkName: String, error: String?)] {
        let links = repo.fetchLinks().filter { $0.enabled }
        var results: [(linkName: String, error: String?)] = []
        for link in links {
            let error = await syncLink(link)
            results.append((linkName: link.displayName, error: error))
        }
        return results
    }

    // MARK: - Persisting to investment_positions
    //
    // Strategy:
    //   1. If `link.accountId` is nil → create a new `investment_account`
    //      automatically, with a name derived from the provider (e.g. "Binance —
    //      personal", "ETH wallet").
    //   2. For each LiveSyncPosition returned by the provider:
    //      - Look for an existing position (account + ticker) in investment_positions
    //      - If found: update quantity + current_value
    //      - Otherwise: insert (with a retroactive BUY in investment_orders, for consistency)
    //   3. Positions PREVIOUSLY synced but ABSENT from the new result are kept
    //      with a quantity of 0 (the user sold on the external source). They are
    //      not auto-deleted, so order history isn't lost.
    //
    // Returns a text summary ("3 positions updated, 2 new") for display in
    // `last_sync_message`.

    private func persistPositions(
        _ positions: [LiveSyncPosition],
        link: InvestmentLiveSyncLink,
        providerType: InvestmentLiveSyncProvider.Type
    ) throws -> (summary: LocalizedStringResource?, accountId: Int) {
        // 1. Resolve / create the target account
        //
        // A link created from `LiveSyncLinkFormView` already has an `accountId`
        // (the caller's account, or a dedicated one created on the fly), so this
        // path is only taken by links that have none — hence the shared
        // `autoAccountName`, so the two paths never diverge.
        let accountId: Int
        if let existing = link.accountId {
            accountId = existing
        } else {
            let accountName = Self.autoAccountName(
                providerType: providerType, displayName: link.displayName, chain: link.config["chain"]
            )
            let accountType = Self.accountTypeForProvider(providerType.id)
            guard let newAccountId = investmentRepo.addAccountAndGetId(
                name: accountName,
                broker: providerType.displayName,
                currency: "EUR",
                accountType: accountType,
                openedAt: Date()
            ) else {
                throw LiveSyncError.parseError(AppLocalization.string("Impossible de créer le compte de sync."))
            }
            // Attach the live_sync link to the created account for the next sync
            var updated = link
            updated.accountId = newAccountId
            repo.updateLink(updated)
            accountId = newAccountId
        }

        // 2. Upsert the position by ticker.
        //
        // Quantity and average cost are DERIVED from investment_orders. For a
        // position synced from an exchange to show the right quantity and an
        // approximate average cost, a synthetic BUY order must be created with the
        // position. Without it → qty = 0 / average cost = 0 at fetch time.
        //
        // Strategy:
        // - INSERT: creates an empty position + 1 synthetic BUY with qty = snapshot,
        //   unit_price = currentValue/qty (an approximation for lack of anything
        //   better — exchanges don't supply the historical average cost).
        // - UPDATE: ONLY current_value is touched. The quantity isn't resynced from
        //   the exchange, because that would require wiping user-entered orders. A
        //   user who wants an exact quantity adds the BUY/SELL deltas manually.
        // - DISAPPEARED: just current_value = 0; order history is kept.
        let existingPositions = investmentRepo.fetchPositions(accountId: accountId)
        var updatedCount = 0
        var insertedCount = 0

        for pos in positions {
            // Match by ticker (case-insensitive) on this account
            if let existing = existingPositions.first(where: { $0.ticker.uppercased() == pos.ticker.uppercased() }) {
                // UPDATE: market value only (qty/average cost derived from orders)
                var copy = existing
                copy.currentValue = pos.currentValueEUR ?? 0
                _ = investmentRepo.updatePosition(copy)
                updatedCount += 1
            } else {
                // INSERT: position + synthetic BUY order to materialize the qty/average cost
                // at fetch time.
                let unitPrice = (pos.currentValueEUR ?? 0) > 0 && pos.quantity > 0
                    ? (pos.currentValueEUR ?? 0) / pos.quantity
                    : 0
                if let newPosId = investmentRepo.addPositionAndGetId(
                    accountId: accountId,
                    assetType: pos.assetType.uppercased(),
                    assetName: pos.assetName,
                    ticker: pos.ticker,
                    purchaseDate: Date()
                ) {
                    // Also updates the brand-new row's current_value.
                    var fresh = InvestmentPosition(
                        id: newPosId, accountId: accountId,
                        assetType: pos.assetType.uppercased(),
                        assetName: pos.assetName, ticker: pos.ticker,
                        quantity: 0, averageBuyPrice: 0,
                        currentValue: pos.currentValueEUR ?? 0,
                        purchaseDate: Date()
                    )
                    _ = investmentRepo.updatePosition(fresh)
                    // Synthetic BUY order
                    let snapshot = InvestmentOrder(
                        id: 0, positionId: newPosId,
                        orderType: .buy,
                        quantity: pos.quantity,
                        unitPrice: unitPrice,
                        fees: 0,
                        executedAt: Date(),
                        notes: "Sync \(providerType.displayName)"
                    )
                    _ = investmentRepo.addOrder(snapshot)
                    insertedCount += 1
                    // Avoids a Swift "fresh never used" warning should the updatePosition be
                    // removed later; here it's used for the value.
                    _ = fresh
                }
            }
        }

        // 3. Reset the market value to 0 for positions gone from the source
        //    (order history is kept — the user can add a SELL delta manually to
        //    record the disposal).
        let newTickers = Set(positions.map { $0.ticker.uppercased() })
        var zeroedCount = 0
        for existing in existingPositions where !newTickers.contains(existing.ticker.uppercased()) && existing.currentValue > 0 {
            var copy = existing
            copy.currentValue = 0
            _ = investmentRepo.updatePosition(copy)
            zeroedCount += 1
        }

        var parts: [LocalizedStringResource] = []
        if insertedCount > 0 { parts.append(LocalizedStringResource("+\(insertedCount) nouvelles")) }
        if updatedCount > 0  { parts.append(LocalizedStringResource("\(updatedCount) maj")) }
        if zeroedCount > 0   { parts.append(LocalizedStringResource("\(zeroedCount) à zéro")) }
        return (Self.joinLocalized(parts, separator: ", "), accountId)
    }

    /// Determines the account type to create for the provider (for display).
    /// `nonisolated` + non-`private`: called both here (deferred sync, link
    /// without an accountId) and by `LiveSyncLinkFormView.save()` (direct
    /// creation, outside this actor) — a pure function, no reason to isolate it
    /// on the MainActor.
    nonisolated static func accountTypeForProvider(_ providerId: String) -> String {
        switch providerId {
        case "binance":         return "CRYPTO_EXCHANGE"
        case "evm_wallet":      return "CRYPTO_WALLET"
        case "bitcoin_wallet":  return "CRYPTO_WALLET"
        case "solana_wallet":   return "CRYPTO_WALLET"
        default:                return "CRYPTO"
        }
    }

    /// Auto-generated name for a LiveSync link's account — SINGLE SOURCE, used
    /// both by direct creation (`LiveSyncLinkFormView.save()`, account assigned
    /// immediately) and by the deferred fallback above (`persistPositions`).
    /// Centralized so the two paths never silently diverge.
    nonisolated static func autoAccountName(
        providerType: InvestmentLiveSyncProvider.Type, displayName: String, chain: String?
    ) -> String {
        let nameSuffix = displayName.isEmpty ? providerType.displayName : displayName
        let chainHint = chain.map { " (\($0.capitalized))" } ?? ""
        return "\(providerType.displayName)\(chainHint) — \(nameSuffix)"
    }

    // MARK: - Persisting transactions to investment_orders
    //
    // Strategy:
    //   1. For each LiveSyncTransaction → find the matching position on the
    //      link's account (match by ticker, case-insensitive)
    //   2. If the position doesn't exist → skip silently (the user hasn't synced
    //      positions, or the ticker doesn't match a known asset)
    //   3. Dedup: check whether an order with this `externalId` already exists
    //   4. Otherwise INSERT (INSERT OR IGNORE on the UNIQUE INDEX as a backstop)
    //
    // No manual recompute needed: qty/average cost are computed on the fly by
    // `fetchPositions` via JOIN + GROUP BY.

    private func persistTransactions(
        _ transactions: [LiveSyncTransaction],
        link: InvestmentLiveSyncLink
    ) -> LocalizedStringResource? {
        guard let accountId = link.accountId else { return nil }
        let positions = investmentRepo.fetchPositions(accountId: accountId)

        // Index by ticker (case-insensitive) for O(1) lookup
        let positionByTicker = Dictionary(
            uniqueKeysWithValues: positions.map { ($0.ticker.uppercased(), $0) }
        )

        var insertedCount = 0
        var skippedNoPositionCount = 0
        var skippedDupCount = 0
        // Positions that received at least 1 real trade — to clean their synthetic
        // orders after insertion (otherwise qty and average cost are doubled).
        var positionsWithRealTrades: Set<Int> = []

        for tx in transactions {
            // 1. Find the position
            guard let position = positionByTicker[tx.assetTicker.uppercased()] else {
                skippedNoPositionCount += 1
                continue
            }

            // 2. Dedup via external_id
            if investmentRepo.orderExistsWithExternalId(tx.externalId) {
                skippedDupCount += 1
                continue
            }

            // 3. INSERT (INSERT OR IGNORE as a backstop if the dedup races)
            let order = InvestmentOrder(
                id: 0,
                positionId: position.id,
                orderType: tx.orderType,
                quantity: tx.quantity,
                unitPrice: tx.unitPriceEUR ?? 0,
                fees: tx.fees,
                executedAt: tx.executedAt,
                notes: tx.notes,
                externalId: tx.externalId
            )
            if investmentRepo.addOrder(order) {
                insertedCount += 1
                positionsWithRealTrades.insert(position.id)
            }
        }

        // 4. Cleanup: for each position that received real trades, delete the
        //    synthetic orders created by persistPositions (otherwise qty =
        //    synthetic + sum of trades = doubled). Positions that received nothing
        //    (wallets, pairs without history) keep their synthetic order so the
        //    quantity stays materialized.
        var deletedSynthetics = 0
        for positionId in positionsWithRealTrades {
            deletedSynthetics += investmentRepo.deleteSyntheticOrders(positionId: positionId)
        }

        var parts: [LocalizedStringResource] = []
        if insertedCount > 0 { parts.append(LocalizedStringResource("+\(insertedCount) trades")) }
        if skippedDupCount > 0 { parts.append(LocalizedStringResource("\(skippedDupCount) déjà connus")) }
        if deletedSynthetics > 0 { parts.append(LocalizedStringResource("-\(deletedSynthetics) snapshot")) }
        // skippedNoPositionCount isn't displayed (needlessly verbose — the user just
        // wants to know whether the sync worked). The counter is kept for debugging.
        return Self.joinLocalized(parts, separator: ", ")
    }

    /// `LocalizedStringResource` has no `.joined()` — manual fold by nesting
    /// (supported, see `AppLocalization`), which keeps each fragment's key +
    /// arguments instead of freezing resolved text. `nil` if `parts` is empty.
    private static func joinLocalized(_ parts: [LocalizedStringResource], separator: String) -> LocalizedStringResource? {
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { acc, part in
            LocalizedStringResource("\(acc)\(separator)\(part)")
        }
    }
}

// MARK: - Identifiable wrapper for metatypes (used by SwiftUI ForEach)

/// Wraps an `InvestmentLiveSyncProvider.Type` metatype in an
/// `Identifiable + Hashable` struct so it can be used in `ForEach`.
struct LiveSyncProviderEntry: Identifiable, Hashable, Sendable {
    let providerType: InvestmentLiveSyncProvider.Type

    init(_ providerType: InvestmentLiveSyncProvider.Type) {
        self.providerType = providerType
    }

    var id: String { providerType.id }
    var displayName: String { providerType.displayName }
    var iconName: String { providerType.iconName }
    var description: String { providerType.description }

    static func == (lhs: LiveSyncProviderEntry, rhs: LiveSyncProviderEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Provider declarations
//
// Each provider's public interface: static metadata here, network methods
// in an extension under `Providers/`.

// MARK: Binance

// Static metadata only — the instance methods (validate, fetchPositions,
// fetchTransactions) are implemented in
// `Providers/Binance/BinanceLiveSyncProvider.swift` via an extension.
struct BinanceLiveSyncProvider: InvestmentLiveSyncProvider {
    static let id = "binance"
    static let displayName = "Binance"
    static let iconName = "bitcoinsign.circle.fill"
    static let description = "Centralized exchange — synchronise vos holdings spot et l'historique des trades."
    static let supportsChainSelection = false
    static let supportedChains: [LiveSyncChainOption] = []

    static let credentialFields: [LiveSyncCredentialField] = [
        LiveSyncCredentialField(
            key: "apiKey",
            label: "Clé API",
            isSecret: true,
            placeholder: "Clé read-only générée dans votre compte Binance",
            helpText: "Créez une clé read-only dans Profil → API Management. N'activez PAS les permissions de trading ni de retrait.",
            validation: .minLength(40)
        ),
        LiveSyncCredentialField(
            key: "apiSecret",
            label: "Secret API",
            isSecret: true,
            placeholder: "Secret associé à la clé",
            helpText: nil,
            validation: .minLength(40)
        )
    ]

    init() {}
}

// MARK: EVM wallet (generic, multi-chain)

// Static metadata only — instance methods implemented in
// `Providers/EVM/EvmWalletLiveSyncProvider.swift` (extension).
struct EvmWalletLiveSyncProvider: InvestmentLiveSyncProvider {
    static let id = "evm_wallet"
    static let displayName = "Wallet EVM"
    static let iconName = "link.circle.fill"
    static let description = "Wallets sur Ethereum, Polygon, BSC, Arbitrum, Optimism, Base. Adresse publique uniquement (read-only)."
    static let supportsChainSelection = true

    /// 6 major EVM chains supported via the Etherscan V2 Multichain API (one key for all).
    static let supportedChains: [LiveSyncChainOption] = [
        LiveSyncChainOption(id: "eth",       displayName: "Ethereum",  icon: "e.circle.fill",      nativeCurrency: "ETH",   chainIdHex: "0x1"),
        LiveSyncChainOption(id: "polygon",   displayName: "Polygon",   icon: "p.circle.fill",      nativeCurrency: "MATIC", chainIdHex: "0x89"),
        LiveSyncChainOption(id: "bsc",       displayName: "BNB Chain", icon: "b.circle.fill",      nativeCurrency: "BNB",   chainIdHex: "0x38"),
        LiveSyncChainOption(id: "arbitrum",  displayName: "Arbitrum",  icon: "a.circle.fill",      nativeCurrency: "ETH",   chainIdHex: "0xa4b1"),
        LiveSyncChainOption(id: "optimism",  displayName: "Optimism",  icon: "o.circle.fill",      nativeCurrency: "ETH",   chainIdHex: "0xa"),
        LiveSyncChainOption(id: "base",      displayName: "Base",      icon: "circle.hexagonpath", nativeCurrency: "ETH",   chainIdHex: "0x2105")
    ]

    static let credentialFields: [LiveSyncCredentialField] = [
        LiveSyncCredentialField(
            key: "address",
            label: "Adresse publique",
            isSecret: false,
            placeholder: "0x...",
            helpText: "Adresse publique du wallet (commence par 0x). Aucune clé privée n'est demandée — read-only via blockchain explorer.",
            validation: .hexAddress
        ),
        LiveSyncCredentialField(
            key: "etherscanApiKey",
            label: "Clé API Etherscan V2",
            isSecret: true,
            placeholder: "Clé générée sur etherscan.io/apis",
            // Required (`.nonEmpty`): Etherscan V2 no longer serves the
            // account/balance module anonymously — without a key the API returns
            // `result: "Missing/Invalid API Key"` instead of a balance, and
            // `EvmAPIClient.fetchNativeBalance` fails to parse it. Making it required
            // avoids creating a link doomed to fail.
            helpText: "Obligatoire depuis Etherscan V2 (l'accès sans clé a été retiré). Créez une clé gratuite sur etherscan.io/apis — elle fonctionne sur les 6 chaînes EVM.",
            validation: .nonEmpty
        )
    ]

    init() {}
}

// MARK: Bitcoin Wallet

// Static metadata only — instance methods implemented in
// `Providers/Bitcoin/BitcoinWalletLiveSyncProvider.swift` (extension).
struct BitcoinWalletLiveSyncProvider: InvestmentLiveSyncProvider {
    static let id = "bitcoin_wallet"
    static let displayName = "Wallet Bitcoin"
    static let iconName = "bitcoinsign.circle"
    static let description = "Wallet Bitcoin natif — adresse publique uniquement (read-only via Blockstream)."
    static let supportsChainSelection = false
    static let supportedChains: [LiveSyncChainOption] = []

    static let credentialFields: [LiveSyncCredentialField] = [
        LiveSyncCredentialField(
            key: "address",
            label: "Adresse Bitcoin",
            isSecret: false,
            placeholder: "bc1... ou 1... ou 3...",
            helpText: "Adresse publique Bitcoin (SegWit recommandé, format bc1). Aucune clé privée n'est demandée.",
            validation: .bitcoinAddress
        )
    ]

    init() {}
}

// MARK: Solana Wallet

// Static metadata only — instance methods implemented in
// `Providers/Solana/SolanaWalletLiveSyncProvider.swift` (extension).
struct SolanaWalletLiveSyncProvider: InvestmentLiveSyncProvider {
    static let id = "solana_wallet"
    static let displayName = "Wallet Solana"
    static let iconName = "s.circle.fill"
    static let description = "Wallet Solana — adresse publique uniquement, sync SOL + tokens SPL via RPC public."
    static let supportsChainSelection = false
    static let supportedChains: [LiveSyncChainOption] = []

    static let credentialFields: [LiveSyncCredentialField] = [
        LiveSyncCredentialField(
            key: "address",
            label: "Adresse Solana",
            isSecret: false,
            placeholder: "Adresse base58 (32-44 chars)",
            helpText: "Adresse publique Solana. Permet de tracker SOL natif + tous les tokens SPL associés (USDC, USDT, BONK, etc.).",
            validation: .solanaAddress
        )
    ]

    init() {}
}
