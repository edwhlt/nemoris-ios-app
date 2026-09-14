import Foundation
import Testing
@testable import Nemoris

/// The business registry client (recherche-entreprises.api.gouv.fr).
///
/// This client carries two rules that show up nowhere at runtime if they're
/// broken: the imposed order of two parameters, and the ban on putting
/// the locality inside the search term. In both cases the call succeeds and
/// returns zero results — indistinguishable from a genuinely unknown business.
///
/// ⚠️ No test here simulates a 429: this client goes through `ResilientHTTP`'s
/// shared circuit breaker, whose state is global to the process. A simulated 429 here
/// would open the breaker and make unrelated later tests fail.
extension NetworkSeam {

@Suite("CompanyRegistryClient")
struct CompanyRegistryClientTests {

    private let hote = "recherche-entreprises.api.gouv.fr"

    private func reponse(_ entreprises: [String] = []) -> String {
        "{\"results\":[\(entreprises.joined(separator: ","))],\"total_results\":\(entreprises.count)}"
    }

    private func entreprise(siren: String, nom: String) -> String {
        """
        {"siren":"\(siren)","nom_complet":"\(nom)","nom_raison_sociale":"\(nom)",
         "etat_administratif":"A","nombre_etablissements":1,
         "siege":{"siret":"\(siren)00015","adresse":"1 RUE TEST 69002 LYON",
                  "code_postal":"69002","libelle_commune":"LYON"}}
        """
    }

    private func parametres(de url: URL) -> [(String, String)] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map { ($0.name, $0.value ?? "") } ?? []
    }

    // MARK: - The two invisible rules

    @Test("Le paramètre de réponse minimale précède celui des champs inclus")
    func ordreDesParametres() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        _ = try await CompanyRegistryClient().search(CompanyRegistryQuery(q: "carrefour market"))

