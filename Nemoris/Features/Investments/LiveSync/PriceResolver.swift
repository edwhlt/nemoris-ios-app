import Foundation

// MARK: - AXE I Couche 0e — Résolution des prix EUR via CoinGecko
//
// Tous les providers crypto (Binance, EVM, BTC, SOL) utilisent ce service pour
// convertir des holdings (BTC, ETH, USDC, etc.) en valeur EUR pour le portfolio.
//
// Stratégie :
//   - CoinGecko free API : 50 req/min sans clé (largement suffisant pour usage perso)
//   - 2 modes de lookup :
//       * `/simple/price` par symbol/coin_id (ex: "bitcoin", "ethereum") — pour natifs
//       * `/simple/token_price/<chain>` par contract address — pour ERC-20/BEP-20/SPL
//   - Cache RAM 10 min : on suppose que pour usage perso, refresh par sync manuel suffit
//   - Tokens sans prix CoinGecko → renvoyés avec value nil, traités par UI comme
//     "Valeur indisponible" (cf. décision user)
//
// Privacy : appels directs à api.coingecko.com depuis le device. Aucun proxy serveur.

actor PriceResolver {

    static let shared = PriceResolver()
    private init() {}

    /// TTL du cache RAM en secondes. 10 min = trade-off entre coût réseau et fraîcheur.
    private let cacheTTL: TimeInterval = 600

    /// Cache : clé = "<lookupType>:<key>", valeur = (prix EUR, date fetch)
    /// Ex : "coin:bitcoin" → 95000.0, ou "token:ethereum:0xa0b8..." → 0.9998
    private var cache: [String: (price: Double, fetchedAt: Date)] = [:]

    // MARK: - Mapping tickers → CoinGecko coin IDs (natifs majeurs)
    //
    // CoinGecko utilise des slugs ("bitcoin") au lieu des tickers ("BTC"). On a un
    // mapping en dur pour les natifs les plus courants. Les tokens ERC-20/SPL passent
    // par le lookup par contract address (plus précis).

    private static let nativeCoinIDs: [String: String] = [
        // Majeurs
        "BTC": "bitcoin",
        "ETH": "ethereum",
        "SOL": "solana",
        "BNB": "binancecoin",
        "MATIC": "matic-network",
        "AVAX": "avalanche-2",
        "ADA": "cardano",
        "DOT": "polkadot",
        "XRP": "ripple",
        "DOGE": "dogecoin",
        "TRX": "tron",
        "LTC": "litecoin",
        "BCH": "bitcoin-cash",
        "LINK": "chainlink",
        "ATOM": "cosmos",
        "ALGO": "algorand",
        "NEAR": "near",
        "FTM": "fantom",
        "OP": "optimism",
        "ARB": "arbitrum",
        // Stablecoins (mais on les fetche aussi pour précision micro-écarts ~$0.998-1.002)
        "USDT": "tether",
        "USDC": "usd-coin",
        "DAI": "dai",
        "BUSD": "binance-usd",
        "TUSD": "true-usd",
        // Memes & autres populaires
        "SHIB": "shiba-inu",
        "PEPE": "pepe",
        "UNI": "uniswap",
        "AAVE": "aave",
        "CRV": "curve-dao-token",
        "MKR": "maker",
        "SNX": "synthetix-network-token",
        // AI / autres tokens populaires
        "FET": "fetch-ai",
        "AGIX": "singularitynet",
        "OCEAN": "ocean-protocol",
        "RNDR": "render-token",
        "GRT": "the-graph",
        "JTO": "jito-governance-token",
        "JUP": "jupiter-exchange-solana",
        "PYTH": "pyth-network",
        "WIF": "dogwifcoin",
        "BONK": "bonk",
        "INJ": "injective-protocol",
        "TIA": "celestia",
        "SUI": "sui",
        "APT": "aptos",
        "SEI": "sei-network"
    ]

    /// Résout le ticker (ex: "BTC", "FET") en coinId CoinGecko (ex: "bitcoin",
    /// "fetch-ai"). Renvoie nil si le ticker n'est pas une crypto connue —
    /// dans ce cas la sync de cours doit passer par Yahoo, pas CoinGecko.
    static func coinId(forTicker ticker: String) -> String? {
        nativeCoinIDs[ticker.uppercased()]
    }

    /// CoinGecko "platform" IDs pour le lookup par contract address.
    /// Référence : https://api.coingecko.com/api/v3/asset_platforms
    private static let platformIDs: [String: String] = [
        "eth":       "ethereum",
        "polygon":   "polygon-pos",
        "bsc":       "binance-smart-chain",
        "arbitrum":  "arbitrum-one",
        "optimism":  "optimistic-ethereum",
        "base":      "base",
        "avalanche": "avalanche",
        "solana":    "solana"
    ]

    // MARK: - Public API

    /// Résout les prix EUR pour une liste de tickers natifs (BTC, ETH, SOL, USDC...).
    /// Retourne un dictionnaire ticker → prix EUR (manque les tickers inconnus).
    func resolveNativePrices(tickers: [String]) async -> [String: Double] {
        let upperTickers = Set(tickers.map { $0.uppercased() })
        var result: [String: Double] = [:]

        // Étape 1 : remplir depuis le cache
        var toFetch: [String] = []
        for ticker in upperTickers {
            guard let coinId = Self.nativeCoinIDs[ticker] else { continue }
            let cacheKey = "coin:\(coinId)"
            if let cached = cache[cacheKey], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
                result[ticker] = cached.price
            } else {
                toFetch.append(coinId)
            }
        }
        guard !toFetch.isEmpty else { return result }

        // Étape 2 : fetch les manquants en 1 seule requête CoinGecko (multi-IDs)
        let idsCSV = toFetch.joined(separator: ",")
        let urlString = "https://api.coingecko.com/api/v3/simple/price?ids=\(idsCSV)&vs_currencies=eur"
        guard let url = URL(string: urlString),
              let prices = try? await fetchSimplePriceResponse(url: url) else {
            return result
        }
        let now = Date()
        for (coinId, eurPrice) in prices {
            let cacheKey = "coin:\(coinId)"
            cache[cacheKey] = (eurPrice, now)
            // Map inverse coinId → ticker pour remplir le result
            if let ticker = Self.nativeCoinIDs.first(where: { $0.value == coinId })?.key {
                result[ticker] = eurPrice
            }
        }
        return result
    }

    /// Résout les prix EUR pour une liste de tokens par contract address.
    /// `tokens` : liste de (chain, contractAddress) où chain est dans `platformIDs`.
    /// Retourne dictionnaire "<chain>:<lowerContractAddress>" → prix EUR.
    func resolveTokenPrices(tokens: [(chain: String, contract: String)]) async -> [String: Double] {
        var result: [String: Double] = [:]
        let now = Date()

        // Regrouper par chaîne pour faire 1 req CoinGecko par chaîne
        let groupedByChain = Dictionary(grouping: tokens, by: { $0.chain.lowercased() })

        for (chain, contracts) in groupedByChain {
            guard let platformId = Self.platformIDs[chain] else { continue }

            // Cache hits
            var toFetch: [String] = []
            for (_, contract) in contracts {
                let lower = contract.lowercased()
                let cacheKey = "token:\(platformId):\(lower)"
                if let cached = cache[cacheKey], now.timeIntervalSince(cached.fetchedAt) < cacheTTL {
                    result["\(chain):\(lower)"] = cached.price
                } else {
                    toFetch.append(lower)
                }
            }
            guard !toFetch.isEmpty else { continue }

            // Fetch en 1 req par chaîne (CoinGecko accepte CSV)
            let addressesCSV = toFetch.joined(separator: ",")
            let urlString = "https://api.coingecko.com/api/v3/simple/token_price/\(platformId)?contract_addresses=\(addressesCSV)&vs_currencies=eur"
            guard let url = URL(string: urlString),
                  let prices = try? await fetchSimplePriceResponse(url: url) else { continue }
            for (address, eurPrice) in prices {
                let lower = address.lowercased()
                let cacheKey = "token:\(platformId):\(lower)"
                cache[cacheKey] = (eurPrice, now)
                result["\(chain):\(lower)"] = eurPrice
            }
        }
        return result
    }

    // MARK: - Historical (chart)

    /// Résultat détaillé d'un fetch historique CoinGecko. `points` peut être
    /// vide si l'API a renvoyé une erreur (HTTP ≠ 200) — `errorReason` contient
    /// alors un message lisible pour le diagnostic / la sync trace.
    struct HistoryFetchResult {
        let points: [InvestmentPricePoint]
        let errorReason: String?
    }

    /// Récupère l'historique de cours quotidien EUR pour un coin CoinGecko.
    /// Endpoint `/coins/{id}/market_chart?vs_currency=eur&days=365`.
    ///
    /// ⚠️ Deux limitations de la free public API :
    ///   1. `interval=daily` réservé Enterprise → on ne le passe pas (CoinGecko
    ///      choisit l'auto-granularité = daily pour days > 90, parfait)
    ///   2. `days=max` réservé aux plans payants. La free public API est capée
    ///      à 365 jours d'historique. Donc on demande 365 directement.
    ///
    /// Pour le chart "Max" sur une crypto plus ancienne, l'historique sera
    /// tronqué à 1 an (cohérent avec le comportement Yahoo d'avant la migration
    /// à 10y, qui ne s'applique de toute façon pas aux cryptos).
    ///
    /// Free tier : 30 req/min sans clé API.
    ///
    /// L'`identifier` est passé pour servir de clé en base (ex: "BTC" pour
    /// Bitcoin, pas le coinId CoinGecko "bitcoin" — cohérence avec position.ticker
    /// indispensable pour le JOIN à la lecture).
    func fetchHistoryDetailed(coinId: String, identifier: String) async -> HistoryFetchResult {
        let urlString = "https://api.coingecko.com/api/v3/coins/\(coinId)/market_chart?vs_currency=eur&days=365"
        guard let url = URL(string: urlString) else {
            return .init(points: [], errorReason: "URL invalide")
        }

        struct MarketChartResponse: Decodable {
            let prices: [[Double]]
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(points: [], errorReason: "Réponse réseau invalide")
            }
            guard http.statusCode == 200 else {
                // Inclure le body pour diagnostic (CoinGecko renvoie souvent
                // un JSON `{"status":{"error_message":"..."}}` quand ça plante)
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                return .init(
                    points: [],
                    errorReason: "HTTP \(http.statusCode) — \(body)"
                )
            }
            let decoded = try JSONDecoder().decode(MarketChartResponse.self, from: data)

            var points: [InvestmentPricePoint] = []
            points.reserveCapacity(decoded.prices.count)
            for entry in decoded.prices {
                guard entry.count >= 2 else { continue }
                let timestampMs = entry[0]
                let priceEUR = entry[1]
                guard priceEUR > 0 else { continue }
                let date = Date(timeIntervalSince1970: timestampMs / 1000)
                points.append(InvestmentPricePoint(
                    id: "\(identifier)-\(Int(timestampMs))",
                    identifier: identifier,
                    date: date,
                    close: priceEUR
                ))
            }
            return .init(
                points: points.sorted { $0.date < $1.date },
                errorReason: points.isEmpty ? "Réponse vide" : nil
            )
        } catch {
            return .init(
                points: [],
                errorReason: "Parse/réseau : \(error.localizedDescription)"
            )
        }
    }

    /// Variante simplifiée (compat ancienne API) — renvoie juste les points
    /// ou nil si échec.
    func fetchHistory(coinId: String, identifier: String) async -> [InvestmentPricePoint]? {
        let result = await fetchHistoryDetailed(coinId: coinId, identifier: identifier)
        return result.points.isEmpty ? nil : result.points
    }

    // MARK: - Helpers

    /// Parse la réponse CoinGecko `/simple/price` (et `/token_price`) qui a la forme :
    ///     { "bitcoin": {"eur": 95000.0}, "ethereum": {"eur": 3200.5} }
    /// Renvoie un dictionnaire plat key → eur. Throw si parsing impossible.
    private func fetchSimplePriceResponse(url: URL) async throws -> [String: Double] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.networkError("Réponse HTTP invalide")
        }
        // 429 = rate limit. CoinGecko free n'a pas de header Retry-After fiable, on indique
        // juste qu'on est limité et l'user devra retry plus tard.
        if http.statusCode == 429 {
            throw LiveSyncError.rateLimited(retryAfter: 60)
        }
        guard http.statusCode == 200 else {
            throw LiveSyncError.networkError("HTTP \(http.statusCode)")
        }

        guard let nested = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else {
            throw LiveSyncError.parseError("Format CoinGecko inattendu")
        }
        var flat: [String: Double] = [:]
        for (key, eurDict) in nested {
            if let eur = eurDict["eur"] {
                flat[key] = eur
            }
        }
        return flat
    }
}
