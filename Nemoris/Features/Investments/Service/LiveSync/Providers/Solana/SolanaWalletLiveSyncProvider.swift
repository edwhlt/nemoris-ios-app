import Foundation

// MARK: - Solana wallet provider
//
// fetchPositions flow:
//   1. fetchBalance(address) → native SOL in human units
//   2. fetchTokenAccounts(address) → every SPL token (filtered > 0)
//   3. EUR resolution via PriceResolver:
//      - SOL via resolveNativePrices(["SOL"])
//      - SPL tokens via resolveTokenPrices with chain="solana" + mintAddress
//
// Cost: 2 RPC requests + 1-2 CoinGecko requests = very fast (< 2 s).
//
// Known limit: the RPC does NOT return human symbols (USDC, BONK, JUP...) —
// only mint addresses. CoinGecko `/simple/token_price` accepts mint addresses
// for `platform=solana`, so EUR prices are available. For NAMES, a small
// mapping table of popular SPL tokens is used, with a "Token <truncated mint>"
// fallback.

extension SolanaWalletLiveSyncProvider {

    func validate(credentials: [String: String], config: [String: String]) async throws {
        guard let address = credentials["address"], !address.isEmpty else {
            throw LiveSyncError.missingCredentials
        }
        let client = SolanaAPIClient()
        _ = try await client.fetchBalance(address: address)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        guard let address = credentials["address"], !address.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = SolanaAPIClient()

        // 1. SOL native
        let solBalance = try await client.fetchBalance(address: address)

        // 2. SPL tokens (handles the case where the RPC fails but SOL succeeded)
        let tokenAccounts = (try? await client.fetchTokenAccounts(address: address)) ?? []

        // 3. Prix EUR
        let nativePrices = await PriceResolver.shared.resolveNativePrices(tickers: ["SOL"])
        let solPriceEUR = nativePrices["SOL"]

        let tokenContractList: [(chain: String, contract: String)] = tokenAccounts.map {
            (chain: "solana", contract: $0.mintAddress)
        }
        let tokenPrices = await PriceResolver.shared.resolveTokenPrices(tokens: tokenContractList)

        // 4. Assemble
        var positions: [LiveSyncPosition] = []

        if solBalance > 0 {
            positions.append(LiveSyncPosition(
                assetType: "crypto",
                assetName: "Solana",
                ticker: "SOL",
                quantity: solBalance,
                currentValueEUR: solPriceEUR.map { $0 * solBalance },
                metadata: [
                    "address": address,
                    "isNative": "true",
                    "chain": "solana"
                ]
            ))
        }

        for account in tokenAccounts {
            let priceKey = "solana:\(account.mintAddress.lowercased())"
            let unitPrice = tokenPrices[priceKey]
            let (displayName, ticker) = Self.mintLookup(account.mintAddress)
            positions.append(LiveSyncPosition(
                assetType: "crypto",
                assetName: displayName,
                ticker: ticker,
                quantity: account.quantity,
                currentValueEUR: unitPrice.map { $0 * account.quantity },
                metadata: [
                    "address": address,
                    "chain": "solana",
                    "mintAddress": account.mintAddress,
                    "decimals": "\(account.decimals)"
                ]
            ))
        }

        return positions.sorted { lhs, rhs in
            switch (lhs.currentValueEUR, rhs.currentValueEUR) {
            case let (l?, r?):  return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.quantity > rhs.quantity
            }
        }
    }

    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction] {
        // Not implemented yet. To do:
        //   - getSignaturesForAddress → list of transaction signatures
        //   - getTransaction (per signature) → details (inflows/outflows)
        //   - More complex parsing than EVM (Solana's account model is very different)
        return []
    }

    // MARK: - Mint mapping

    /// Mint address → (full name, ticker) mapping. Popular SPL tokens.
    /// Fallback: ("Token <mint[..6]>", "SPL").
    /// Mint addresses are public and standard — no security risk in hardcoding
    /// them.
    private static let mintTable: [String: (name: String, ticker: String)] = [
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": ("USD Coin", "USDC"),
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": ("Tether", "USDT"),
        "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263": ("Bonk", "BONK"),
        "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN":  ("Jupiter", "JUP"),
        "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs": ("Ether (Wormhole)", "ETH"),
        "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So":  ("Marinade Staked SOL", "mSOL"),
        "7dHbWXmci3dT8UFYWYZweBLXgycu7Y3iL6trKn1Y7ARj": ("Lido Staked SOL", "stSOL"),
        "JitoxqXKzAcLEbHwLkR2WoVStHnoLnVx3CG3FfvSjQT":  ("Jito", "JTO")
    ]

    private static func mintLookup(_ mint: String) -> (name: String, ticker: String) {
        if let known = mintTable[mint] { return known }
        // Fallback: truncate the mint address to get a human-readable identifier
        let prefix = String(mint.prefix(6))
        return ("Token \(prefix)…", "SPL")
    }
}
