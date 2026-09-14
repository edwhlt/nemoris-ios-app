import Foundation
import Testing
@testable import Nemoris

/// The dashboard's snapshot layer: period bounds, dependencies
/// between aggregates, and above all the CACHE BY SCOPE.
///
/// Without this cache, changing the displayed month would recompute the budget, net
/// worth, alerts, and insights — even though none of them look at
/// the displayed month. The two invalidation tests exist to prevent this
/// regression, otherwise invisible except as sluggishness on screen.
@Suite("Instantané du tableau de bord")
struct DashboardSnapshotEngineTests {

    private func jour(_ date: Date) -> (Int, Int, Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Period bounds

    @Test("L'exercice couvre du 1er janvier au 31 décembre")
    func bornesDeLExercice() throws {
        let periode = DashboardPeriod(year: 2026, month: nil)

        #expect(jour(periode.yearFrom) == (2026, 1, 1))
        #expect(jour(periode.yearTo) == (2026, 12, 31))
        #expect(jour(periode.filterFrom) == jour(periode.yearFrom),
                "sans filtre de mois, le détail couvre l'exercice")
        #expect(jour(periode.filterTo) == jour(periode.yearTo))
        #expect(periode.monthLabel == nil)

        let debutNMoins1 = try #require(periode.previousYearFrom)
        let finNMoins1 = try #require(periode.previousYearTo)
        #expect(jour(debutNMoins1) == (2025, 1, 1))
        #expect(jour(finNMoins1) == (2025, 12, 31))
    }

    @Test("Le filtre de mois borne la fenêtre de détail")
    func filtreDeMois() {
        let juillet = DashboardPeriod(year: 2026, month: "2026-07")
        #expect(jour(juillet.filterFrom) == (2026, 7, 1))
        #expect(jour(juillet.filterTo) == (2026, 7, 31))
        #expect(juillet.monthLabel != nil)

        // The "+1 month −1 day" calculation must stay within the year.
        let decembre = DashboardPeriod(year: 2026, month: "2026-12")
        #expect(jour(decembre.filterTo) == (2026, 12, 31), "décembre ne déborde pas sur janvier")

        // No month length is hardcoded: the calendar does the work.
        let fevrier = DashboardPeriod(year: 2024, month: "2024-02")
        #expect(jour(fevrier.filterTo) == (2024, 2, 29), "année bissextile")
    }

    @Test("Un mois mal formé retombe sur l'année entière")
    func moisMalForme() {
        // Parsing is manual — a DateFormatter isn't Sendable — so it's
        // necessary to verify an invalid input doesn't produce a bogus date.
        for entree in ["2026-13", "n'importe quoi", "2026", "2026-07-15", ""] {
            let periode = DashboardPeriod(year: 2026, month: entree)
            #expect(jour(periode.filterFrom) == (2026, 1, 1), "« \(entree) »")
            #expect(jour(periode.filterTo) == (2026, 12, 31), "« \(entree) »")
        }
    }

    // MARK: - Dependencies between aggregates

