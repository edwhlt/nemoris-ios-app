import Foundation

// MARK: - Client Blockstream pour Bitcoin
//
// Blockstream Esplora API publique (https://blockstream.info/api/) :
//   - gratuite, sans clé
//   - utilisée par Blockstream Green wallet en prod
//   - alternative : mempool.space (même API REST)
//
// Endpoint principal :
//   GET /address/{address}
//   → { chain_stats: { funded_txo_sum, spent_txo_sum, ... }, mempool_stats: {...} }
//
// Balance = (funded_txo_sum - spent_txo_sum) en satoshis, divisé par 1e8 = BTC.

struct BitcoinAPIClient {

    /// Base URL de l'API Esplora Blockstream. Mainnet uniquement (testnet non supporté).
    private let baseURL = URL(string: "https://blockstream.info/api")!

    /// Récupère la balance BTC d'une adresse en BTC unité (Double).
    /// Throw `LiveSyncError` typé en cas d'erreur réseau/parsing/adresse invalide.
    func fetchBalance(address: String) async throws -> Double {
        let url = baseURL.appendingPathComponent("address").appendingPathComponent(address)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPResponse(response, address: address)

        do {
            let parsed = try JSONDecoder().decode(BitcoinAddressResponse.self, from: data)
            // Balance confirmée + en mempool (pour refléter les txs en cours d'inclusion)
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
        case 400:       throw LiveSyncError.invalidCredentials  // adresse mal formée
        case 404:       throw LiveSyncError.networkError("Adresse Bitcoin introuvable : \(address)")
        case 429:       throw LiveSyncError.rateLimited(retryAfter: nil)
        default:        throw LiveSyncError.networkError("HTTP \(http.statusCode)")
        }
    }
}

// MARK: - DTO Esplora

/// Réponse `/address/{addr}` — on garde uniquement les sommes utiles.
private struct BitcoinAddressResponse: Decodable {
    let chain_stats: Stats
    let mempool_stats: Stats

    struct Stats: Decodable {
        let funded_txo_sum: Int    // satoshis reçus (total)
        let spent_txo_sum: Int     // satoshis dépensés (total)
    }
}
