import Foundation
import CryptoKit

// MARK: - Low-level Binance Spot API client
//
// Implements the HMAC SHA256 authentication required by Binance (see the
// official docs:
// https://developers.binance.com/docs/binance-spot-api-docs/rest-api/general-api-information).
//
// Auth flow:
//   1. Build the query string with timestamp=<ms_epoch>
//   2. HMAC-SHA256(secret, query) → hex signature
//   3. Append "&signature=<hex>" to the query
//   4. GET with the "X-MBX-APIKEY: <apiKey>" header
//
// Read-only by design:
//   - /api/v3/ping       (public, connectivity test)
//   - /api/v3/account    (signed, spot balances)
//
// The key supplied by the user MUST be created with "Enable Reading" only (no
// trading or withdrawal). The code only issues GETs — no risk even if the key
// mistakenly has broader permissions.

struct BinanceAccountResponse: Decodable {
    let balances: [Balance]
    // makerCommission, takerCommission, canTrade, canDeposit... ignored

    struct Balance: Decodable {
        let asset: String       // Ex: "BTC", "ETH", "USDT"
        let free: String        // Free quantity (a Binance string, for precision)
        let locked: String      // Locked quantity (open orders, flexible staking…)

        /// Total = free + locked, parsed as Double. 0 if parsing fails.
        var total: Double {
            (Double(free) ?? 0) + (Double(locked) ?? 0)
        }
    }
}

/// A trade as returned by /api/v3/myTrades.
/// Binance uses `String` for decimal numbers to preserve precision.
struct BinanceTrade: Decodable {
    let id: Int                  // Trade ID unique chez Binance
    let symbol: String           // Ex: "BTCUSDT"
    let price: String            // Unit price in the quote asset (USDT for BTCUSDT)
    let qty: String              // Quantity in the base asset (BTC for BTCUSDT)
    let quoteQty: String         // qty × price (= total en quote)
    let commission: String       // Frais en commissionAsset
    let commissionAsset: String  // Often "BNB" when BNB fees are enabled, otherwise the quote asset (USDT)
    let time: Int64              // Timestamp ms UTC
    let isBuyer: Bool            // true → the user bought (entering the position)

    var priceDouble: Double      { Double(price) ?? 0 }
    var qtyDouble: Double        { Double(qty) ?? 0 }
    var commissionDouble: Double { Double(commission) ?? 0 }
    var executedAt: Date         { Date(timeIntervalSince1970: Double(time) / 1000) }
}

struct BinanceAPIClient {

    /// Base URL of the Binance spot API. api.binance.com for global production;
    /// api.binance.us for Binance US (legally separate, different fingerprint).
    private let baseURL: URL

    init(baseURL: URL = URL(string: "https://api.binance.com")!) {
        self.baseURL = baseURL
    }

    // MARK: - Public endpoints

    /// Public ping — connectivity test without auth. Useful to check that Binance
    /// servers answer from the device (often blocked in some countries).
    func ping() async throws {
        let url = baseURL.appendingPathComponent("api/v3/ping")
        let (_, response) = try await URLSession.shared.data(from: url)
        try Self.checkHTTPResponse(response)
    }

    // MARK: - Signed endpoints

    /// Fetches spot balances. Throws `LiveSyncError` on credential/network/parsing errors.
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

    /// Trade history for a given pair.
    /// `symbol` required (e.g. "BTCUSDT"). Default cap 500 (Binance max = 1000).
    /// Returns an empty array if the pair doesn't exist / the user never traded it.
    ///
    /// Rate-limit cost: 10 weight per request. With a 1200/min quota → ~120 pairs/min max.
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

        // Binance returns 400 when the pair doesn't exist (e.g. PNUTUSDT for a very
        // new asset). Treated as "0 trades" rather than as an error.
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

    /// Builds a signed URLRequest for a private endpoint.
    /// Throws if URL encoding is impossible.
    private func buildSignedRequest(
        endpoint: String,
        apiKey: String,
        apiSecret: String,
        params: [String: String]
    ) throws -> URLRequest {
        // 1. Build the query with the timestamp
        var queryParams = params
        queryParams["timestamp"] = "\(Int(Date().timeIntervalSince1970 * 1000))"
        queryParams["recvWindow"] = "10000" // 10 s tolerance against the server clock

        // Encode in a stable (alphabetical) order for reproducibility (Binance
        // doesn't care, but it makes debugging cleaner).
        let sortedKeys: [String] = queryParams.keys.sorted()
        let pairs: [String] = sortedKeys.map { paramKey -> String in
            let value = queryParams[paramKey] ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(paramKey)=\(encoded)"
        }
        let queryString: String = pairs.joined(separator: "&")

        // 2. Sign with HMAC-SHA256 using apiSecret.
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

    /// Checks the HTTP status and converts it into a typed `LiveSyncError`.
    /// - 200 → OK
    /// - 401 → invalid credentials
    /// - 429 / 418 → rate limit (Binance uses 418 for a temporary ban)
    /// - others → networkError
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
