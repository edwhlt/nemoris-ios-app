import Foundation

// MARK: - Registry orchestrateur des providers
//
// Point d'entrée unique pour :
//   - lister les providers disponibles (catalogue à montrer dans l'UI d'ajout)
//   - dispatcher un sync vers le bon provider d'un lien
//   - persister le résultat (positions + transactions) dans le schéma investments
//
// Cette session livre l'infra. Les 4 providers (Binance/EVM/BTC/SOL) sont des STUBS :
//   - leurs métadonnées (id, displayName, icon, fields) sont définies
//   - leurs méthodes `validate/fetchPositions/fetchTransactions` throw
//     `LiveSyncError.providerNotImplemented`
// Les implémentations réelles arriveront dans les Couches 1-3.

@MainActor
final class LiveSyncRegistry {

    static let shared = LiveSyncRegistry()
    private init() {}

    private let repo = LiveSyncRepository.shared
    private let credentialStore = InvestmentCredentialStore.shared
    private let investmentRepo = InvestmentRepository()

    // MARK: - Catalogue providers disponibles

    /// Liste des providers connus de l'app, wrappés dans `LiveSyncProviderEntry`
    /// pour être `Identifiable` (les metatypes ne le sont pas directement).
    static let availableProviders: [LiveSyncProviderEntry] = [
        LiveSyncProviderEntry(BinanceLiveSyncProvider.self),
        LiveSyncProviderEntry(EvmWalletLiveSyncProvider.self),
        LiveSyncProviderEntry(BitcoinWalletLiveSyncProvider.self),
        LiveSyncProviderEntry(SolanaWalletLiveSyncProvider.self)
    ]

    /// Résout un provider par son ID (cf. `InvestmentLiveSyncProvider.id`).
    /// Retourne nil si l'ID est inconnu.
    static func provider(for id: String) -> InvestmentLiveSyncProvider.Type? {
        availableProviders.first(where: { $0.id == id })?.providerType
    }

    // MARK: - Sync orchestration

    /// Lance la sync d'un lien spécifique. Met à jour `last_sync_*` après exécution.
    /// Retourne nil si succès, sinon le message d'erreur user-friendly.
    ///
    /// ⚠️ Renvoie une `String` (pas un `LocalizedStringResource`) : ce retour
    /// n'est utilisé QUE pour un toast affiché immédiatement (même passe de
    /// rendu, donc déjà dans la bonne langue — pas de risque de figer une
    /// traduction). `repo.updateSyncStatus`, lui, PERSISTE le message —
    /// c'est CE chemin qui doit rester un `LocalizedStringResource`.
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

        // Marquer pending avant l'appel (utile pour l'UI loader)
        repo.updateSyncStatus(linkId: link.id, status: .pending, message: nil, syncedAt: link.lastSyncAt ?? Date())

