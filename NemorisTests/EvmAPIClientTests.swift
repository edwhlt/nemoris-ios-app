import Foundation
import Testing
@testable import Nemoris

/// The EVM client (Etherscan V2, six chains behind a single entry point).
///
/// The target chain travels in the `chainid` parameter: a mistake here
/// would query the right wallet on the wrong chain and return a
/// perfectly plausible balance — so unverifiable by eye.
extension NetworkSeam {

@Suite("EvmAPIClient")
struct EvmAPIClientTests {

    private let hote = "api.etherscan.io"

    private func soldeBrut(_ valeur: String) -> String {
        "{\"status\":\"1\",\"message\":\"OK\",\"result\":\"\(valeur)\"}"
    }

    private func transfert(contrat: String, symbole: String, decimales: String) -> String {
        """
        {"contractAddress":"\(contrat)","tokenName":"Jeton \(symbole)",
         "tokenSymbol":"\(symbole)","tokenDecimal":"\(decimales)"}
        """
    }

    private func reponseTransferts(_ items: [String]) -> String {
        "{\"status\":\"1\",\"message\":\"OK\",\"result\":[\(items.joined(separator: ","))]}"
    }

    // MARK: - Solde natif

    @Test("Les wei sont convertis en unité native")
    func conversionWei() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // 1 ETH = 10^18 wei.
        StubURLProtocol.on(hote, .json(soldeBrut("2500000000000000000")))

        let solde = try await EvmAPIClient().fetchNativeBalance(address: "0xabc", chainId: 1)
        #expect(abs(solde - 2.5) < 0.000_000_001, "solde : \(solde)")
    }

    @Test("Un solde non numérique est signalé plutôt que ramené à zéro")
    func soldeIllisible() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // Etherscan responds in plain text when the address is malformed.
        StubURLProtocol.on(hote, .json(
            "{\"status\":\"0\",\"message\":\"NOTOK\",\"result\":\"Invalid address format\"}"))

        await #expect(throws: LiveSyncError.self) {
            _ = try await EvmAPIClient().fetchNativeBalance(address: "pas-une-adresse", chainId: 1)
        }
    }

    // MARK: - The target chain

    @Test("La chaîne demandée est transmise dans la requête")
    func chaineTransmise() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(soldeBrut("0")))

        _ = try await EvmAPIClient().fetchNativeBalance(address: "0xabc", chainId: 137)

        let urls = StubURLProtocol.requestedURLs.map(\.absoluteString)
        #expect(urls.contains { $0.contains("chainid=137") },
                "sans le bon chainid, on lit un solde sur la mauvaise chaîne : \(urls)")
    }

    @Test("Les six chaînes déclarées se retrouvent par leur identifiant")
    func correspondanceDesChaines() {
        for (slug, identifiant) in EvmAPIClient.chainIdMap {
            #expect(EvmAPIClient.internalChainID(forEtherscanChainID: identifiant) == slug,
                    "aller-retour rompu pour \(slug)")
        }
        #expect(EvmAPIClient.chainIdMap.count == 6)
        #expect(EvmAPIClient.internalChainID(forEtherscanChainID: 999_999) == nil)
    }

    // MARK: - API key

    @Test("Une clé vide est traitée comme une absence de clé")
    func cleVide() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(soldeBrut("0")))

        // Sending `apikey=` would get the request rejected, whereas the service
        // works perfectly fine without a key — at a reduced rate.
        #expect(EvmAPIClient(apiKey: "   ").apiKey == nil)
        _ = try await EvmAPIClient(apiKey: "").fetchNativeBalance(address: "0xabc", chainId: 1)
        #expect(!StubURLProtocol.requestedURLs.contains { $0.absoluteString.contains("apikey") })
    }

    @Test("Une clé renseignée accompagne la requête, débarrassée de ses espaces")
    func cleTransmise() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(soldeBrut("0")))

        _ = try await EvmAPIClient(apiKey: "  MACLE  ").fetchNativeBalance(address: "0xabc", chainId: 1)

        #expect(StubURLProtocol.requestedURLs.contains { $0.absoluteString.contains("apikey=MACLE") },
                "URLs : \(StubURLProtocol.requestedURLs.map(\.absoluteString))")
    }

    // MARK: - Token discovery

    @Test("Les contrats sont dédupliqués, la première occurrence gagne")
    func contratsDedupliques() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // The transfer history contains several movements of the same
        // token: without deduplication, the same balance would be queried N times.
        StubURLProtocol.on(hote, .json(reponseTransferts([
            transfert(contrat: "0xAAA", symbole: "USDC", decimales: "6"),
            transfert(contrat: "0xaaa", symbole: "USDC", decimales: "6"),
            transfert(contrat: "0xBBB", symbole: "DAI", decimales: "18")
        ])))

        let contrats = try await EvmAPIClient().fetchTokenContracts(address: "0xabc", chainId: 1)
        #expect(contrats.count == 2, "obtenu : \(contrats.map(\.contractAddress))")
        #expect(contrats.allSatisfy { $0.contractAddress == $0.contractAddress.lowercased() },
                "la casse d'une adresse ne doit pas créer deux entrées")
    }

    @Test("Des décimales illisibles retombent sur la convention à 18")
    func decimalesParDefaut() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponseTransferts([
            transfert(contrat: "0xCCC", symbole: "ODD", decimales: "")
        ])))

        let contrats = try await EvmAPIClient().fetchTokenContracts(address: "0xabc", chainId: 1)
        #expect(contrats.first?.decimals == 18, "obtenu : \(contrats.first?.decimals ?? -1)")
    }

    @Test("Un portefeuille sans transfert rend une liste vide")
    func aucunTransfert() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponseTransferts([])))

        #expect(try await EvmAPIClient().fetchTokenContracts(address: "0xabc", chainId: 1).isEmpty)
    }

    @Test("Le solde d'un jeton reste en unités brutes")
    func soldeJetonBrut() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // The conversion belongs to the caller, who alone knows the decimals.
        StubURLProtocol.on(hote, .json(soldeBrut("123456789012345678901234567890")))

        let brut = try await EvmAPIClient().fetchTokenBalance(
            address: "0xabc", contractAddress: "0xdef", chainId: 1)
        #expect(brut == "123456789012345678901234567890",
                "un passage par Double perdrait des chiffres significatifs")
    }

    // MARK: - Failures

    @Test("Un 429 est reconnu comme une limitation de débit")
    func limitationDeDebit() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .status(429))

        do {
            _ = try await EvmAPIClient().fetchNativeBalance(address: "0xabc", chainId: 1)
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
            _ = try await EvmAPIClient().fetchNativeBalance(address: "0xabc", chainId: 1)
        }
    }
}
}
