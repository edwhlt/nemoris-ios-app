import Foundation

// MARK: - Etherscan V2 Multichain API client
//
// Etherscan V2 unifies access to EVM explorers through ONE endpoint,
// `https://api.etherscan.io/v2/api`, parameterized by `chainid`. A single free
// API key works for the 6 supported chains (100k requests/day). The key is
// required: the account/balance module is no longer served anonymously.
//
// Official docs: https://docs.etherscan.io/etherscan-v2/

struct EvmAPIClient {

    /// Unified Etherscan V2 base URL (every chain via `chainid`).
    private let baseURL = URL(string: "https://api.etherscan.io/v2/api")!

    /// API key (required by Etherscan V2 for the account/balance module).
    let apiKey: String?

    init(apiKey: String? = nil) {
        // Strip whitespace + treat "" as nil
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Chain ID mapping
    //
    // Internal Nemoris ID → Etherscan V2 chainid.
    // Must stay consistent with `EvmWalletLiveSyncProvider.supportedChains`.

    static let chainIdMap: [String: Int] = [
        "eth":      1,       // Ethereum Mainnet
        "polygon":  137,     // Polygon PoS
        "bsc":      56,      // BNB Smart Chain
        "arbitrum": 42161,   // Arbitrum One
        "optimism": 10,      // Optimism
        "base":     8453     // Base
    ]

    /// Reverse mapping: Etherscan chainid → internal ID (used by PriceResolver,
    /// which needs the CoinGecko slug via `platformIDs`).
    static func internalChainID(forEtherscanChainID id: Int) -> String? {
        chainIdMap.first(where: { $0.value == id })?.key
    }

    // MARK: - Endpoints

    /// Native balance (ETH/MATIC/BNB depending on the chain), returned in wei
    /// (integer). Divide by 1e18 to get native units.
    /// Throws a typed `LiveSyncError` on network/parsing errors.
    func fetchNativeBalance(address: String, chainId: Int) async throws -> Double {
        let response: BalanceResponse = try await get(
            params: [
                "chainid":  "\(chainId)",
                "module":   "account",
                "action":   "balance",
                "address":  address,
                "tag":      "latest"
            ]
        )
        guard let wei = Double(response.result) else {
            throw LiveSyncError.parseError("Balance native non parseable (\(response.result))")
        }
        return wei / 1_000_000_000_000_000_000.0  // 1e18 wei = 1 ETH/MATIC/BNB
    }

    /// Fetches recent ERC-20 transfers to discover the contracts held.
    /// `limit` caps the returned transactions (50-100 is enough to discover holdings).
    /// Returns the unique contracts encountered (deduplicated, symbol/decimals kept).
    func fetchTokenContracts(address: String, chainId: Int, limit: Int = 100) async throws -> [TokenContractInfo] {
        let response: TokenTxResponse = try await get(
            params: [
                "chainid":  "\(chainId)",
                "module":   "account",
                "action":   "tokentx",
                "address":  address,
                "page":     "1",
                "offset":   "\(limit)",
                "sort":     "desc"
            ]
        )

        // Deduplicate by contractAddress, keeping the 1st occurrence (the most recent).
        var seen = Set<String>()
        var contracts: [TokenContractInfo] = []
        for tx in response.result {
            let contract = tx.contractAddress.lowercased()
            guard !seen.contains(contract), !contract.isEmpty else { continue }
            seen.insert(contract)
            contracts.append(TokenContractInfo(
                contractAddress: contract,
                symbol: tx.tokenSymbol,
                name: tx.tokenName,
                decimals: Int(tx.tokenDecimal) ?? 18
            ))
        }
        return contracts
    }

    /// Balance of a specific ERC-20 token, in raw units (string). Divide by
    /// 10^decimals to get the real quantity.
    func fetchTokenBalance(address: String, contractAddress: String, chainId: Int) async throws -> String {
        let response: BalanceResponse = try await get(
            params: [
                "chainid":         "\(chainId)",
                "module":          "account",
                "action":          "tokenbalance",
                "contractaddress": contractAddress,
                "address":         address,
                "tag":              "latest"
            ]
        )
        return response.result
    }

    // MARK: - HTTP helper

    /// GET to `baseURL` with encoded params. Adds the API key when provided.
    /// Parses the response as typed JSON.
    private func get<T: Decodable>(params: [String: String]) async throws -> T {
        var allParams = params
        if let apiKey {
            allParams["apikey"] = apiKey
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw LiveSyncError.parseError("URL Etherscan invalide")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPResponse(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LiveSyncError.parseError("Decode Etherscan : \(error.localizedDescription)")
        }
    }

    private static func checkHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.networkError("Réponse HTTP invalide")
        }
        switch http.statusCode {
        case 200..<300: return
        case 429:       throw LiveSyncError.rateLimited(retryAfter: nil)
        default:        throw LiveSyncError.networkError("HTTP \(http.statusCode)")
        }
    }
}

// MARK: - DTO Decodable

/// Standard Etherscan response for balance/tokenbalance — string `result`.
private struct BalanceResponse: Decodable {
    let status: String          // "1" = OK, "0" = erreur (souvent address invalide)
    let message: String
    let result: String
}

/// Response for tokentx — `result` is an array of transfers.
private struct TokenTxResponse: Decodable {
    let status: String
    let message: String
    let result: [TokenTransfer]
}

private struct TokenTransfer: Decodable {
    let contractAddress: String
    let tokenName: String
    let tokenSymbol: String
    let tokenDecimal: String
}

/// Info extracted from an ERC-20 transfer — used to identify the tokens to query.
struct TokenContractInfo: Hashable {
    let contractAddress: String  // 0x... lowercased
    let symbol: String
    let name: String
    let decimals: Int
}
