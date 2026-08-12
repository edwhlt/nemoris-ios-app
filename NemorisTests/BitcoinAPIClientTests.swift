import Foundation
import Testing
@testable import Nemoris

/// Client Bitcoin — première suite bâtie sur la couture réseau.
///
/// Un client d'API se trompe de deux façons : il convertit mal ce qu'il reçoit,
/// ou il interprète mal un échec. La première donne un solde faux, la seconde
/// un message qui n'aide pas l'utilisateur à comprendre quoi corriger.
///
/// `.serialized` est obligatoire : l'interception réseau est un état global du
/// processus, deux tests parallèles se disputeraient la table des réponses.
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

        // 150 000 000 sats reçus, 50 000 000 dépensés → 1 BTC.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (150_000_000, 50_000_000))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(abs(solde - 1.0) < 0.000_000_01, "solde : \(solde)")
    }

    @Test("Le mempool s'ajoute au solde confirmé")
    func mempoolInclus() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // Une transaction en cours d'inclusion doit apparaître : sans elle,
        // l'utilisateur qui vient de recevoir des fonds ne les verrait pas.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (100_000_000, 0), mempool: (50_000_000, 0))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(abs(solde - 1.5) < 0.000_000_01, "solde : \(solde)")
    }

    @Test("Une adresse entièrement dépensée rend zéro, jamais un négatif")
    func soldeNul() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // Dépensé plus que reçu — incohérent, mais un solde négatif afficherait
        // une dette en bitcoins, ce qui n'a aucun sens.
        StubURLProtocol.on("blockstream.info",
                           .json(reponse(confirme: (100_000, 200_000))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(solde == 0, "solde : \(solde)")
    }

    @Test("Une fraction de satoshi est préservée")
    func precisionFine() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        // 1 satoshi = 0,000 000 01 BTC. Un arrondi le ferait disparaître.
        StubURLProtocol.on("blockstream.info", .json(reponse(confirme: (1, 0))))

        let solde = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        #expect(solde == 0.000_000_01, "solde : \(solde)")
    }

    // MARK: - L'adresse demandée

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

    // MARK: - Interprétation des échecs

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

        // Distinguer ce cas compte : c'est le seul où réessayer plus tard a du
        // sens, plutôt que de demander à l'utilisateur de corriger sa saisie.
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

        // Rendre 0 en cas de coupure ferait croire à un portefeuille vidé.
        await #expect(throws: (any Error).self) {
            _ = try await BitcoinAPIClient().fetchBalance(address: "bc1qtest")
        }
    }
}
}
