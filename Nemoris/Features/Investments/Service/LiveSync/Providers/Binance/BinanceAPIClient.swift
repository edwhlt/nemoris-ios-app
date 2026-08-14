import Foundation
import CryptoKit

// MARK: - Client bas niveau Binance Spot API
//
// Implémente l'authentification HMAC SHA256 requise par Binance (cf. docs officielles
// https://developers.binance.com/docs/binance-spot-api-docs/rest-api/general-api-information).
//
// Flow auth :
//   1. Construire la query string avec timestamp=<ms_epoch>
//   2. HMAC-SHA256(secret, query) → signature hex
//   3. Ajouter "&signature=<hex>" à la query
//   4. GET avec header "X-MBX-APIKEY: <apiKey>"
//
// On vise read-only :
//   - /api/v3/ping       (public, test connectivité)
//   - /api/v3/account    (signed, balances spot)
//
// La clé fournie par l'utilisateur DOIT être créée en mode "Enable Reading" only (pas de
// trading ni de withdrawal). Le code ne fait que des GET — aucun risque même si la
// clé avait par erreur des permissions plus larges.

struct BinanceAccountResponse: Decodable {
    let balances: [Balance]
    // makerCommission, takerCommission, canTrade, canDeposit... ignorés pour MVP

    struct Balance: Decodable {
        let asset: String       // Ex: "BTC", "ETH", "USDT"
        let free: String        // Quantité libre (string Binance pour précision)
        let locked: String      // Quantité bloquée (ordres ouverts, staking flexible…)

        /// Total = free + locked, parsé en Double. 0 si parse échoue.
        var total: Double {
            (Double(free) ?? 0) + (Double(locked) ?? 0)
        }
    }
}

/// Un trade tel que retourné par /api/v3/myTrades.
/// Binance utilise des `String` pour les nombres décimaux pour préserver la précision.
struct BinanceTrade: Decodable {
    let id: Int                  // Trade ID unique chez Binance
    let symbol: String           // Ex: "BTCUSDT"
    let price: String            // Prix unitaire en quote (USDT pour BTCUSDT)
    let qty: String              // Quantité en base (BTC pour BTCUSDT)
    let quoteQty: String         // qty × price (= total en quote)
    let commission: String       // Frais en commissionAsset
    let commissionAsset: String  // Souvent "BNB" si BNB activé, sinon quote (USDT)
    let time: Int64              // Timestamp ms UTC
    let isBuyer: Bool            // true → l'utilisateur a acheté (entrée en position)

    var priceDouble: Double      { Double(price) ?? 0 }
    var qtyDouble: Double        { Double(qty) ?? 0 }
    var commissionDouble: Double { Double(commission) ?? 0 }
    var executedAt: Date         { Date(timeIntervalSince1970: Double(time) / 1000) }
}

struct BinanceAPIClient {

    /// URL de base de l'API spot Binance. api.binance.com pour prod global.
    /// api.binance.us pour Binance US (séparée juridiquement, autre fingerprint).
    private let baseURL: URL

    init(baseURL: URL = URL(string: "https://api.binance.com")!) {
        self.baseURL = baseURL
    }

    // MARK: - Public endpoints

    /// Ping public — test connectivité sans auth. Utile pour vérifier que les serveurs
    /// Binance répondent depuis le device (souvent bloqué dans certains pays).
    func ping() async throws {
        let url = baseURL.appendingPathComponent("api/v3/ping")
        let (_, response) = try await URLSession.shared.data(from: url)
        try Self.checkHTTPResponse(response)
    }

    // MARK: - Signed endpoints

    /// Récupère les balances spot. Throw `LiveSyncError` en cas d'erreur de creds/réseau/parsing.
    func fetchAccount(apiKey: String, apiSecret: String) async throws -> BinanceAccountResponse {
        let endpoint = "api/v3/account"
        let request = try buildSignedRequest(endpoint: endpoint, apiKey: apiKey, apiSecret: apiSecret, params: [:])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPResponse(response)

        do {
            return try JSONDecoder().decode(BinanceAccountResponse.self, from: data)
        } catch {
            throw LiveSyncError.parseError("Decode Binance account : \(error.localizedDescription)")
        }
    }

