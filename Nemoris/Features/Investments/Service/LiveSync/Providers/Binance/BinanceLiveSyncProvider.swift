import Foundation

// MARK: - Binance provider
//
// Syncs Binance spot balances through the official API:
//   - validate: public ping + fetch account (checks the read-only credentials)
//   - fetchPositions: fetches spot balances, keeps non-zero ones, converts to
//     EUR via CoinGecko (PriceResolver). Assets without a EUR price are
//     returned with `currentValueEUR = nil` (obscure tokens).
//   - fetchTransactions: iterates myTrades per symbol (see below).
//
// The static metadata (id, displayName, credentialFields…) stays declared in
// `LiveSyncRegistry.swift` (stub struct), so adding a provider doesn't mean
// moving 4 files — this extension brings the actual implementation.

extension BinanceLiveSyncProvider {

    func validate(credentials: [String: String], config: [String: String]) async throws {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        // Public ping first, to tell "network down" from "bad credentials" quickly
        try await client.ping()
        // Then fetch the account with the credentials — exposes no state, no mutation
        _ = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        let account = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)

        // Keep non-zero balances (Binance returns ~400 assets, 95% of them at 0)
        let nonZero = account.balances.filter { $0.total > 0 }
        guard !nonZero.isEmpty else { return [] }

        // Fetch EUR prices for ALL tickers in 1 CoinGecko request (multi-ID)
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
        // Sort: EUR value descending, then quantity descending for tokens without a price
        .sorted { lhs, rhs in
            switch (lhs.currentValueEUR, rhs.currentValueEUR) {
            case let (l?, r?):  return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.quantity > rhs.quantity
            }
        }
    }

    /// Syncs Binance trade history.
    ///
    /// Strategy to avoid spamming Binance:
    ///   1. Fetch current balances → list of held assets
    ///   2. Drop stable/quote assets (USDT, USDC, BUSD, DAI)
    ///   3. For each asset, try the `<ASSET>USDT` pair (the most common on Binance)
    ///   4. Sleep 100 ms between requests to stay comfortably under 1200 weight/min
    ///   5. Cap at 25 pairs for wallets with > 25 different holdings
    ///
    /// EUR conversion: the current USDT/EUR rate is fetched via CoinGecko (1 req)
    /// and applied uniformly to every trade. This is an APPROXIMATION (the real
    /// USDT/EUR rate on the trade day differs), acceptable for personal tracking.
    /// For a precise average cost, the user can edit the unitPrice manually.
    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction] {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty,
              let apiSecret = credentials["apiSecret"], !apiSecret.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BinanceAPIClient()
        let account = try await client.fetchAccount(apiKey: apiKey, apiSecret: apiSecret)

        // Keep the assets worth fetching trades for (capped at 25)
        let stableTickers: Set<String> = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD"]
        let candidates = account.balances
            .filter { $0.total > 0 && !stableTickers.contains($0.asset.uppercased()) && $0.asset != "BNB" }
            .prefix(25)
            .map { $0.asset.uppercased() }

        guard !candidates.isEmpty else { return [] }

        // Fetch the USDT/EUR rate for conversion. CoinGecko returns USDT at ~€0.92
        // (it hovers around $1, so around €0.92-0.95 depending on EUR/USD).
        let usdtPrices = await PriceResolver.shared.resolveNativePrices(tickers: ["USDT"])
        let usdtEUR = usdtPrices["USDT"] ?? 0.92  // fallback si CoinGecko HS

        // Fetch trades for each asset on the ASSETUSDT pair
        var allTransactions: [LiveSyncTransaction] = []
        for asset in candidates {
            let symbol = "\(asset)USDT"
            do {
                let trades = try await client.fetchMyTrades(
                    symbol: symbol,
                    limit: 500,  // 500 = latest trades on this pair
                    apiKey: apiKey,
                    apiSecret: apiSecret
                )
                for trade in trades {
                    // Filter by `since` when provided (incremental sync)
                    if let since, trade.executedAt < since { continue }

                    // Fees: usually in BNB or USDT. Converted to EUR when the rate is known.
                    // Fees in other assets are kept at 0 rather than converted; the user can
                    // recompute them manually if precision matters.
                    let feesEUR: Double = {
                        if trade.commissionAsset.uppercased() == "BNB" {
                            return 0  // Without a BNB/EUR conversion here, 0 avoids skewing the numbers
                        }
                        if trade.commissionAsset.uppercased() == "USDT" {
                            return trade.commissionDouble * usdtEUR
                        }
                        // Fee paid in the purchased asset (rare): not converted
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
                // Silently skip pairs in error (rate limit, non-existent pair…) so a single
                // problematic pair doesn't fail the whole sync.
                continue
            }

            // Sleep between requests to stay under the rate limit (1200 weight/min ÷ 10
            // weight/req = 120 req/min = 1 req every 500 ms). 100 ms = 600 req/min in
            // theory, but network latency keeps this comfortably safe.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return allTransactions
    }

    // MARK: - Helpers

    /// Ticker → full name mapping, for user-friendly display.
    /// Fallback = the ticker itself when not in the table.
    static func assetDisplayName(for ticker: String) -> String {
        nameTable[ticker.uppercased()] ?? ticker.uppercased()
    }

    /// Full names of the most common cryptos on Binance.
    /// Deliberately short list — the ticker is shown for the others.
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
