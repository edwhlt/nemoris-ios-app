import Foundation

// MARK: - Client Etherscan V2 Multichain API
//
// Etherscan V2 (lancée fin 2024) unifie l'accès aux explorers EVM via UN SEUL endpoint
// `https://api.etherscan.io/v2/api` paramétré par `chainid`. Une seule clé API gratuite
// fonctionne pour les 6 chaînes qu'on supporte. Sans clé : 5 req/s. Avec clé : 100k/jour.
//
// Docs officielles : https://docs.etherscan.io/etherscan-v2/

struct EvmAPIClient {

    /// Base URL unifiée Etherscan V2 (toutes chaînes via `chainid`).
    private let baseURL = URL(string: "https://api.etherscan.io/v2/api")!

    /// Clé API optionnelle. Si vide → 5 req/s sans clé.
    let apiKey: String?

    init(apiKey: String? = nil) {
        // Strip whitespace + traiter "" comme nil
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Chain ID mapping
    //
    // Mapping interne ID Nemoris → chainid Etherscan V2.
    // Doit rester cohérent avec `EvmWalletLiveSyncProvider.supportedChains`.

    static let chainIdMap: [String: Int] = [
        "eth":      1,       // Ethereum Mainnet
        "polygon":  137,     // Polygon PoS
        "bsc":      56,      // BNB Smart Chain
        "arbitrum": 42161,   // Arbitrum One
        "optimism": 10,      // Optimism
        "base":     8453     // Base
    ]

    /// Mapping inverse : chainid Etherscan → ID interne (utile pour PriceResolver
    /// qui veut le slug CoinGecko via `platformIDs`).
    static func internalChainID(forEtherscanChainID id: Int) -> String? {
        chainIdMap.first(where: { $0.value == id })?.key
    }

    // MARK: - Endpoints

    /// Balance native (ETH/MATIC/BNB selon chaîne), retournée en wei (entier).
    /// Convertir en unité native en divisant par 1e18.
    /// Throw `LiveSyncError` typé en cas d'erreur réseau/parsing.
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

    /// Récupère les transferts ERC-20 récents pour découvrir les contracts détenus.
    /// `limit` cap les txs retournées (50-100 suffit pour décrouvrir les holdings).
    /// Renvoie les contracts uniques rencontrés (dédup + symbol/decimals préservés).
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

        // Dédup par contractAddress en gardant la 1ère occurrence (la plus récente).
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

    /// Balance d'un token ERC-20 spécifique, en raw units (string). À diviser par
    /// 10^decimals pour obtenir la quantité réelle.
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

    /// GET vers `baseURL` avec params encodés. Ajoute la clé API si fournie.
    /// Parse la réponse comme JSON typé.
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

/// Réponse standard Etherscan pour balance/tokenbalance — string `result`.
private struct BalanceResponse: Decodable {
    let status: String          // "1" = OK, "0" = erreur (souvent address invalide)
    let message: String
    let result: String
}

/// Réponse pour tokentx — `result` est un array de transferts.
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

/// Infos extraites d'un transfert ERC-20 — utilisé pour identifier les tokens à requêter.
struct TokenContractInfo: Hashable {
    let contractAddress: String  // 0x... lowercased
    let symbol: String
    let name: String
    let decimals: Int
}