        let noms = parametres(de: StubURLProtocol.requestedURLs[0]).map(\.0)
        let rangMinimal = noms.firstIndex(of: "minimal")
        let rangInclude = noms.firstIndex(of: "include")
        #expect(rangMinimal != nil && rangInclude != nil, "paramètres : \(noms)")
        // The API refuses `include` placed before `minimal` and returns a
        // validation error; insertion order therefore carries meaning, despite
        // the intuition that a query string is unordered.
        #expect((rangMinimal ?? 99) < (rangInclude ?? 0),
                "ordre obtenu : \(noms)")
    }

    @Test("La localité est un filtre, jamais un mot du terme recherché")
    func localiteHorsDuTerme() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        _ = try await CompanyRegistryClient().search(
            CompanyRegistryQuery(q: "srom", codeCommune: "69385"))

        let params = Dictionary(uniqueKeysWithValues: parametres(de: StubURLProtocol.requestedURLs[0]))
        // Measured against the real API: "carrefour market flanches" returns 0 results
        // while "carrefour market" returns 1411. The place name doesn't narrow
        // the search, it makes it fail.
        #expect(params["q"] == "srom", "terme envoyé : \(params["q"] ?? "nil")")
        #expect(params["code_commune"] == "69385")
    }

    // MARK: - Filters

    @Test("Un filtre géographique absent n'est pas envoyé")
    func filtresOptionnels() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        _ = try await CompanyRegistryClient().search(CompanyRegistryQuery(q: "boulangerie"))

        let noms = parametres(de: StubURLProtocol.requestedURLs[0]).map(\.0)
        // Sending an empty `code_postal=` would filter on the empty string and
        // never return anything.
        #expect(!noms.contains("code_commune"))
        #expect(!noms.contains("code_postal"))
        #expect(!noms.contains("departement"))
    }

    @Test("Le nombre de résultats demandé reste dans les bornes de l'API")
    func bornesDuNombreDeResultats() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))
        let client = CompanyRegistryClient()

        _ = try await client.search(CompanyRegistryQuery(q: "a", perPage: 500))
        _ = try await client.search(CompanyRegistryQuery(q: "b", perPage: 0))

        let valeurs = StubURLProtocol.requestedURLs.compactMap { url in
            parametres(de: url).first { $0.0 == "per_page" }?.1
        }
        // Out of bounds, the API rejects the whole request rather than correcting it.
        #expect(valeurs == ["25", "1"], "obtenu : \(valeurs)")
    }

    @Test("Le filtre d'état administratif accompagne la requête par défaut")
    func etatAdministratifParDefaut() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        _ = try await CompanyRegistryClient().search(CompanyRegistryQuery(q: "test"))

        let params = Dictionary(uniqueKeysWithValues: parametres(de: StubURLProtocol.requestedURLs[0]))
        #expect(params["etat_administratif"] == "A",
                "par défaut on ne propose pas des entreprises fermées")
    }

    // MARK: - Cache

    @Test("Une requête identique n'est pas rejouée sur le réseau")
    func cacheDesRequetes() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse([entreprise(siren: "123456789", nom: "SROM")])))
        let client = CompanyRegistryClient()

        let premier = try await client.search(CompanyRegistryQuery(q: "srom"))
        let second = try await client.search(CompanyRegistryQuery(q: "srom"))

        #expect(StubURLProtocol.requestedURLs.count == 1,
                "un import rejoue la même recherche sur des lignes jumelles : \(StubURLProtocol.requestedURLs.count) appels")
        #expect(premier.count == second.count)
    }

    @Test("Deux requêtes différentes ne partagent pas leur entrée de cache")
    func cachePropreAChaqueRequete() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))
        let client = CompanyRegistryClient()

        _ = try await client.search(CompanyRegistryQuery(q: "srom", codeCommune: "69385"))
        _ = try await client.search(CompanyRegistryQuery(q: "srom", codeCommune: "75056"))

        #expect(StubURLProtocol.requestedURLs.count == 2,
                "la commune fait partie de l'identité de la requête")
    }

    @Test("Vider le cache force une nouvelle interrogation")
    func videTheCache() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))
        let client = CompanyRegistryClient()

        _ = try await client.search(CompanyRegistryQuery(q: "srom"))
        await client.clearCache()
        _ = try await client.search(CompanyRegistryQuery(q: "srom"))

        #expect(StubURLProtocol.requestedURLs.count == 2)
    }

    // MARK: - Reading the response

    @Test("Les entreprises de la réponse sont converties en résultats")
    func lectureDesResultats() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse([
            entreprise(siren: "111111111", nom: "SROM"),
            entreprise(siren: "222222222", nom: "SROM CONSEIL")
        ])))

        let resultats = try await CompanyRegistryClient().search(CompanyRegistryQuery(q: "srom"))
        #expect(resultats.count == 2, "obtenu : \(resultats.count)")
    }

    @Test("Une recherche sans résultat rend une liste vide, pas une erreur")
    func aucunResultat() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        // "No business by this name" is a valid response: it's what
        // makes the planner move on to its next attempt.
        #expect(try await CompanyRegistryClient()
            .search(CompanyRegistryQuery(q: "inexistant")).isEmpty)
    }

    // MARK: - Proximity search

    @Test("La recherche par proximité envoie le point et le rayon")
    func rechercheParProximite() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(hote, .json(reponse()))

        _ = try await CompanyRegistryClient().searchNearPoint(
            latitude: 45.75, longitude: 4.85, radiusKm: 5, perPage: 10)

        let params = Dictionary(uniqueKeysWithValues: parametres(de: StubURLProtocol.requestedURLs[0]))
        #expect(params["lat"] == "45.75")
        #expect(params["long"] == "4.85")
        #expect(params["radius"] == "5.0")
        #expect(StubURLProtocol.requestedURLs[0].path.contains("near_point"),
                "chemin : \(StubURLProtocol.requestedURLs[0].path)")
    }
}
}
