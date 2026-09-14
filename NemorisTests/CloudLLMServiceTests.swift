import Foundation
import Testing
@testable import Nemoris

/// A client for remote AI providers.
///
/// The two contracts DIFFER in ways nothing signals at
/// runtime other than an unhelpful refusal: Anthropic doesn't use an
/// `Authorization` header, requires an API version, and wants raw
/// image bytes with a separate media type — where OpenAI expects a full data
/// URL. Confusing the two gives a 400 with no explanation.
///
/// ⚠️ These tests write to the keychain. They SAVE and RESTORE the
/// pre-existing value: without that, running them would wipe out a real
/// key configured on the simulator.
extension NetworkSeam {

@Suite("CloudLLMService")
struct CloudLLMServiceTests {

    private func avecCle(_ fournisseur: AICloudProvider, _ cle: String,
                         _ corps: () async throws -> Void) async rethrows {
        let precedente = CloudLLMKeychain.load(fournisseur)
        CloudLLMKeychain.save(cle, for: fournisseur)
        defer { CloudLLMKeychain.save(precedente ?? "", for: fournisseur) }
        try await corps()
    }

    private func reponseClaude(_ texte: String) -> String {
        "{\"content\":[{\"type\":\"text\",\"text\":\"\(texte)\"}]}"
    }

    private func reponseOpenAI(_ texte: String) -> String {
        "{\"choices\":[{\"message\":{\"content\":\"\(texte)\"}}]}"
    }

    // MARK: - No key, no request

    @Test("Sans clé configurée, rien ne part sur le réseau")
    func sansCle() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }

