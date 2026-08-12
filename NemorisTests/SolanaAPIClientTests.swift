import Foundation
import Testing
@testable import Nemoris

/// Client Solana (JSON-RPC).
///
/// Deux pièges propres à ce protocole : les quantités arrivent en **chaînes**
/// (les entiers dépassent la précision d'un JSON number) et une erreur métier
/// est renvoyée avec un **statut HTTP 200**, dans le corps. Un client qui ne
/// regarde que le code HTTP conclurait au succès sur une adresse invalide.
extension NetworkSeam {

@Suite("SolanaAPIClient")
struct SolanaAPIClientTests {

    private let hote = "api.mainnet-beta.solana.com"

    private func compteSPL(mint: String, brut: String, decimales: Int) -> String {
        """
        {"account":{"data":{"parsed":{"info":{"mint":"\(mint)",
        "tokenAmount":{"amount":"\(brut)","decimals":\(decimales)}}}}}}
        """
    }

    private func reponseTokens(_ comptes: [String]) -> String {
        "{\"result\":{\"value\":[\(comptes.joined(separator: ","))]}}"
    }

    // MARK: - Solde natif

    @Test("Les lamports sont convertis en SOL")
    func conversionLamports() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // 1 SOL = 10^9 lamports.
        StubURLProtocol.on(hote, .json("{\"result\":{\"value\":2500000000}}"))

        let solde = try await SolanaAPIClient().fetchBalance(address: "AdresseTest")
        #expect(abs(solde - 2.5) < 0.000_000_001, "solde : \(solde)")
    }

    @Test("Un portefeuille vide rend zéro")
    func soldeVide() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json("{\"result\":{\"value\":0}}"))

        #expect(try await SolanaAPIClient().fetchBalance(address: "AdresseTest") == 0)
    }

    // MARK: - Tokens SPL

    @Test("Les décimales du token ramènent la quantité à son unité affichable")
    func decimalesAppliquees() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // USDC a 6 décimales : 1 500 000 unités brutes valent 1,50 USDC.
        StubURLProtocol.on(hote, .json(reponseTokens([
            compteSPL(mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                      brut: "1500000", decimales: 6)
        ])))

        let comptes = try await SolanaAPIClient().fetchTokenAccounts(address: "AdresseTest")
        #expect(comptes.count == 1)
        #expect(abs((comptes.first?.quantity ?? 0) - 1.5) < 0.000_001,
                "quantité : \(comptes.first?.quantity ?? -1)")
    }

    @Test("Les comptes de token vidés sont écartés")
    func comptesVidesEcartes() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // Le RPC renvoie les comptes fermés avec un solde nul : les afficher
        // remplirait le portefeuille de lignes à 0 que l'utilisateur ne détient plus.
        StubURLProtocol.on(hote, .json(reponseTokens([
            compteSPL(mint: "MintActif", brut: "1000000", decimales: 6),
            compteSPL(mint: "MintVide", brut: "0", decimales: 6)
        ])))

        let comptes = try await SolanaAPIClient().fetchTokenAccounts(address: "AdresseTest")
        #expect(comptes.map(\.mintAddress) == ["MintActif"])
    }

    @Test("Une très grande quantité brute reste lisible")
    func grandeQuantite() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // C'est pour ce cas que le protocole transporte la quantité en chaîne :
        // un mème-coin à 5 décimales dépasse vite la précision d'un entier JSON.
        StubURLProtocol.on(hote, .json(reponseTokens([
            compteSPL(mint: "MintBonk", brut: "123456789000000", decimales: 5)
        ])))

        let comptes = try await SolanaAPIClient().fetchTokenAccounts(address: "AdresseTest")
        #expect(abs((comptes.first?.quantity ?? 0) - 1_234_567_890) < 1,
                "quantité : \(comptes.first?.quantity ?? -1)")
    }

    @Test("Un portefeuille sans token rend une liste vide")
    func aucunToken() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponseTokens([])))

        #expect(try await SolanaAPIClient().fetchTokenAccounts(address: "AdresseTest").isEmpty)
    }

    // MARK: - Échecs

    @Test("Une erreur RPC servie en HTTP 200 est bien détectée")
    func erreurDansUnSucces() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // Le piège central de ce protocole : le statut HTTP dit « tout va bien ».
        StubURLProtocol.on(hote, .json(
            "{\"error\":{\"code\":-32602,\"message\":\"Invalid param: WrongSize\"}}"))

        await #expect(throws: LiveSyncError.self) {
            _ = try await SolanaAPIClient().fetchBalance(address: "trop-court")
        }
    }

    @Test("Un 429 est reconnu comme une limitation de débit")
    func limitationDeDebit() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .status(429))

        do {
            _ = try await SolanaAPIClient().fetchBalance(address: "AdresseTest")
            Issue.record("une limitation de débit aurait dû être signalée")
        } catch let erreur as LiveSyncError {
            if case .rateLimited = erreur {} else { Issue.record("erreur : \(erreur)") }
        }
    }

    @Test("Une coupure réseau remonte")
    func coupureReseau() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .networkFailure())

        await #expect(throws: (any Error).self) {
            _ = try await SolanaAPIClient().fetchBalance(address: "AdresseTest")
        }
    }
}
}
