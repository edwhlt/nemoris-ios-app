import Foundation

// MARK: - Bitcoin wallet provider
//
// Simple sync — a single request to Blockstream Esplora for the balance.
// Bitcoin has no tokens (in the ERC-20 sense), so one single position = native
// BTC. Ordinals/Runes/BRC-20 are out of scope (fragmented ecosystem, hard EUR
// valuation, and most personal wallets hold none).

extension BitcoinWalletLiveSyncProvider {

    func validate(credentials: [String: String], config: [String: String]) async throws {
        guard let address = credentials["address"], !address.isEmpty else {
            throw LiveSyncError.missingCredentials
        }
        let client = BitcoinAPIClient()
        // A simple balance fetch validates both connectivity AND the address format
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
        // Not implemented yet. To do:
        //   - GET /address/{addr}/txs → array of Bitcoin transactions
        //   - Parse vin/vout to identify inflows (BUY) and outflows (SELL)
        //   - For a personal wallet, each external inflow = a "purchase" (received)
        //   - EUR conversion at transaction time → needs BTC/EUR price history
        return []
    }
}