        let providerInstance = providerType.init()
        do {
            // Couche 1-3 : fetch les positions réelles
            let positions = try await providerInstance.fetchPositions(credentials: creds, config: link.config)
            // persistance vers investment_positions.
            // Retourne aussi l'accountId effectif (résolu OU créé par persistPositions)
            // pour le réinjecter dans persistTransactions ci-dessous — sans ça,
            // sur la première sync où le compte est auto-créé, link.accountId
            // reste nil localement et persistTransactions return early en
            // sautant tous les trades.
            let (positionsSummary, resolvedAccountId) = try persistPositions(
                positions, link: link, providerType: providerType
            )
            // Reconstruit un link avec l'accountId à jour pour les étapes suivantes
            var linkWithAccount = link
            linkWithAccount.accountId = resolvedAccountId

            // fetch + persist des transactions/trades.
            // Seulement si le provider supporte (Binance pour l'instant — les wallets
            // blockchain renvoient toujours [] car leurs fetchTransactions sont stubs).
            // Les transactions persistent dans investment_orders avec external_id pour dédup.
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

    /// Lance la sync de tous les liens activés. Séquentiel pour respecter les rate limits
    /// CoinGecko/Etherscan (pas de bursts). Retourne un statut par lien (error = nil
    /// si succès) pour que l'appelant (InvestmentAutoSyncService) bâtisse son résumé.
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

    // MARK: - Persistance vers investment_positions
    //
    // Stratégie :
    //   1. Si `link.accountId` est nil → on crée un nouveau `investment_account` auto
    //      avec un nom dérivé du provider (ex: "Binance — perso", "Wallet ETH").
    //   2. Pour chaque LiveSyncPosition retournée par le provider :
    //      - On cherche une position existante (account + ticker) dans investment_positions
    //      - Si trouvée : on update quantity + current_value
    //      - Sinon : on insère (crée un BUY rétroactif via investment_orders pour cohérence)
    //   3. Les positions PRÉCÉDEMMENT syncées mais ABSENTES du nouveau résultat sont
    //      conservées avec leur quantity à 0 (l'utilisateur a vendu sur la source externe).
    //      Note : on n'auto-delete pas pour ne pas perdre l'historique d'ordres.
    //
    // Retourne un résumé textuel ("3 positions mises à jour, 2 nouvelles") pour
    // affichage dans `last_sync_message`.

    private func persistPositions(
        _ positions: [LiveSyncPosition],
        link: InvestmentLiveSyncLink,
        providerType: InvestmentLiveSyncProvider.Type
    ) throws -> (summary: LocalizedStringResource?, accountId: Int) {
        // 1. Résoudre / créer le compte cible
        //
        // ⚠️ Ce chemin ne devrait normalement plus JAMAIS s'emprunter pour un
        // lien créé depuis `LiveSyncLinkFormView` : celui-ci
        // assigne désormais un `accountId` dès la création (compte fourni par
        // l'appelant ou compte dédié créé à la volée), donc `link.accountId`
        // est déjà non-nil au premier sync. Ce repli reste nécessaire pour les
        // liens créés AVANT ce chantier (bases existantes, pas de migration
        // possible sur une donnée Keychain/hors-schéma) — cf. `autoAccountName`
        // partagée pour que les deux chemins ne divergent jamais.
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
            // Lier le live_sync au compte créé pour la prochaine sync
            var updated = link
            updated.accountId = newAccountId
            repo.updateLink(updated)
            accountId = newAccountId
        }

        // 2. Upsert position par ticker.
        //
        // Depuis la migration v30, qty et PRU sont DÉRIVÉS des investment_orders.
        // Pour qu'une position synchronisée depuis un exchange montre la bonne
        // quantité et un PRU approximé, on doit créer un ordre BUY synthétique
        // à la création de la position. Sans ça → qty = 0 / PRU = 0 au fetch.
        //
        // Stratégie :
        // - INSERT : crée position vide + 1 BUY synthétique qty = snapshot,
        //   unit_price = currentValue/qty (approximation faute de mieux —
        //   les exchanges ne fournissent pas le PRU historique).
        // - UPDATE : on ne touche QUE current_value. On ne re-synchronise pas
        //   la qty depuis l'exchange parce que ça nécessiterait de wiper
        //   les ordres user-saisis. Acceptable pour MVP : l'utilisateur qui veut une
        //   qty exacte ajoute manuellement les BUY/SELL delta après chaque sync.
        // - DISAPPEARED : juste current_value = 0, on garde l'historique d'ordres.
        let existingPositions = investmentRepo.fetchPositions(accountId: accountId)
        var updatedCount = 0
        var insertedCount = 0

        for pos in positions {
            // Match par ticker (case insensitive) sur ce compte
            if let existing = existingPositions.first(where: { $0.ticker.uppercased() == pos.ticker.uppercased() }) {
                // UPDATE : valeur marché seulement (qty/PRU dérivés des ordres)
                var copy = existing
                copy.currentValue = pos.currentValueEUR ?? 0
                _ = investmentRepo.updatePosition(copy)
                updatedCount += 1
            } else {
                // INSERT : position + ordre BUY synthétique pour matérialiser
                // la qty/PRU au fetch.
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
                    // Met aussi à jour current_value du tout nouvel enreg.
                    var fresh = InvestmentPosition(
                        id: newPosId, accountId: accountId,
                        assetType: pos.assetType.uppercased(),
                        assetName: pos.assetName, ticker: pos.ticker,
                        quantity: 0, averageBuyPrice: 0,
                        currentValue: pos.currentValueEUR ?? 0,
                        purchaseDate: Date()
                    )
                    _ = investmentRepo.updatePosition(fresh)
                    // Ordre BUY synthétique
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
                    // Empêche un warning Swift "fresh never used" si on supprime
                    // l'updatePosition plus tard ; ici c'est utile pour la value.
                    _ = fresh
                }
            }
        }

