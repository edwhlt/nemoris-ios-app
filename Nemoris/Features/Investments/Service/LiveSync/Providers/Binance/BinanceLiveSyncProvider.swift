import Foundation

// MARK: - AXE I Couche 1b — Provider Binance (impl réelle)
//
// Synchronise les balances spot Binance via l'API officielle :
//   - validate : ping public + fetch account (vérifie les credentials read-only)
//   - fetchPositions : récupère les balances spot, filtre les non-nuls, convertit en EUR
//     via CoinGecko (PriceResolver). Les assets sans prix EUR sont retournés avec
//     `currentValueEUR = nil` (tokens obscurs, choix user décidé en Couche 0).
//   - fetchTransactions : stub pour cette Couche 1 (besoin de itérer myTrades par symbol,
//     gestion rate limit complexe → reporté à une Couche 1.5)
//
// La déclaration des métadonnées statiques (id, displayName, credentialFields…) reste
// dans `LiveSyncRegistry.swift` (struct stub) pour éviter de devoir déplacer 4 fichiers
// à chaque ajout — c'est l'extension qui apporte l'implémentation réelle ici.

extension BinanceLiveSyncProvider {

    func validate(credentials: [String: String], config: [String: String]) async throws {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        // Ping public d'abord pour discriminer rapidement "réseau ko" vs "credentials ko"
        try await client.ping()
        // Puis fetch account avec les credentials — n'expose aucun état ni mutation
        _ = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        let account = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)

        // Filtrer les balances non-nuls (Binance renvoie ~400 assets dont 95% à 0)
        let nonZero = account.balances.filter { $0.total > 0 }
        guard !nonZero.isEmpty else { return [] }

        // Récupérer les prix EUR pour TOUS les tickers en 1 req CoinGecko (multi-IDs)
        let tickers = nonZero.map { $0.asset }
        let prices = await PriceResolver.shared.resolveNativePrices(tickers: tickers)

