import Foundation

// MARK: - Provider Solana Wallet (impl réelle)
//
// Flow fetchPositions :
//   1. fetchBalance(address) → SOL natif en unités humaines
//   2. fetchTokenAccounts(address) → tous les SPL tokens (filtrés > 0)
//   3. Résolution EUR via PriceResolver :
//      - SOL via resolveNativePrices(["SOL"])
//      - Tokens SPL via resolveTokenPrices avec chain="solana" + mintAddress
//
// Coût : 2 requêtes RPC + 1-2 requêtes CoinGecko = très rapide (< 2s).
//
// Limite connue : on n'a PAS les symboles humains (USDC, BONK, JUP...) directement
// depuis le RPC — seulement les mint addresses. CoinGecko `/simple/token_price` accepte
// les mint addresses pour `platform=solana` donc on a les prix EUR. Pour les NOMS, on
// utilise une mini table de mappage des SPL populaires + fallback "Token <mint truncated>".

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

        // 2. SPL tokens (gérer le cas où le RPC échoue mais SOL a marché)
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
        // Stub Couche 3b. À venir :
        //   - getSignaturesForAddress → liste des signatures de tx
        //   - getTransaction (par signature) → détails (entrées/sorties)
        //   - Parsing complexe vs EVM (Solana a un format account model bien différent)
        return []
    }

    // MARK: - Mint mapping

    /// Mapping mint address → (nom complet, ticker). Liste des SPL populaires.
    /// Fallback : ("Token <mint[..6]>", "SPL").
    /// Les mint addresses sont publiques et standard — pas de risque sécurité à les hardcoder.
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
        // Fallback : truncate mint address pour avoir un identifier humain
        let prefix = String(mint.prefix(6))
        return ("Token \(prefix)…", "SPL")
    }
}
