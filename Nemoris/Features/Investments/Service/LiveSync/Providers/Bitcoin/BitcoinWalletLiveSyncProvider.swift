import Foundation

// MARK: - AXE I Couche 3a — Provider Bitcoin Wallet (impl réelle)
//
// Sync simple — 1 seule requête vers Blockstream Esplora pour la balance.
// Bitcoin n'a pas de tokens (au sens ERC-20), donc 1 position unique = BTC native.
// Les Ordinals/Runes/BRC-20 sont hors scope MVP (écosystème fragmenté, valorisation
// EUR difficile, et la majorité des wallets perso n'en détiennent pas).

extension BitcoinWalletLiveSyncProvider {

    func validate(credentials: [String: String], config: [String: String]) async throws {
        guard let address = credentials["address"], !address.isEmpty else {
            throw LiveSyncError.missingCredentials
        }
        let client = BitcoinAPIClient()
        // Simple balance fetch valide à la fois la connectivité ET le format de l'adresse
        _ = try await client.fetchBalance(address: address)
    }

    func fetchPositions(credentials: [String: String], config: [String: String]) async throws -> [LiveSyncPosition] {
        guard let address = credentials["address"], !address.isEmpty else {
            throw LiveSyncError.missingCredentials
        }

        let client = BitcoinAPIClient()
        let btcBalance = try await client.fetchBalance(address: address)
        guard btcBalance > 0 else { return [] }

        // Conversion EUR via CoinGecko
        let prices = await PriceResolver.shared.resolveNativePrices(tickers: ["BTC"])
        let btcPriceEUR = prices["BTC"]

        return [
            LiveSyncPosition(
                assetType: "crypto",
                assetName: "Bitcoin",
                ticker: "BTC",
                quantity: btcBalance,
                currentValueEUR: btcPriceEUR.map { $0 * btcBalance },
                metadata: [
                    "address": address,
                    "isNative": "true"
                ]
            )
        ]
    }

    func fetchTransactions(credentials: [String: String], config: [String: String], since: Date?) async throws -> [LiveSyncTransaction] {
        // Stub Couche 3a. À venir :
        //   - GET /address/{addr}/txs → array de transactions Bitcoin
        //   - Parsing vin/vout pour identifier les entrées (BUY) et sorties (SELL)
        //   - Pour un wallet perso, chaque entrée externe = "achat" (qu'on a reçu)
        //   - Conversion EUR au moment de la tx → besoin d'historique de prix BTC/EUR
        return []
    }
}
