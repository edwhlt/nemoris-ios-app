import Foundation

// MARK: - EUR price resolution via CoinGecko
//
// Every crypto provider (Binance, EVM, BTC, SOL) uses this service to convert
// holdings (BTC, ETH, USDC, etc.) into EUR value for the portfolio.
//
// Strategy:
//   - CoinGecko free API: 50 req/min without a key (plenty for personal use)
//   - 2 lookup modes:
//       * `/simple/price` by symbol/coin_id (e.g. "bitcoin", "ethereum") — for natives
//       * `/simple/token_price/<chain>` by contract address — for ERC-20/BEP-20/SPL
//   - 10-min RAM cache: for personal use, refreshing on each sync is enough
//   - Tokens without a CoinGecko price → returned with a nil value, shown by
//     the UI as "Value unavailable"
//
// Privacy: direct calls to api.coingecko.com from the device. No server proxy.

actor PriceResolver {

    static let shared = PriceResolver()
    private init() {}

    /// RAM cache TTL in seconds. 10 min = trade-off between network cost and freshness.
    private let cacheTTL: TimeInterval = 600

    /// Cache: key = "<lookupType>:<key>", value = (EUR price, fetch date)
    /// E.g. "coin:bitcoin" → 95000.0, or "token:ethereum:0xa0b8..." → 0.9998
    private var cache: [String: (price: Double, fetchedAt: Date)] = [:]

    // MARK: - Ticker → CoinGecko coin ID mapping (major natives)
    //
    // CoinGecko uses slugs ("bitcoin") instead of tickers ("BTC"). The most common
    // natives are mapped by hand. ERC-20/SPL tokens go through the lookup by
    // contract address (more precise).

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
        // Stablecoins (fetched too, for the ~$0.998-1.002 micro-deviations)
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

    /// Resolves a ticker (e.g. "BTC", "FET") into a CoinGecko coinId (e.g.
    /// "bitcoin", "fetch-ai"). Returns nil if the ticker isn't a known crypto —
    /// in that case the price sync must go through Yahoo, not CoinGecko.
    static func coinId(forTicker ticker: String) -> String? {
        nativeCoinIDs[ticker.uppercased()]
    }

    /// CoinGecko "platform" IDs for the lookup by contract address.
    /// Reference: https://api.coingecko.com/api/v3/asset_platforms
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

    /// Resolves EUR prices for a list of native tickers (BTC, ETH, SOL, USDC...).
    /// Returns a ticker → EUR price dictionary (unknown tickers are missing).
    func resolveNativePrices(tickers: [String]) async -> [String: Double] {
        let upperTickers = Set(tickers.map { $0.uppercased() })
        var result: [String: Double] = [:]

        // Step 1: fill from the cache
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

        // Step 2: fetch the missing ones in a single CoinGecko request (multi-ID)
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
            // Reverse coinId → ticker map to fill the result
            if let ticker = Self.nativeCoinIDs.first(where: { $0.value == coinId })?.key {
                result[ticker] = eurPrice
            }
        }
        return result
    }

    /// Resolves EUR prices for a list of tokens by contract address.
    /// `tokens`: list of (chain, contractAddress) where chain is in `platformIDs`.
    /// Returns a "<chain>:<lowerContractAddress>" → EUR price dictionary.
    func resolveTokenPrices(tokens: [(chain: String, contract: String)]) async -> [String: Double] {
        var result: [String: Double] = [:]
        let now = Date()

        // Group by chain to make 1 CoinGecko request per chain
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

            // Fetch in 1 request per chain (CoinGecko accepts CSV)
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

    /// Detailed result of a CoinGecko history fetch. `points` may be empty if the
    /// API returned an error (HTTP ≠ 200) — `errorReason` then holds a readable
    /// message for diagnostics / the sync trace. `isRateLimited` tells a 429
    /// (TEMPORARY failure, breaker open) from a real "no data" — consumed by
    /// InvestmentAutoSyncService.
    struct HistoryFetchResult {
        let points: [InvestmentPricePoint]
        let errorReason: String?
        var isRateLimited: Bool = false
    }

    /// Fetches the daily EUR price history of a CoinGecko coin.
    /// Endpoint `/coins/{id}/market_chart?vs_currency=eur&days=365`.
    ///
    /// Two limitations of the free public API:
    ///   1. `interval=daily` is Enterprise-only → not passed (CoinGecko picks its
    ///      auto-granularity = daily for days > 90, which is exactly right)
    ///   2. `days=max` is reserved to paid plans. The free public API is capped at
    ///      365 days of history, so 365 is requested directly.
    ///
    /// For the "Max" chart on an older crypto, history is therefore truncated to
    /// 1 year.
    ///
    /// Free tier: 30 req/min without an API key.
    ///
    /// `identifier` is passed to serve as the storage key (e.g. "BTC" for Bitcoin,
    /// not the CoinGecko coinId "bitcoin") — consistency with position.ticker is
    /// required for the lookup on read.
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
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // ResilientHTTP = 2.2 s pacing (30 req/min free tier)
            // + breaker after a 429 + backoff retry on 5xx/timeouts.
            let data = try await ResilientHTTP.send(request, provider: .coinGecko, timeout: 20)
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
        } catch MarketDataFetchError.rateLimited(_, let retryAfter) {
            return .init(
                points: [],
                errorReason: "HTTP 429 — limite de requêtes CoinGecko (réessai dans \(Int(retryAfter))s)",
                isRateLimited: true
            )
        } catch MarketDataFetchError.badStatus(let code) {
            return .init(points: [], errorReason: "HTTP \(code)")
        } catch {
            return .init(
                points: [],
                errorReason: "Parse/réseau : \(error.localizedDescription)"
            )
        }
    }

    /// Simplified variant — returns just the points, or nil on failure.
    func fetchHistory(coinId: String, identifier: String) async -> [InvestmentPricePoint]? {
        let result = await fetchHistoryDetailed(coinId: coinId, identifier: identifier)
        return result.points.isEmpty ? nil : result.points
    }

    /// INTRADAY history for the 1D range: `market_chart?days=1` (auto granularity
    /// ≈ 5 min on the free tier), DOWNSAMPLED to one point / 30 min (~48 points /
    /// 24 h instead of ~288 — the frequency is matched to the range to limit the
    /// stored volume).
    func fetchIntradayDetailed(coinId: String, identifier: String) async -> HistoryFetchResult {
        let urlString = "https://api.coingecko.com/api/v3/coins/\(coinId)/market_chart?vs_currency=eur&days=1"
        guard let url = URL(string: urlString) else {
            return .init(points: [], errorReason: "URL invalide")
        }

        struct MarketChartResponse: Decodable {
            let prices: [[Double]]
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await ResilientHTTP.send(request, provider: .coinGecko, timeout: 20)
            let decoded = try JSONDecoder().decode(MarketChartResponse.self, from: data)

            var points: [InvestmentPricePoint] = []
            var lastBucket: Double = -1
            for entry in decoded.prices {
                guard entry.count >= 2 else { continue }
                let timestampMs = entry[0]
                let priceEUR = entry[1]
                guard priceEUR > 0 else { continue }
                // 30-min bucket: only the first point of each bucket is kept.
                let bucket = (timestampMs / 1000 / 1800).rounded(.down)
                guard bucket != lastBucket else { continue }
                lastBucket = bucket
                points.append(InvestmentPricePoint(
                    id: "\(identifier)-i30-\(Int(timestampMs))",
                    identifier: identifier,
                    date: Date(timeIntervalSince1970: timestampMs / 1000),
                    close: priceEUR
                ))
            }
            return .init(
                points: points.sorted { $0.date < $1.date },
                errorReason: points.isEmpty ? "Réponse vide" : nil
            )
        } catch MarketDataFetchError.rateLimited(_, let retryAfter) {
            return .init(
                points: [],
                errorReason: "HTTP 429 — limite de requêtes CoinGecko (réessai dans \(Int(retryAfter))s)",
                isRateLimited: true
            )
        } catch MarketDataFetchError.badStatus(let code) {
            return .init(points: [], errorReason: "HTTP \(code)")
        } catch {
            return .init(
                points: [],
                errorReason: "Parse/réseau : \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    /// Parses the CoinGecko `/simple/price` (and `/token_price`) response, shaped:
    ///     { "bitcoin": {"eur": 95000.0}, "ethereum": {"eur": 3200.5} }
    /// Returns a flat key → eur dictionary. Throws if parsing is impossible.
    private func fetchSimplePriceResponse(url: URL) async throws -> [String: Double] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.networkError("Réponse HTTP invalide")
        }
        // 429 = rate limit. CoinGecko free has no reliable Retry-After header, so it
        // only reports being limited and the user will retry later. It also feeds
        // the shared breaker, so HISTORY fetches (InvestmentAutoSyncService) know
        // immediately that CoinGecko is unavailable.
        if http.statusCode == 429 {
            await ProviderRateLimiter.shared.reportRateLimited(.coinGecko, retryAfter: 60)
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
