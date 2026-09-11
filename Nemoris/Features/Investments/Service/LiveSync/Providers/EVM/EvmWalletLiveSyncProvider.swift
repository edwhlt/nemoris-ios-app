import Foundation

// MARK: - EVM wallet provider (multi-chain)
//
// Syncs an EVM wallet's balances (Ethereum, Polygon, BSC, Arbitrum,
// Optimism, Base). Uses the Etherscan V2 Multichain API (one endpoint
// parameterized by chainid).
//
// `fetchPositions` flow:
//   1. Read the chain from `config["chain"]` (e.g. "eth", "polygon")
//   2. Fetch the native balance (1 req) → ETH/MATIC/BNB depending on the chain
//   3. Fetch recent tokentx (1 req) → ERC-20 contracts held historically
//   4. For each unique contract found (capped at 25 to avoid too many
//      requests) → fetch tokenbalance (N sequential requests to respect the
//      5 req/s rate limit without a key)
//   5. Keep balance > 0 (contracts seen in history but emptied disappear)
//   6. Convert to EUR via PriceResolver (1 batched CoinGecko request by contract address)
//
// Request cost: 2 + N (N ≤ 25 → at most ~5 seconds without an Etherscan key).

extension EvmWalletLiveSyncProvider {

    /// Cap on the number of ERC-20 tokens to query, to avoid spamming Etherscan.
    /// Heavy-trader wallets (>25 distinct tokens) get a subset.
    private static let maxTokenLookups = 25

    func validate(credentials: [String: String], config: [String: String]) async throws {
        let (address, chainId, _) = try Self.parseConfig(credentials: credentials, config: config)
        let client = EvmAPIClient(apiKey: credentials["etherscanApiKey"])
        // A simple balance call validates the address + connectivity
        _ = try await client.fetchNativeBalance(address: address, chainId: chainId)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        let (address, chainId, chainInternalId) = try Self.parseConfig(credentials: credentials, config: config)
        let client = EvmAPIClient(apiKey: credentials["etherscanApiKey"])

        // 1. Native balance
        let nativeBalance = try await client.fetchNativeBalance(address: address, chainId: chainId)

        // 2. Discover ERC-20 contracts via the tokentx history (last 100 transfers)
        let contracts = (try? await client.fetchTokenContracts(address: address, chainId: chainId)) ?? []
        let cappedContracts = Array(contracts.prefix(Self.maxTokenLookups))

        // 3. Fetch each contract's balance (sequential — 5 req/s rate limit without a key)
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
                // Small delay (200 ms) without a key, to stay comfortably under 5 req/s
                if credentials["etherscanApiKey"]?.isEmpty != false {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch {
                // Skip a broken token without failing the whole sync
                continue
            }
        }

        // 4. Resolve EUR prices:
        //    - Native via resolveNativePrices (by ticker such as "ETH", "MATIC")
        //    - Tokens via resolveTokenPrices (by contract address on the CoinGecko chain)
        let nativeTicker = Self.nativeCurrencyTicker(forChain: chainInternalId)
        let nativePrices = await PriceResolver.shared.resolveNativePrices(tickers: [nativeTicker])
        let nativePriceEUR = nativePrices[nativeTicker]

        let tokenContractList: [(chain: String, contract: String)] = tokenBalances.map {
            (chain: chainInternalId, contract: $0.contract.contractAddress)
        }
        let tokenPrices = await PriceResolver.shared.resolveTokenPrices(tokens: tokenContractList)

        // 5. Assemble LiveSyncPosition[]
        var positions: [LiveSyncPosition] = []

        // Native first (always present, even when balance == 0)
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
        // Not implemented yet. To do:
        //   - module=account&action=txlist (native ETH transactions)
        //   - module=account&action=tokentx (ERC-20 transfers)
        //   - Mapping to InvestmentOrderType (.buy/.sell by in/out direction)
        //   - Filtering by address (IN transactions are purchases, OUT are sales)
        //   - EUR conversion at transaction time via historical PriceResolver (not available)
        return []
    }

    // MARK: - Helpers

    /// Parses + validates the user config. Throws if missing/invalid.
    /// Returns (address, chainIdEtherscan, chainInternalID).
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

    /// Native currency ticker per chain. Used for the CoinGecko lookup.
    static func nativeCurrencyTicker(forChain chainInternalId: String) -> String {
        switch chainInternalId {
        case "eth", "arbitrum", "optimism", "base":  return "ETH"
        case "polygon":                              return "MATIC"
        case "bsc":                                  return "BNB"
        default:                                     return "ETH"
        }
    }

    /// Native currency's full name, for display.
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
