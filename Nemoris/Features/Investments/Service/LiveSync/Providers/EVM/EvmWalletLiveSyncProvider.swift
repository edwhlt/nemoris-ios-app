import Foundation

// MARK: - Provider EVM Wallet (impl réelle multi-chain)
//
// Synchronise les balances d'un wallet EVM (Ethereum, Polygon, BSC, Arbitrum, Optimism, Base).
// Utilise Etherscan V2 Multichain API (1 endpoint paramétré par chainid).
//
// Flow `fetchPositions` :
//   1. Lire chain depuis `config["chain"]` (ex: "eth", "polygon")
//   2. Fetch native balance (1 req) → ETH/MATIC/BNB selon chaîne
//   3. Fetch tokentx récents (1 req) → liste des contracts ERC-20 détenus historiquement
//   4. Pour chaque contract unique trouvé (cap 25 pour éviter trop de requêtes) →
//      fetch tokenbalance (N req sequentiel pour respecter rate limit 5 req/s sans clé)
//   5. Filter balance > 0 (les contracts vus en historique mais soldés à 0 disparaissent)
//   6. Convert EUR via PriceResolver (1 req batch CoinGecko par contract address)
//
// Coût en requêtes : 2 + N (N ≤ 25 → max ~5 secondes sans clé Etherscan).

extension EvmWalletLiveSyncProvider {

    /// Cap au nombre de tokens ERC-20 à requêter pour éviter de spam Etherscan.
    /// Les wallets gros traders (>25 tokens distincts) auront un sous-ensemble.
    private static let maxTokenLookups = 25

    func validate(credentials: [String: String], config: [String: String]) async throws {
        let (address, chainId, _) = try Self.parseConfig(credentials: credentials, config: config)
        let client = EvmAPIClient(apiKey: credentials["etherscanApiKey"])
        // Une simple balance call valide l'adresse + la connectivité
        _ = try await client.fetchNativeBalance(address: address, chainId: chainId)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        let (address, chainId, chainInternalId) = try Self.parseConfig(credentials: credentials, config: config)
        let client = EvmAPIClient(apiKey: credentials["etherscanApiKey"])

        // 1. Native balance
        let nativeBalance = try await client.fetchNativeBalance(address: address, chainId: chainId)

        // 2. Découvrir les contracts ERC-20 via l'historique tokentx (last 100 transferts)
        let contracts = (try? await client.fetchTokenContracts(address: address, chainId: chainId)) ?? []
        let cappedContracts = Array(contracts.prefix(Self.maxTokenLookups))

        // 3. Fetch balance de chaque contract (séquentiel — rate limit 5 req/s sans clé)
        var tokenBalances: [(contract: TokenContractInfo, qty: Double)] = []
        for contract in cappedContracts {
            do {
                let rawBalance = try await client.fetchTokenBalance(
                    address: address,
                    contractAddress: contract.contractAddress,
                    chainId: chainId
                )
                guard let raw = Double(rawBalance) else { continue }
                let qty = raw / pow(10.0, Double(contract.decimals))
                if qty > 0 {
                    tokenBalances.append((contract, qty))
                }
                // Petit délai (200ms) sans clé pour rester sous 5 req/s confortable
                if credentials["etherscanApiKey"]?.isEmpty != false {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch {
                // Skip un token cassé sans faire échouer toute la sync
                continue
            }
        }

        // 4. Résoudre les prix EUR :
        //    - Native via resolveNativePrices (par ticker comme "ETH", "MATIC")
        //    - Tokens via resolveTokenPrices (par contract address sur la chaîne CoinGecko)
        let nativeTicker = Self.nativeCurrencyTicker(forChain: chainInternalId)
        let nativePrices = await PriceResolver.shared.resolveNativePrices(tickers: [nativeTicker])
        let nativePriceEUR = nativePrices[nativeTicker]

        let tokenContractList: [(chain: String, contract: String)] = tokenBalances.map {
            (chain: chainInternalId, contract: $0.contract.contractAddress)
        }
        let tokenPrices = await PriceResolver.shared.resolveTokenPrices(tokens: tokenContractList)

        // 5. Assemble LiveSyncPosition[]
        var positions: [LiveSyncPosition] = []

        // Native d'abord (toujours présent même si balance == 0)
        if nativeBalance > 0 {
            positions.append(LiveSyncPosition(
                assetType: "crypto",
                assetName: Self.nativeCurrencyName(forChain: chainInternalId),
                ticker: nativeTicker,
                quantity: nativeBalance,
                currentValueEUR: nativePriceEUR.map { $0 * nativeBalance },
                metadata: [
                    "chain": chainInternalId,
                    "address": address,
                    "isNative": "true"
                ]
            ))
        }

        // Tokens ERC-20
        for (contract, qty) in tokenBalances {
            let priceKey = "\(chainInternalId):\(contract.contractAddress)"
            let unitPrice = tokenPrices[priceKey]
            positions.append(LiveSyncPosition(
                assetType: "crypto",
                assetName: contract.name.isEmpty ? contract.symbol : contract.name,
                ticker: contract.symbol.isEmpty ? "TOKEN" : contract.symbol,
                quantity: qty,
                currentValueEUR: unitPrice.map { $0 * qty },
                metadata: [
                    "chain": chainInternalId,
                    "address": address,
                    "contractAddress": contract.contractAddress,
                    "decimals": "\(contract.decimals)"
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
        // Stub Couche 2. À venir :
        //   - module=account&action=txlist (transactions ETH natives)
        //   - module=account&action=tokentx (transferts ERC-20)
        //   - Mapping vers InvestmentOrderType (.buy/.sell selon direction in/out)
        //   - Filtrage par adresse (les txs IN sont des achats, OUT des ventes)
        //   - Conversion EUR au moment de la tx via PriceResolver historique (pas dispo MVP)
        return []
    }

    // MARK: - Helpers

    /// Parse + valide la config user. Throw si manquant/invalide.
    /// Retourne (address, chainIdEtherscan, chainInternalID).
    private static func parseConfig(
        credentials: [String: String],
        config: [String: String]
    ) throws -> (String, Int, String) {
        guard let address = credentials["address"],
              !address.isEmpty,
              address.lowercased().hasPrefix("0x"),
              address.count == 42 else {
            throw LiveSyncError.missingCredentials
        }
        guard let chainInternalId = config["chain"],
              let chainId = EvmAPIClient.chainIdMap[chainInternalId] else {
            throw LiveSyncError.missingCredentials
        }
        return (address, chainId, chainInternalId)
    }

    /// Ticker de la devise native par chaîne. Utilisé pour le lookup CoinGecko.
    static func nativeCurrencyTicker(forChain chainInternalId: String) -> String {
        switch chainInternalId {
        case "eth", "arbitrum", "optimism", "base":  return "ETH"
        case "polygon":                              return "MATIC"
        case "bsc":                                  return "BNB"
        default:                                     return "ETH"
        }
    }

    /// Nom complet de la devise native pour affichage.
    static func nativeCurrencyName(forChain chainInternalId: String) -> String {
        switch chainInternalId {
        case "eth":      return "Ethereum"
        case "polygon":  return "Polygon (MATIC)"
        case "bsc":      return "BNB"
        case "arbitrum": return "Ethereum (Arbitrum)"
        case "optimism": return "Ethereum (Optimism)"
        case "base":     return "Ethereum (Base)"
        default:         return "ETH"
        }
    }
}