    @Test("Un agrégat tire ses dépendances avec lui")
    func dependancesResolues() {
        #expect(DashboardAggregate.expanded([.alerts]).contains(.budgetEnvelopes),
                "les alertes lisent l'avancement des enveloppes")
        #expect(DashboardAggregate.expanded([.insights]) == [.insights],
                "un agrégat sans dépendance reste seul")
    }

    @Test("L'ordre d'évaluation place les producteurs avant leurs consommateurs")
    func ordreDEvaluation() {
        let ordre = DashboardAggregate.evaluationOrder

        #expect(Set(ordre) == Set(DashboardAggregate.allCases), "aucun agrégat oublié")
        #expect(ordre.count == DashboardAggregate.allCases.count, "aucun doublon")

        for agregat in DashboardAggregate.allCases {
            guard let rang = ordre.firstIndex(of: agregat) else { continue }
            for requis in agregat.requires {
                guard let rangRequis = ordre.firstIndex(of: requis) else { continue }
                // Otherwise a consumer would read a snapshot that's still empty.
                #expect(rangRequis < rang, "\(requis.rawValue) doit précéder \(agregat.rawValue)")
            }
        }
    }

    // MARK: - Cache by scope

    @Test("Changer de mois n'invalide que les catégories et les tags")
    func invalidationParMois() {
        let jeton = UUID()
        let avant = DashboardCacheKey(refreshToken: jeton,
                                      period: DashboardPeriod(year: 2026, month: nil))
        let apres = DashboardCacheKey(refreshToken: jeton,
                                      period: DashboardPeriod(year: 2026, month: "2026-07"))

        let invalides = DashboardAggregate.allCases.filter {
            avant.unitKey(for: $0) != apres.unitKey(for: $0)
        }
        #expect(Set(invalides) == [.categoryBreakdown, .tagBreakdown],
                "invalidés : \(invalides.map(\.rawValue).sorted())")
    }

    @Test("Changer d'exercice épargne les agrégats « au présent »")
    func invalidationParExercice() {
        let jeton = UUID()
        let avant = DashboardCacheKey(refreshToken: jeton,
                                      period: DashboardPeriod(year: 2026, month: nil))
        let apres = DashboardCacheKey(refreshToken: jeton,
                                      period: DashboardPeriod(year: 2025, month: nil))

        let invalides = Set(DashboardAggregate.allCases.filter {
            avant.unitKey(for: $0) != apres.unitKey(for: $0)
        })
        #expect(invalides.contains(.yearSeries))
        #expect(invalides.contains(.categoryBreakdown) && invalides.contains(.tagBreakdown))
        // Budget, net worth, investments, alerts, and insights all pertain to
        // "now": the displayed fiscal year doesn't affect them.
        #expect(invalides.isDisjoint(with: [.patrimoine, .budgetEnvelopes,
                                            .insights, .investments, .alerts]),
                "invalidés : \(invalides.map(\.rawValue).sorted())")
    }

    @Test("Une mutation de données invalide tout")
    func invalidationTotale() {
        let periode = DashboardPeriod(year: 2026, month: "2026-03")
        let avant = DashboardCacheKey(refreshToken: UUID(), period: periode)
        let apres = DashboardCacheKey(refreshToken: UUID(), period: periode)

        let stables = DashboardAggregate.allCases.filter {
            avant.unitKey(for: $0) == apres.unitKey(for: $0)
        }
        #expect(stables.isEmpty, "aucun agrégat ne survit : \(stables.map(\.rawValue))")
    }

    // MARK: - Merging the two passes

    @Test("La passe lourde complète la passe légère sans l'effacer")
    func fusionDesPasses() {
        var legere = DashboardSnapshot()
        legere.stats = .empty
        legere.budget = .empty

        var lourde = DashboardSnapshot()
        lourde.insights = [Insight(id: "test", kind: .categoryDrift, title: "Titre",
                                   detail: "Détail", annualImpact: 120,
                                   actionability: 3, confidence: 0.8)]

        let fusion = legere.merging(lourde)

        #expect(fusion.stats != nil, "les statistiques de la passe légère survivent")
        #expect(fusion.budget != nil)
        #expect(fusion.insights?.count == 1)
        // `nil` isn't "zero": it's "not computed yet", which shows
        // the card's skeleton rather than an empty screen.
        #expect(fusion.patrimoine == nil)
    }

    @Test("Une passe vide n'efface rien")
    func passeVideInoffensive() {
        var legere = DashboardSnapshot()
        legere.stats = .empty

        let inchange = legere.merging(DashboardSnapshot())
        #expect(inchange.stats != nil, "un agrégat sans donnée ne doit pas effacer l'existant")
    }

    // MARK: - Aggregate cost

    @Test("Seules les analyses sont différées en seconde passe")
    func agregatsCouteux() {
        let couteux = DashboardAggregate.allCases.filter(\.isExpensive)
        #expect(couteux == [.insights], "trouvés : \(couteux.map(\.rawValue))")
        // They do their own 180-day scan: sharing a source would
        // load it twice, once per pass.
        #expect(DashboardAggregate.insights.sources.isEmpty)
    }
}
