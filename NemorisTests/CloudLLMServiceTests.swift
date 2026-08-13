import Foundation
import Testing
@testable import Nemoris

/// Client des fournisseurs d'IA distants.
///
/// Les deux contrats DIFFÈRENT sur des points que rien ne signale à
/// l'exécution autrement que par un refus peu parlant : Anthropic n'utilise
/// pas d'en-tête `Authorization`, exige une version d'API, et veut les octets
/// d'image nus avec un type de média à part — là où OpenAI attend une URL de
/// données complète. Confondre les deux donne un 400 sans explication.
///
/// ⚠️ Ces tests écrivent dans le trousseau. Ils SAUVEGARDENT et RESTAURENT la
/// valeur préexistante : sans ça, les lancer effacerait une vraie clé
/// configurée sur le simulateur.
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

    // MARK: - Sans clé, aucune requête

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
        // Partir sans clé donnerait un 401 après un aller-retour inutile,
        // et un message d'erreur venant du fournisseur plutôt que de l'app.
        #expect(StubURLProtocol.requestedURLs.isEmpty)
    }

    // MARK: - Les deux contrats d'authentification

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
        // Sans cet en-tête, la requête est rejetée par un 400 peu parlant.
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

    // MARK: - Les deux encodages d'image

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

    // MARK: - Échecs

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
                // « HTTP 400 » seul n'aide personne : le vrai motif — clé
                // invalide, quota épuisé, modèle inconnu — est dans le corps.
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
                // Réessayer a du sens ici, pas sur une clé refusée.
                if case .unreachable = erreur {} else if case .timedOut = erreur {} else {
                    Issue.record("erreur : \(erreur)")
                }
            }
        }
    }
}
}