    /// Historique des trades pour une paire donnée.
    /// `symbol` obligatoire (ex: "BTCUSDT"). Cap par défaut 500 (max Binance = 1000).
    /// Retourne array vide si la paire n'existe pas / l'utilisateur n'a jamais tradé dessus.
    ///
    /// Coût rate limit : 10 weight par requête. Avec quota 1200/min → ~120 paires/min max.
    func fetchMyTrades(symbol: String, limit: Int = 500, apiKey: String, apiSecret: String) async throws -> [BinanceTrade] {
        let endpoint = "api/v3/myTrades"
        let request = try buildSignedRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            apiSecret: apiSecret,
            params: [
                "symbol": symbol,
                "limit": "\(min(max(limit, 1), 1000))"
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        // Binance renvoie 400 quand la paire n'existe pas (ex: PNUTUSDT pour un asset
        // trop nouveau). On traite ça comme "0 trades" plutôt que comme une erreur.
        if let http = response as? HTTPURLResponse, http.statusCode == 400 {
            return []
        }
        try Self.checkHTTPResponse(response)

        do {
            return try JSONDecoder().decode([BinanceTrade].self, from: data)
        } catch {
            throw LiveSyncError.parseError("Decode Binance trades : \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers (signing)

    /// Construit une URLRequest signée pour un endpoint privé.
    /// Throw si encodage URL impossible.
    private func buildSignedRequest(
        endpoint: String,
        apiKey: String,
        apiSecret: String,
        params: [String: String]
    ) throws -> URLRequest {
        // 1. Construire la query avec timestamp (recvWindow par défaut 5000ms suffit)
        var queryParams = params
        queryParams["timestamp"] = "\(Int(Date().timeIntervalSince1970 * 1000))"
        queryParams["recvWindow"] = "10000" // tolérance 10s vs serveur

        // Encoder avec ordre stable (alpha) pour reproductibilité (Binance s'en fiche
        // mais c'est plus propre pour debug).
        let sortedKeys: [String] = queryParams.keys.sorted()
        let pairs: [String] = sortedKeys.map { paramKey -> String in
            let value = queryParams[paramKey] ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(paramKey)=\(encoded)"
        }
        let queryString: String = pairs.joined(separator: "&")

        // 2. Signer en HMAC-SHA256 avec apiSecret.
        let secretBytes: [UInt8] = Array(apiSecret.utf8)
        let queryBytes: [UInt8] = Array(queryString.utf8)
        let symmetricKey = SymmetricKey(data: secretBytes)
        let signature = HMAC<SHA256>.authenticationCode(for: queryBytes, using: symmetricKey)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        // 3. URL finale + header API key
        let urlString = "\(baseURL.absoluteString)/\(endpoint)?\(queryString)&signature=\(signatureHex)"
        guard let url = URL(string: urlString) else {
            throw LiveSyncError.parseError("URL invalide après signature")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.timeoutInterval = 15
        return request
    }

    /// Vérifie le code HTTP et convertit en `LiveSyncError` typé.
    /// - 200 → OK
    /// - 401 → credentials invalides
    /// - 429 / 418 → rate limit (Binance utilise 418 pour ban temporaire)
    /// - autres → networkError
    private static func checkHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.networkError("Réponse HTTP invalide")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw LiveSyncError.invalidCredentials
        case 418, 429:
            // Header Retry-After parfois fourni par Binance
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw LiveSyncError.rateLimited(retryAfter: retry ?? 60)
        case 451:
            throw LiveSyncError.networkError("Service indisponible dans votre région (HTTP 451).")
        default:
            throw LiveSyncError.networkError("HTTP \(http.statusCode)")
        }
    }
}
