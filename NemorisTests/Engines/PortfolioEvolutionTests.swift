import Foundation
import Testing
@testable import Nemoris

/// Aggregating portfolio evolution curves.
///
/// The cardinal rule fits in one sentence: **cost basis never enters
/// a valuation curve**. It's an acquisition cost, not a
/// market price, and can sit on a completely different scale — a security bought
/// at €250 that trades at €40 made the total spike at every step with no price.
/// Hence the sawtooth measured at 218% amplitude before this engine.
@Suite("Évolution de portefeuille")
struct PortfolioEvolutionEngineTests {

    private let calendrier = Calendar.current
    private let maintenant = Date()

    /// Relative trough-to-peak amplitude, in %. On stable prices, a high
    /// value is the signature of a sawtooth.
    private func amplitude(_ points: [PortfolioEvolutionPoint]) -> Double {
        guard let bas = points.map(\.value).min(),
              let haut = points.map(\.value).max(), bas > 0 else { return 0 }
        return (haut - bas) / bas * 100
    }

    private func point(_ joursAvant: Int, heure: Int, cours: Double,
                       identifiant: String) -> InvestmentPricePoint {
        let base = calendrier.date(byAdding: .day, value: -joursAvant, to: maintenant)!
        let date = calendrier.date(bySettingHour: heure, minute: 5, second: 0, of: base)!
        return InvestmentPricePoint(id: "\(identifiant)\(joursAvant)",
                                    identifier: identifiant, date: date, close: cours)
    }

    /// Two positions in the same PEA synced at DIFFERENT times
    /// (9am and 5pm), so on misaligned timestamp grids — the
    /// configuration that produced the sawtooth.
    ///   30 shares at ~€84 (cost basis €71) and 45 shares at ~€40 (cost basis €250).
    ///   Market value ≈ €4,350, total at cost basis = €13,380.
    private func portefeuilleRealiste() -> [PortfolioSeriesInput] {
        var premiere: [InvestmentPricePoint] = []
        var seconde: [InvestmentPricePoint] = []
        for j in stride(from: 89, through: 0, by: -1) {
            premiere.append(point(j, heure: 9,
                                  cours: 84.0 + Double((89 - j) % 7) * 0.15,
                                  identifiant: "CAC.PA"))
            seconde.append(point(j, heure: 17,
                                 cours: 40.0 + Double((89 - j) % 5) * 0.08,
                                 identifiant: "EWLD.PA"))
        }
        return [PortfolioSeriesInput(positionId: 1, quantity: 30, history: premiere),
                PortfolioSeriesInput(positionId: 2, quantity: 45, history: seconde)]
    }

    // MARK: - The sawtooth regression

    @Test("Des séries désalignées ne produisent pas de dents de scie")
    func seriesDesalignees() {
        let resultat = PortfolioEvolutionBuilder.build(inputs: portefeuilleRealiste(),
                                                       range: .threeMonth, now: maintenant)

        let amp = amplitude(resultat.points)
        #expect(amp < 10, "amplitude = \(amp) %")
        // €13,380 is the total at cost basis: the curve must never
        // approach it, that was exactly the height of the spikes.
        let sommet = resultat.points.map(\.value).max() ?? 0
        #expect(sommet < 6_000, "sommet = \(sommet) €")
        #expect(resultat.unpricedPositionIds.isEmpty)
    }

