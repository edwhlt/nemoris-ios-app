import Foundation

// MARK: - Blockstream client for Bitcoin
//
// Public Blockstream Esplora API (https://blockstream.info/api/):
//   - free, no key
//   - used by the Blockstream Green wallet in production
//   - alternative: mempool.space (same REST API)
//
// Main endpoint:
//   GET /address/{address}
//   → { chain_stats: { funded_txo_sum, spent_txo_sum, ... }, mempool_stats: {...} }
//
// Balance = (funded_txo_sum - spent_txo_sum) in satoshis, divided by 1e8 = BTC.

struct BitcoinAPIClient {

    /// Base URL of the Blockstream Esplora API. Mainnet only (testnet unsupported).
    private let baseURL = URL(string: "https://blockstream.info/api")!

    /// Fetches an address's BTC balance, in BTC units (Double).
    /// Throws a typed `LiveSyncError` on network/parsing/invalid-address errors.
    func fetchBalance(address: String) async throws -> Double {
        let url = baseURL.appendingPathComponent("address").appendingPathComponent(address)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPResponse(response, address: address)

        do {
            let parsed = try JSONDecoder().decode(BitcoinAddressResponse.self, from: data)
            // Confirmed + mempool balance (to reflect transactions being included)
            let confirmed = parsed.chain_stats.funded_txo_sum - parsed.chain_stats.spent_txo_sum
            let mempool = parsed.mempool_stats.funded_txo_sum - parsed.mempool_stats.spent_txo_sum
            let totalSats = max(0, confirmed + mempool)
            return Double(totalSats) / 100_000_000.0  // 1 BTC = 1e8 sats
        } catch {
            throw LiveSyncError.parseError("Decode Blockstream : \(error.localizedDescription)")
        }
    }

    private static func checkHTTPResponse(_ response: URLResponse, address: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.networkError("Réponse HTTP invalide")
        }
        switch http.statusCode {
        case 200..<300: return
        case 400:       throw LiveSyncError.invalidCredentials  // malformed address
        case 404:       throw LiveSyncError.networkError("Adresse Bitcoin introuvable : \(address)")
        case 429:       throw LiveSyncError.rateLimited(retryAfter: nil)
        default:        throw LiveSyncError.networkError("HTTP \(http.statusCode)")
        }
    }
}

// MARK: - DTO Esplora

/// `/address/{addr}` response — only the useful sums are kept.
private struct BitcoinAddressResponse: Decodable {
    let chain_stats: Stats
    let mempool_stats: Stats

    struct Stats: Decodable {
        let funded_txo_sum: Int    // satoshis received (total)
        let spent_txo_sum: Int     // satoshis spent (total)
    }
}
