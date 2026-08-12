import Foundation
import Testing
@testable import Nemoris

/// Client EVM (Etherscan V2, six chaînes derrière un seul point d'entrée).
///
/// La chaîne visée voyage en paramètre `chainid` : une erreur à cet endroit
/// interrogerait le bon portefeuille sur la mauvaise chaîne et rendrait un
/// solde parfaitement plausible — donc invérifiable à l'œil.
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
        // Etherscan répond en texte quand l'adresse est mal formée.
        StubURLProtocol.on(hote, .json(
            "{\"status\":\"0\",\"message\":\"NOTOK\",\"result\":\"Invalid address format\"}"))

        await #expect(throws: LiveSyncError.self) {
            _ = try await EvmAPIClient().fetchNativeBalance(address: "pas-une-adresse", chainId: 1)
        }
    }

    // MARK: - La chaîne visée

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

    // MARK: - Clé d'API

    @Test("Une clé vide est traitée comme une absence de clé")
    func cleVide() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(soldeBrut("0")))

        // Envoyer `apikey=` ferait rejeter la requête, alors que le service
        // fonctionne parfaitement sans clé — à débit réduit.
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

    // MARK: - Découverte des jetons

    @Test("Les contrats sont dédupliqués, la première occurrence gagne")
    func contratsDedupliques() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // L'historique des transferts contient plusieurs mouvements d'un même
        // jeton : sans déduplication on interrogerait N fois le même solde.
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
        // La conversion appartient à l'appelant, qui seul connaît les décimales.
        StubURLProtocol.on(hote, .json(soldeBrut("123456789012345678901234567890")))

        let brut = try await EvmAPIClient().fetchTokenBalance(
            address: "0xabc", contractAddress: "0xdef", chainId: 1)
        #expect(brut == "123456789012345678901234567890",
                "un passage par Double perdrait des chiffres significatifs")
    }

    // MARK: - Échecs

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