    @Test("Une position sans aucun cours est exclue, jamais valorisée au prix de revient")
    func positionSansCours() {
        let orpheline = PortfolioSeriesInput(positionId: 99, quantity: 1000, history: [])

        let resultat = PortfolioEvolutionBuilder.build(
            inputs: portefeuilleRealiste() + [orpheline],
            range: .threeMonth, now: maintenant)

        // It's REPORTED to the UI rather than silently absent:
        // the user must know their curve doesn't cover everything.
        #expect(resultat.unpricedPositionIds == [99],
                "obtenu : \(resultat.unpricedPositionIds.sorted())")
        let sommet = resultat.points.map(\.value).max() ?? 0
        #expect(sommet < 6_000, "sommet = \(sommet) €")
    }

    // MARK: - Series shape

    @Test("La grille est régulière, triée et sans date en double")
    func grilleReguliere() {
        let resultat = PortfolioEvolutionBuilder.build(inputs: portefeuilleRealiste(),
                                                       range: .threeMonth, now: maintenant)
        let dates = resultat.points.map(\.date)

        // Two values at the same instant create a vertical segment in an area:
        // that's the "barcode" rendering.
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count,
                "\(dates.count) points, \(Set(dates).count) uniques")
        #expect(resultat.points.count <= 160, "nombre de points borné")
    }

    @Test("Le back-fill évite la marche d'escalier d'une position démarrée tard")
    func backFill() {
        var complete: [InvestmentPricePoint] = []
        var tardive: [InvestmentPricePoint] = []
        for j in stride(from: 89, through: 0, by: -1) {
            complete.append(point(j, heure: 9, cours: 100, identifiant: "A"))
            if j <= 10 { tardive.append(point(j, heure: 17, cours: 50, identifiant: "B")) }
        }

        let resultat = PortfolioEvolutionBuilder.build(
            inputs: [PortfolioSeriesInput(positionId: 1, quantity: 10, history: complete),
                     PortfolioSeriesInput(positionId: 2, quantity: 10, history: tardive)],
            range: .threeMonth, now: maintenant)

        // 10×100 + 10×50 = 1,500 across the whole range, B's first known price
        // being carried backward rather than replaced by its cost basis.
        let amp = amplitude(resultat.points)
        #expect(amp < 1, "amplitude = \(amp) %")
    }

    // MARK: - Day view

    @Test("La vue 1J reste utilisable quand une seule position a de l'intraday")
    func vueJournaliereMixte() {
        var intraday: [InvestmentPricePoint] = []
        for pas in stride(from: 47, through: 0, by: -1) {
            intraday.append(InvestmentPricePoint(
                id: "I\(pas)", identifier: "CAC.PA",
                date: maintenant.addingTimeInterval(-Double(pas) * 1800),
                close: 84.0 + Double(47 - pas) * 0.01))
        }
        let quotidienSeul = portefeuilleRealiste()[1]

        let resultat = PortfolioEvolutionBuilder.build(
            inputs: [PortfolioSeriesInput(positionId: 1, quantity: 30, history: intraday),
                     quotidienSeul],
            range: .oneDay, now: maintenant)

        // Before: only 2 points, the union of timestamps being nearly
        // empty over 24h. The other position is kept at its last real price.
        #expect(resultat.points.count >= 40, "\(resultat.points.count) points")
        #expect(amplitude(resultat.points) < 10)
    }

    @Test("La vue 1J consultée hors séance montre la dernière cotation")
    func vueJournaliereHorsSeance() {
        // A Saturday: the last quote dates from Friday 5:30pm, 46h
        // earlier. A grid bounded to [now − 24h] would contain
        // no real point and the curve would flatten to a carried-forward value.
        var seance: [InvestmentPricePoint] = []
        let derniereCotation = maintenant.addingTimeInterval(-46 * 3600)
        for pas in stride(from: 15, through: 0, by: -1) {
            seance.append(InvestmentPricePoint(
                id: "S\(pas)", identifier: "EWLD.PA",
                date: derniereCotation.addingTimeInterval(-Double(pas) * 1800),
                close: 40.0 + Double(15 - pas) * 0.02))
        }

        let resultat = PortfolioEvolutionBuilder.build(
            inputs: [PortfolioSeriesInput(positionId: 1, quantity: 100, history: seance)],
            range: .oneDay, now: maintenant)

        #expect(resultat.points.count >= 15, "\(resultat.points.count) points")
        #expect(amplitude(resultat.points) > 0.1, "la variation de la séance reste visible")
        #expect(resultat.points.last.map { $0.date <= maintenant } ?? false,
                "la grille ne dépasse pas l'instant présent")
        #expect(resultat.unpricedPositionIds.isEmpty)
    }

    // MARK: - Robustesse

    @Test("Les cours négatifs ou non finis sont écartés sans déformer la courbe")
    func coursDegeneres() {
        var series: [InvestmentPricePoint] = []
        for j in stride(from: 30, through: 0, by: -1) {
            series.append(point(j, heure: 9, cours: j % 5 == 0 ? -1 : 100, identifiant: "D"))
        }
        series.append(InvestmentPricePoint(id: "nan", identifier: "D",
                                           date: maintenant, close: .nan))

        let resultat = PortfolioEvolutionBuilder.build(
            inputs: [PortfolioSeriesInput(positionId: 1, quantity: 10, history: series)],
            range: .threeMonth, now: maintenant)

        // A non-finite value propagated to the chart breaks the whole render.
        #expect(resultat.points.allSatisfy { $0.value.isFinite })
        #expect(amplitude(resultat.points) < 1, "aucun pic créé par les valeurs invalides")
    }
}
