import Foundation
import Testing
@testable import Nemoris

/// The Solana client (JSON-RPC).
///
/// Two traps specific to this protocol: quantities arrive as **strings**
/// (integers exceed a JSON number's precision), and a business error
/// is returned with an **HTTP 200 status**, inside the body. A client that
/// only looks at the HTTP code would conclude success on an invalid address.
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
        // USDC has 6 decimals: 1,500,000 raw units are worth 1.50 USDC.
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
        // The RPC returns closed accounts with a zero balance: displaying them
        // would fill the portfolio with 0-value lines the user no longer holds.
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
        // This is exactly why the protocol carries the quantity as a string:
        // a meme-coin with 5 decimals quickly exceeds a JSON integer's precision.
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

    // MARK: - Failures

    @Test("Une erreur RPC servie en HTTP 200 est bien détectée")
    func erreurDansUnSucces() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // The central trap of this protocol: the HTTP status says "everything's fine".
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