        // 3. Reset valeur marché à 0 pour positions disparues côté source
        //    (l'historique d'ordres est conservé — l'utilisateur peut ajouter un SELL
        //    delta manuellement s'il veut tracer la cession).
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

    /// Détermine le type de compte à créer selon le provider (pour affichage user).
    /// `nonisolated` + non-`private` : appelée aussi bien ici (sync différée,
    /// lien pré-2026-08-08 sans accountId) que par `LiveSyncLinkFormView.save()`
    /// (création directe, hors de cet acteur) — fonction pure, aucune raison
    /// de l'isoler sur MainActor.
    nonisolated static func accountTypeForProvider(_ providerId: String) -> String {
        switch providerId {
        case "binance":         return "CRYPTO_EXCHANGE"
        case "evm_wallet":      return "CRYPTO_WALLET"
        case "bitcoin_wallet":  return "CRYPTO_WALLET"
        case "solana_wallet":   return "CRYPTO_WALLET"
        default:                return "CRYPTO"
        }
    }

    /// Nom auto-généré pour le compte d'un lien LiveSync — SOURCE UNIQUE,
    /// utilisée à la fois par la création directe (`LiveSyncLinkFormView.save()`,
    /// compte assigné immédiatement) et par le repli différé ci-dessus
    /// (`persistPositions`, liens créés avant ce chantier). Centralisée pour
    /// que les deux chemins ne divergent jamais silencieusement.
    nonisolated static func autoAccountName(
        providerType: InvestmentLiveSyncProvider.Type, displayName: String, chain: String?
    ) -> String {
        let nameSuffix = displayName.isEmpty ? providerType.displayName : displayName
        let chainHint = chain.map { " (\($0.capitalized))" } ?? ""
        return "\(providerType.displayName)\(chainHint) — \(nameSuffix)"
    }

    // MARK: - Persistance des transactions vers investment_orders
    //
    // Stratégie :
    //   1. Pour chaque LiveSyncTransaction → on cherche la position correspondante
    //      sur l'account du link (match par ticker, case insensitive)
    //   2. Si la position n'existe pas → on skip silencieusement (l'utilisateur n'a pas
    //      synchronisé les positions, ou le ticker ne match pas un asset connu)
    //   3. Dédup : on vérifie si un ordre avec ce `externalId` existe déjà
    //   4. Sinon INSERT (INSERT OR IGNORE sur UNIQUE INDEX en backup)
    //
    // Pas besoin de recompute manuel : depuis la migration v30, qty/PRU sont
    // calculés à la volée par `fetchPositions` via JOIN+GROUP BY.

