import Foundation
import Testing
@testable import Nemoris

/// Récupération d'un taux de change historique.
///
/// Le service interroge deux hébergements du même jeu de données : si le
/// premier ne répond pas, le second prend le relais. Sans ce relais, un
/// Tricount en devise étrangère resterait non converti — l'utilisateur verrait
/// des montants dans une monnaie qu'il ne peut pas comparer aux autres.
extension NetworkSeam {

@Suite("CurrencyRateService")
struct CurrencyRateServiceTests {

    private let principal = "cdn.jsdelivr.net"
    private let secours = "currency-api.pages.dev"

    // MARK: - Lecture du taux

    @Test("Le taux est lu dans la réponse de la source principale")
    func tauxPrincipal() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(principal, .json("{\"date\":\"2026-03-10\",\"usd\":{\"eur\":0.92}}"))

        let taux = try await CurrencyRateService.fetchRate(from: "USD", date: "2026-03-10")
        #expect(abs(taux - 0.92) < 0.000_01, "taux : \(taux)")
    }

    @Test("Les codes de devise sont cherchés en minuscules")
    func codesEnMinuscules() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // Le jeu de données indexe tout en minuscules ; interroger « USD »
        // tel quel ne trouverait aucune clé et déclencherait un faux échec.
        StubURLProtocol.on(principal, .json("{\"vnd\":{\"eur\":0.000038}}"))

        let taux = try await CurrencyRateService.fetchRate(from: "VND", to: "EUR", date: "2026-03-10")
        #expect(abs(taux - 0.000038) < 0.000_000_1, "taux : \(taux)")
    }

    @Test("La date demandée figure dans l'URL de la source principale")
    func dateDansURL() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(principal, .json("{\"usd\":{\"eur\":0.92}}"))

        _ = try await CurrencyRateService.fetchRate(from: "USD", date: "2025-11-04")

        // Un taux du jour appliqué à une dépense d'il y a six mois fausserait
        // silencieusement toutes les conversions du voyage.
        #expect(StubURLProtocol.requestedURLs.contains { $0.absoluteString.contains("2025-11-04") },
                "URLs : \(StubURLProtocol.requestedURLs.map(\.absoluteString))")
    }

    // MARK: - Relais vers la source de secours

    @Test("Une source principale en échec fait basculer sur le secours")
    func basculeSurSecours() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(principal, .status(404))
        StubURLProtocol.on(secours, .json("{\"usd\":{\"eur\":0.93}}"))

        let taux = try await CurrencyRateService.fetchRate(from: "USD", date: "2026-03-10")
        #expect(abs(taux - 0.93) < 0.000_01, "taux : \(taux)")
        #expect(StubURLProtocol.requestedURLs.count == 2, "les deux sources doivent être tentées")
    }

    @Test("Une réponse principale illisible fait aussi basculer")
    func basculeSurReponseIllisible() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        // Un 200 avec un corps inattendu est un échec au même titre qu'un 404 :
        // le CDN sert parfois une page d'erreur avec un statut de succès.
        StubURLProtocol.on(principal, .json("<html>Not Found</html>"))
        StubURLProtocol.on(secours, .json("{\"usd\":{\"eur\":0.91}}"))

        let taux = try await CurrencyRateService.fetchRate(from: "USD", date: "2026-03-10")
        #expect(abs(taux - 0.91) < 0.000_01, "taux : \(taux)")
    }

    @Test("Une devise absente du jeu de données fait basculer puis échouer")
    func deviseInconnue() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(principal, .json("{\"usd\":{\"gbp\":0.79}}"))
        StubURLProtocol.on(secours, .json("{\"usd\":{\"gbp\":0.79}}"))

        // La devise cible manque : mieux vaut ne rien enregistrer qu'un taux faux.
        await #expect(throws: (any Error).self) {
            _ = try await CurrencyRateService.fetchRate(from: "USD", to: "EUR", date: "2026-03-10")
        }
    }

    @Test("Les deux sources en échec remontent l'erreur")
    func deuxSourcesEnEchec() async throws {
        StubURLProtocol.start()
        defer { StubURLProtocol.stop() }
        StubURLProtocol.on(principal, .networkFailure())
        StubURLProtocol.on(secours, .networkFailure())

        // Rendre 1.0 par défaut serait pire : les montants passeraient pour
        // convertis alors qu'ils sont restés dans leur devise d'origine.
        await #expect(throws: (any Error).self) {
            _ = try await CurrencyRateService.fetchRate(from: "USD", date: "2026-03-10")
        }
    }
}
}
