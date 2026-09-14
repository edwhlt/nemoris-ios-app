import Foundation
import Testing
@testable import Nemoris

/// Fetching a historical exchange rate.
///
/// The service queries two hosts of the same dataset: if the
/// first doesn't respond, the second takes over. Without this fallback, a
/// Tricount in a foreign currency would stay unconverted — the user would see
/// amounts in a currency they can't compare to the others.
extension NetworkSeam {

@Suite("CurrencyRateService")
struct CurrencyRateServiceTests {

    private let principal = "cdn.jsdelivr.net"
    private let secours = "currency-api.pages.dev"

    // MARK: - Reading the rate

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
        // The dataset indexes everything in lowercase; querying "USD"
        // as-is would find no key and trigger a false failure.
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

        // Today's rate applied to a six-month-old expense would silently
        // skew every conversion for the trip.
        #expect(StubURLProtocol.requestedURLs.contains { $0.absoluteString.contains("2025-11-04") },
                "URLs : \(StubURLProtocol.requestedURLs.map(\.absoluteString))")
    }

    // MARK: - Falling back to the backup source

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
        // A 200 with an unexpected body is a failure just like a 404:
        // the CDN sometimes serves an error page with a success status.
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

        // The target currency is missing: better to save nothing than a wrong rate.
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

        // Returning 1.0 by default would be worse: amounts would look
        // converted while they actually stayed in their original currency.
        await #expect(throws: (any Error).self) {
            _ = try await CurrencyRateService.fetchRate(from: "USD", date: "2026-03-10")
        }
    }
}
}