    private func persistTransactions(
        _ transactions: [LiveSyncTransaction],
        link: InvestmentLiveSyncLink
    ) -> LocalizedStringResource? {
        guard let accountId = link.accountId else { return nil }
        let positions = investmentRepo.fetchPositions(accountId: accountId)

        // Index par ticker (case insensitive) pour lookup O(1)
        let positionByTicker = Dictionary(
            uniqueKeysWithValues: positions.map { ($0.ticker.uppercased(), $0) }
        )

        var insertedCount = 0
        var skippedNoPositionCount = 0
        var skippedDupCount = 0
        // Positions ayant reçu au moins 1 trade réel — pour nettoyer leurs
        // ordres synthétiques après insertion (sinon qty et PRU sont doublés).
        var positionsWithRealTrades: Set<Int> = []

        for tx in transactions {
            // 1. Trouver la position
            guard let position = positionByTicker[tx.assetTicker.uppercased()] else {
                skippedNoPositionCount += 1
                continue
            }

            // 2. Dédup via external_id
            if investmentRepo.orderExistsWithExternalId(tx.externalId) {
                skippedDupCount += 1
                continue
            }

            // 3. INSERT (INSERT OR IGNORE backstop si la dédup race)
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

        // 4. Nettoyage : pour chaque position qui a reçu des trades réels,
        //    supprimer les ordres synthétiques créés par persistPositions
        //    (sinon qty = synthetic + somme des trades = doublée).
        //    Les positions qui n'ont rien reçu (wallets, paires sans historique)
        //    gardent leur synthetic pour que la qty reste matérialisée.
        var deletedSynthetics = 0
        for positionId in positionsWithRealTrades {
            deletedSynthetics += investmentRepo.deleteSyntheticOrders(positionId: positionId)
        }

        var parts: [LocalizedStringResource] = []
        if insertedCount > 0 { parts.append(LocalizedStringResource("+\(insertedCount) trades")) }
        if skippedDupCount > 0 { parts.append(LocalizedStringResource("\(skippedDupCount) déjà connus")) }
        if deletedSynthetics > 0 { parts.append(LocalizedStringResource("-\(deletedSynthetics) snapshot")) }
        // skippedNoPositionCount n'est pas affiché (verbose pour rien — l'utilisateur veut juste savoir
        // si la sync a marché). On garde le compteur en cas de debug futur.
        return Self.joinLocalized(parts, separator: ", ")
    }

    /// `LocalizedStringResource` n'a pas de `.joined()` — repli manuel par
    /// imbrication (testé, supporté : cf. `AppLocalization`/CLAUDE.md §5), qui
    /// préserve la clé + les arguments de chaque fragment au lieu de figer du
    /// texte résolu. `nil` si `parts` est vide.
    private static func joinLocalized(_ parts: [LocalizedStringResource], separator: String) -> LocalizedStringResource? {
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { acc, part in
            LocalizedStringResource("\(acc)\(separator)\(part)")
        }
    }
}

// MARK: - Wrapper Identifiable pour metatypes (utilisé par les ForEach SwiftUI)

/// Wrappe une métatype `InvestmentLiveSyncProvider.Type` dans une struct
/// `Identifiable + Hashable` pour pouvoir l'utiliser dans `ForEach`.
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

// MARK: - Provider stubs (implémentations Couches 1-3)
//
// Ces stubs définissent l'interface publique de chaque provider mais lèvent
// `LiveSyncError.providerNotImplemented` quand on tente une opération réseau.
// La Couche 0g (UI Settings) peut donc déjà afficher le catalogue, accepter des
// credentials, et créer des liens — sans crash.

// MARK: Binance

// Métadonnées statiques uniquement — les méthodes d'instance (validate, fetchPositions,
// fetchTransactions) sont implémentées dans `Providers/Binance/BinanceLiveSyncProvider.swift`
// via une extension. Couche 1 livrée.
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

// MARK: EVM Wallet (générique multi-chaînes)

// Métadonnées statiques uniquement — méthodes d'instance implémentées dans
// `Providers/EVM/EvmWalletLiveSyncProvider.swift` (extension). Couche 2 livrée.
struct EvmWalletLiveSyncProvider: InvestmentLiveSyncProvider {
    static let id = "evm_wallet"
    static let displayName = "Wallet EVM"
    static let iconName = "link.circle.fill"
    static let description = "Wallets sur Ethereum, Polygon, BSC, Arbitrum, Optimism, Base. Adresse publique uniquement (read-only)."
    static let supportsChainSelection = true

    /// 6 chaînes EVM majeures supportées via Etherscan V2 Multichain API (1 clé optionnelle pour toutes).
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
            // ⚠️ 2026-08-08 : cette clé était documentée "optionnelle" (5 req/s
            // sans clé) au moment où a été livré, mais Etherscan a depuis
            // retiré l'accès anonyme sur le module account/balance de V2 — sans
            // clé, l'API renvoie `result: "Missing/Invalid API Key"` au lieu
            // d'un solde, et `EvmAPIClient.fetchNativeBalance` échoue à parser
            // (constaté en usage réel, pas seulement en doc). Rendue obligatoire
            // (`.nonEmpty`) pour ne plus créer un lien condamné à échouer.
            helpText: "Obligatoire depuis Etherscan V2 (l'accès sans clé a été retiré). Créez une clé gratuite sur etherscan.io/apis — elle fonctionne sur les 6 chaînes EVM.",
            validation: .nonEmpty
        )
    ]

    init() {}
}

// MARK: Bitcoin Wallet

// Métadonnées statiques uniquement — méthodes d'instance implémentées dans
// `Providers/Bitcoin/BitcoinWalletLiveSyncProvider.swift` (extension). Couche 3a livrée.
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

// Métadonnées statiques uniquement — méthodes d'instance implémentées dans
// `Providers/Solana/SolanaWalletLiveSyncProvider.swift` (extension). Couche 3b livrée.
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
