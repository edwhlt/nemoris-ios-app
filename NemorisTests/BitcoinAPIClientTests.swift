import Foundation
import Testing
@testable import Nemoris

/// The Bitcoin client — the first suite built on the network seam.
///
/// An API client goes wrong in two ways: it misconverts what it
/// receives, or it misinterprets a failure. The first gives a wrong balance, the second
/// a message that doesn't help the user understand what to fix.
///
/// `.serialized` is mandatory: network interception is process-global
/// state, two parallel tests would fight over the response table.
extension NetworkSeam {

@Suite("BitcoinAPIClient")
struct BitcoinAPIClientTests {

    private func reponse(confirme: (Int, Int), mempool: (Int, Int) = (0, 0)) -> String {
        """
        {"chain_stats":{"funded_txo_sum":\(confirme.0),"spent_txo_sum":\(confirme.1)},
         "mempool_stats":{"funded_txo_sum":\(mempool.0),"spent_txo_sum":\(mempool.1)}}
        """
    }

    // MARK: - Conversion

    @Test("Les satoshis sont convertis en bitcoins")
    func conversionSatoshis() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // 150,000,000 sats received, 50,000,000 spent → 1 BTC.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (150_000_000, 50_000_000))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(abs(solde - 1.0) < 0.000_000_01, "solde : \(solde)")
    }

    @Test("Le mempool s'ajoute au solde confirmé")
    func mempoolInclus() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // A transaction still being confirmed must show up: without it,
        // a user who just received funds wouldn't see them.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (100_000_000, 0), mempool: (50_000_000, 0))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(abs(solde - 1.5) < 0.000_000_01, "solde : \(solde)")
    }

    @Test("Une adresse entièrement dépensée rend zéro, jamais un négatif")
    func soldeNul() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // Spent more than received — inconsistent, but a negative balance would show
        // a debt in bitcoins, which makes no sense.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (100_000, 200_000))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(solde == 0, "solde : \(solde)")
    }

    @Test("Une fraction de satoshi est préservée")
    func precisionFine() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // 1 satoshi = 0.00000001 BTC. Rounding would make it disappear.
        StubURLProtocol.on("blockstream.info", .json(reponse(confirme: (1, 0))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(solde == 0.000_000_01, "solde : \(solde)")
    }

    // MARK: - The requested address

    @Test("L'adresse demandée figure dans l'URL appelée")
    func urlAppelee() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("blockstream.info", .json(reponse(confirme: (0, 0))))

        _ = try await BitcoinAPIClient().fetchBalance(address: "bc1qexemple")

        let urls = StubURLProtocol.requestedURLs.map(\.absoluteString)
        #expect(urls.contains { $0.contains("/address/bc1qexemple") },
                "URLs appelées : \(urls)")
    }

    // MARK: - Interpreting failures

    @Test("Un 400 est présenté comme une adresse invalide")
    func adresseMalFormee() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("blockstream.info", .status(400))

        await #expect(throws: LiveSyncError.self) {
            _ = try await BitcoinAPIClient().fetchBalance(address: "pas-une-adresse")
        }
    }

    @Test("Un 429 est reconnu comme une limitation de débit")
    func limitationDeDebit() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("blockstream.info", .status(429))

        // Distinguishing this case matters: it's the only one where retrying later makes
        // sense, rather than asking the user to fix their input.
        do {
            _ = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
            Issue.record("une limitation de débit aurait dû être signalée")
        } catch let erreur as LiveSyncError {
            if case .rateLimited = erreur {} else {
                Issue.record("erreur obtenue : \(erreur)")
            }
        }
    }

    @Test("Une réponse illisible est signalée comme un défaut de format")
    func reponseIllisible() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("blockstream.info", .json("{\"inattendu\":true}"))

        do {
            _ = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
            Issue.record("un format inattendu aurait dû être signalé")
        } catch let erreur as LiveSyncError {
            if case .parseError = erreur {} else {
                Issue.record("erreur obtenue : \(erreur)")
            }
        }
    }

    @Test("Une coupure réseau remonte, elle n'est pas confondue avec un solde nul")
    func coupureReseau() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("blockstream.info", .networkFailure())

        // Returning 0 on an outage would make it look like an emptied wallet.
        await #expect(throws: (any Error).self) {
            _ = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        }
    }
}
}