        return nonZero.map { balance -> LiveSyncPosition in
            let ticker = balance.asset
            let priceEUR = prices[ticker]
            let qty = balance.total
            let valueEUR: Double? = priceEUR.map { $0 * qty }
            return LiveSyncPosition(
                assetType: "crypto",
                assetName: Self.assetDisplayName(for: ticker),
                ticker: ticker,
                quantity: qty,
                currentValueEUR: valueEUR,
                metadata: ["exchange": "binance"]
            )
        }
        // Tri : valeur EUR décroissante, puis quantité décroissante pour les tokens sans prix
        .sorted { lhs, rhs in
            switch (lhs.currentValueEUR, rhs.currentValueEUR) {
            case let (l?, r?):  return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.quantity > rhs.quantity
            }
        }
    }

    /// Sync l'historique des trades Binance.
    ///
    /// Stratégie pour éviter de spam Binance :
    ///   1. Fetch les balances actuelles → liste des assets détenus
    ///   2. Filter les assets qui ne sont pas des stables/quote (USDT, USDC, BUSD, DAI)
    ///   3. Pour chaque asset, tente la paire `<ASSET>USDT` (la + courante chez Binance)
    ///   4. Sleep 100ms entre requêtes pour rester confortablement sous 1200 weight/min
    ///   5. Cap à 25 paires pour éviter les wallets > 25 holdings différents
    ///
    /// Conversion EUR : on récupère le taux USDT/EUR courant via CoinGecko (1 req)
    /// et on l'applique uniformément à tous les trades. C'est une APPROXIMATION
    /// (le vrai taux USDT/EUR au jour J est différent), mais acceptable pour le suivi
    /// perso. Pour le calcul de PRU précis, l'utilisateur peut éditer les unitPrice manuellement.
    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction] {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        let account = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)

        // Filtrer les assets qui méritent un fetch de trades (cap 25)
        let stableTickers: Set<String> = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD"]
        let candidates = account.balances
            .filter { $0.total > 0 && !stableTickers.contains($0.asset.uppercased()) && $0.asset != "BNB" }
            .prefix(25)
            .map { $0.asset.uppercased() }

        guard !candidates.isEmpty else { return [] }

        // Récupérer le taux USDT/EUR pour conversion. CoinGecko renvoie USDT à ~0.92€
        // (varie autour de 1$, donc autour de 0.92-0.95€ selon EUR/USD).
        let usdtPrices = await PriceResolver.shared.resolveNativePrices(tickers: ["USDT"])
        let usdtEUR = usdtPrices["USDT"] ?? 0.92  // fallback si CoinGecko HS

        // Fetch trades pour chaque asset sur la paire ASSETUSDT
        var allTransactions: [LiveSyncTransaction] = []
        for asset in candidates {
            let symbol = "\(asset)USDT"
            do {
                let trades = try await client.fetchMyTrades(
                    symbol: symbol,
                    limit: 500,  // 500 = derniers trades sur cette paire
                    apiKey: apiKey,
                    apiSecret: apiSecret
                )
                for trade in trades {
                    // Filter par `since` si fourni (sync incrémentale futur)
                    if let since, trade.executedAt < since { continue }

                    // Frais : en BNB ou USDT généralement. Converti en EUR si on a le taux.
                    // Pour MVP, on stocke les frais bruts (en commissionAsset) sans conversion.
                    // L'utilisateur peut les recalculer manuellement si besoin précis.
                    let feesEUR: Double = {
                        if trade.commissionAsset.uppercased() == "BNB" {
                            return 0  // Sans conversion BNB/EUR ici, on met 0 pour éviter de fausser
                        }
                        if trade.commissionAsset.uppercased() == "USDT" {
                            return trade.commissionDouble * usdtEUR
                        }
                        // Si frais dans l'asset acheté (cas rare), pas converti
                        return 0
                    }()

                    let priceEUR = trade.priceDouble * usdtEUR
                    let externalId = "binance_\(symbol)_\(trade.id)"

                    allTransactions.append(LiveSyncTransaction(
                        externalId: externalId,
                        orderType: trade.isBuyer ? .buy : .sell,
                        assetTicker: asset,
                        quantity: trade.qtyDouble,
                        unitPriceEUR: priceEUR,
                        fees: feesEUR,
                        executedAt: trade.executedAt,
                        notes: "Binance \(symbol) · cours \(String(format: "%.4f", trade.priceDouble)) USDT"
                    ))
                }
            } catch {
                // Skip silencieusement les paires en erreur (rate limit, paire inexistante…)
                // pour ne pas faire échouer toute la sync sur une seule paire problématique.
                continue
            }

            // Sleep entre requêtes pour rester sous le rate limit (1200 weight/min ÷ 10 weight/req
            // = 120 req/min = 1 req toutes les 500ms). On prend 100ms = 600 req/min en théorie
            // mais avec la latence réseau on reste largement safe.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return allTransactions
    }

    // MARK: - Helpers

    /// Mapping ticker → nom complet pour un affichage user-friendly.
    /// Fallback = le ticker lui-même si pas dans la table.
    static func assetDisplayName(for ticker: String) -> String {
        nameTable[ticker.uppercased()] ?? ticker.uppercased()
    }

    /// Noms complets des cryptos les plus courantes sur Binance.
    /// Liste volontairement courte — pour les autres on affiche le ticker.
    private static let nameTable: [String: String] = [
        "BTC": "Bitcoin",
        "ETH": "Ethereum",
        "BNB": "BNB",
        "SOL": "Solana",
        "USDT": "Tether",
        "USDC": "USD Coin",
        "BUSD": "Binance USD",
        "DAI": "Dai",
        "XRP": "XRP",
        "ADA": "Cardano",
        "DOGE": "Dogecoin",
        "TRX": "Tron",
        "AVAX": "Avalanche",
        "DOT": "Polkadot",
        "MATIC": "Polygon",
        "LINK": "Chainlink",
        "LTC": "Litecoin",
        "BCH": "Bitcoin Cash",
        "ATOM": "Cosmos",
        "NEAR": "NEAR Protocol",
        "FTM": "Fantom",
        "OP": "Optimism",
        "ARB": "Arbitrum",
        "UNI": "Uniswap",
        "AAVE": "Aave",
        "SHIB": "Shiba Inu",
        "PEPE": "Pepe",
        "ALGO": "Algorand",
        "ETC": "Ethereum Classic",
        "FIL": "Filecoin",
        "SAND": "The Sandbox",
        "MANA": "Decentraland",
        "AXS": "Axie Infinity"
    ]
}
