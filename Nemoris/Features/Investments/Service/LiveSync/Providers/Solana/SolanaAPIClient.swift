import Foundation

// MARK: - AXE I Couche 3b — Client Solana RPC public
//
// Protocol JSON-RPC 2.0 vers le RPC public officiel Solana (`api.mainnet-beta.solana.com`).
// Gratuit, pas de clé, mais rate limit raisonnable. Pour usage prod intensif, l'utilisateur peut
// passer son propre endpoint (Helius, QuickNode, Triton, etc.) — futur amélioration.
//
// Méthodes utilisées :
//   - getBalance(address)               → balance SOL en lamports (1e9 = 1 SOL)
//   - getTokenAccountsByOwner(address)  → tokens SPL (USDC, USDT, BONK, JUP, etc.)
//
// Docs : https://solana.com/docs/rpc/http

struct SolanaAPIClient {

    private let baseURL = URL(string: "https://api.mainnet-beta.solana.com")!

    /// Balance native SOL en lamports (Double pour précision dans la conversion).
    /// 1 SOL = 10^9 lamports.
    func fetchBalance(address: String) async throws -> Double {
        let body = JSONRPCRequest(
            method: "getBalance",
            params: [.string(address)]
        )
        let response: JSONRPCResponse<GetBalanceResult> = try await post(body)
        let lamports = response.result.value
        return Double(lamports) / 1_000_000_000.0  // 1e9 lamports = 1 SOL
    }

    /// Tokens SPL détenus par le wallet. Renvoie tous les comptes de tokens associés.
    /// Filter qty > 0 fait par le caller (le RPC retourne aussi les comptes vidés).
    func fetchTokenAccounts(address: String) async throws -> [SolanaTokenAccount] {
        // Le 2ème param `programId` = TOKEN_PROGRAM_ID (constant pour SPL standard)
        // Le 3ème param `encoding: jsonParsed` demande à Solana de décoder le compte
        let body = JSONRPCRequest(
            method: "getTokenAccountsByOwner",
            params: [
                .string(address),
                .object(["programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"]),
                .object(["encoding": "jsonParsed"])
            ]
        )
        let response: JSONRPCResponse<GetTokenAccountsResult> = try await post(body)
        return response.result.value.compactMap { wrapped -> SolanaTokenAccount? in
            let info = wrapped.account.data.parsed.info
            // Skip accounts à 0 (l'utilisateur a fermé le SPL token account sans le delete)
            guard let amount = Double(info.tokenAmount.amount), amount > 0 else { return nil }
            let qty = amount / pow(10.0, Double(info.tokenAmount.decimals))
            return SolanaTokenAccount(
                mintAddress: info.mint,
                quantity: qty,
                decimals: info.tokenAmount.decimals
            )
        }
    }

    // MARK: - HTTP/JSON-RPC

    private func post<T: Decodable>(_ body: JSONRPCRequest) async throws -> JSONRPCResponse<T> {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPResponse(response)

        do {
            let decoded = try JSONDecoder().decode(JSONRPCResponse<T>.self, from: data)
            if let error = decoded.error {
                // Solana renvoie 200 avec un body `error` quand l'adresse est invalide
                throw LiveSyncError.parseError("Solana RPC error \(error.code) : \(error.message)")
            }
            return decoded
        } catch let err as LiveSyncError {
            throw err
        } catch {
            throw LiveSyncError.parseError("Decode Solana : \(error.localizedDescription)")
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

// MARK: - DTO

/// Compte SPL token tel qu'extrait par notre client (forme aplatie).
struct SolanaTokenAccount: Hashable {
    let mintAddress: String     // Adresse du contract SPL (équivalent ERC-20 contract)
    let quantity: Double        // Quantité ajustée par decimals (= unité humaine)
    let decimals: Int
}

// MARK: - JSON-RPC 2.0 wrapper

/// Body d'une requête JSON-RPC. `params` est un mix de types donc on encode à la main.
private struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int = 1
    let method: String
    let params: [JSONRPCValue]

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

/// Valeur typée pour JSON-RPC params (string, number, object…).
/// Solana attend des arrays mixtes : `[address (string), {programId: ...}, {encoding: ...}]`.
private enum JSONRPCValue: Encodable {
    case string(String)
    case object([String: String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .object(let d): try container.encode(d)
        }
    }
}

/// Réponse JSON-RPC générique paramétrée par le type de `result`.
private struct JSONRPCResponse<T: Decodable>: Decodable {
    let result: T
    let error: RPCError?

    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    // Custom decoding pour gérer `result` qui peut être manquant si `error` présent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        if let r = try container.decodeIfPresent(T.self, forKey: .result) {
            self.result = r
        } else {
            // Si result absent ET pas d'erreur → on throw un decode error explicite
            throw DecodingError.dataCorruptedError(
                forKey: .result, in: container,
                debugDescription: "Solana RPC : result absent (error: \(self.error?.message ?? "unknown"))"
            )
        }
    }

    enum CodingKeys: String, CodingKey { case result, error }
}

/// Result de `getBalance` : { context, value: lamports }.
private struct GetBalanceResult: Decodable {
    let value: Int
}

/// Result de `getTokenAccountsByOwner` : { context, value: [SPL account] }.
private struct GetTokenAccountsResult: Decodable {
    let value: [SPLAccountWrapper]
}

/// Format aplati extrait : info.mint = contract SPL, info.tokenAmount = {amount, decimals}.
private struct SPLAccountWrapper: Decodable {
    let account: AccountData

    struct AccountData: Decodable {
        let data: ParsedData
    }
    struct ParsedData: Decodable {
        let parsed: Parsed
    }
    struct Parsed: Decodable {
        let info: Info
    }
    struct Info: Decodable {
        let mint: String
        let tokenAmount: TokenAmount
    }
    struct TokenAmount: Decodable {
        let amount: String   // raw amount as string (très grands nombres)
        let decimals: Int
    }
}