        try await avecCle(.claude, "") {
            await #expect(throws: CloudLLMError.self) {
                _ = try await CloudLLMService(provider: .claude)
                    .complete(systemPrompt: "sys", userPrompt: "usr")
            }
        }
        // Proceeding without a key would give a 401 after a pointless round trip,
        // and an error message coming from the provider rather than the app.
        #expect(StubURLProtocol.requestedURLs.isEmpty)
    }

    // MARK: - The two authentication contracts

    @Test("Anthropic s'authentifie par en-tête dédié et impose sa version d'API")
    func authentificationClaude() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.anthropic.com", .json(reponseClaude("bonjour")))

        try await avecCle(.claude, "CLE-TEST") {
            let texte = try await CloudLLMService(provider: .claude)
                .complete(systemPrompt: "sys", userPrompt: "usr")
            #expect(texte == "bonjour")
        }

        let requete = try #require(StubURLProtocol.requests.first)
        #expect(requete.header("x-api-key") == "CLE-TEST")
        // Without this header, the request is rejected with an unhelpful 400.
        #expect(requete.header("anthropic-version") == "2023-06-01")
        #expect(requete.header("Authorization") == nil,
                "Anthropic n'utilise pas le porteur OAuth")
    }

    @Test("OpenAI s'authentifie par porteur")
    func authentificationOpenAI() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.openai.com", .json(reponseOpenAI("salut")))

        try await avecCle(.openAI, "CLE-TEST") {
            let texte = try await CloudLLMService(provider: .openAI)
                .complete(systemPrompt: "sys", userPrompt: "usr")
            #expect(texte == "salut")
        }

        let requete = try #require(StubURLProtocol.requests.first)
        #expect(requete.header("Authorization") == "Bearer CLE-TEST")
        #expect(requete.header("x-api-key") == nil)
    }

    @Test("Chaque fournisseur a son propre point d'entrée")
    func pointsDEntree() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.onAny(.json(reponseClaude("ok")))

        try await avecCle(.claude, "K") {
            _ = try? await CloudLLMService(provider: .claude)
                .complete(systemPrompt: "s", userPrompt: "u")
        }
        #expect(StubURLProtocol.requestedURLs.first?.host == "api.anthropic.com")
    }

    // MARK: - The two image encodings

    @Test("Anthropic reçoit les octets nus et le type de média séparément")
    func imageClaude() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.anthropic.com", .json(reponseClaude("vu")))

        try await avecCle(.claude, "K") {
            _ = try await CloudLLMService(provider: .claude).complete(
                systemPrompt: "sys", userPrompt: "usr",
                imageDataURL: "data:image/png;base64,QUJD")
        }

        let corps = try #require(StubURLProtocol.requests.first).bodyText
        #expect(corps.contains("\"media_type\":\"image\\/png\"")
                || corps.contains("\"media_type\":\"image/png\""),
                "le type de média voyage à part")
        #expect(corps.contains("\"QUJD\""), "les octets sont nus, sans le préfixe de l'URL")
        #expect(!corps.contains("data:image/png;base64,QUJD"),
                "envoyer l'URL complète à Anthropic ferait échouer la lecture")
    }

    @Test("OpenAI reçoit l'URL de données complète")
    func imageOpenAI() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.openai.com", .json(reponseOpenAI("vu")))

        try await avecCle(.openAI, "K") {
            _ = try await CloudLLMService(provider: .openAI).complete(
                systemPrompt: "sys", userPrompt: "usr",
                imageDataURL: "data:image/png;base64,QUJD")
        }

        let corps = try #require(StubURLProtocol.requests.first).bodyText
        #expect(corps.contains("image_url"))
        #expect(corps.contains("base64,QUJD"), "l'URL de données part entière")
    }

    @Test("Sans image, aucune partie visuelle n'est envoyée")
    func sansImage() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.openai.com", .json(reponseOpenAI("ok")))

        try await avecCle(.openAI, "K") {
            _ = try await CloudLLMService(provider: .openAI)
                .complete(systemPrompt: "sys", userPrompt: "usr")
        }

        let corps = try #require(StubURLProtocol.requests.first).bodyText
        #expect(!corps.contains("image_url"), "une partie vide ferait rejeter la requête")
        #expect(corps.contains("usr"), "l'invite utilisateur est bien présente")
    }

    // MARK: - Failures

    @Test("Un refus remonte le motif du fournisseur, pas un code nu")
    func refusExplicite() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.anthropic.com",
                           .json("{\"error\":{\"message\":\"credit balance is too low\"}}",
                                 statusCode: 400))

        try await avecCle(.claude, "K") {
            do {
                _ = try await CloudLLMService(provider: .claude)
                    .complete(systemPrompt: "s", userPrompt: "u")
                Issue.record("un refus aurait dû être signalé")
            } catch let erreur as CloudLLMError {
                // "HTTP 400" alone helps no one: the real reason — an invalid
                // key, exhausted quota, an unknown model — is in the body.
                #expect("\(erreur)".contains("credit balance") || "\(erreur)".contains("400"),
                        "erreur : \(erreur)")
            }
        }
    }

    @Test("Une réponse vide est signalée plutôt que rendue telle quelle")
    func reponseVide() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.anthropic.com", .json("{\"content\":[]}"))

        try await avecCle(.claude, "K") {
            await #expect(throws: CloudLLMError.self) {
                _ = try await CloudLLMService(provider: .claude)
                    .complete(systemPrompt: "s", userPrompt: "u")
            }
        }
    }

    @Test("Une coupure réseau est distinguée d'un refus")
    func coupureReseau() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on("api.openai.com", .networkFailure())

        try await avecCle(.openAI, "K") {
            do {
                _ = try await CloudLLMService(provider: .openAI)
                    .complete(systemPrompt: "s", userPrompt: "u")
                Issue.record("une coupure aurait dû être signalée")
            } catch let erreur as CloudLLMError {
                // Retrying makes sense here, not on a rejected key.
                if case .unreachable = erreur {} else if case .timedOut = erreur {} else {
                    Issue.record("erreur : \(erreur)")
                }
            }
        }
    }
}
}
