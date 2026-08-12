import Foundation
import Testing
@testable import Nemoris

/// Agrégation des courbes de portefeuille.
///
/// La règle cardinale tient en une phrase : **le prix de revient n'entre
/// jamais dans une courbe de valorisation**. C'est un coût d'acquisition, pas
/// un cours, et il peut être sur une tout autre échelle — un titre acheté
/// 250 € qui en cote 40 faisait bondir le total à chaque pas sans cours.
/// D'où les dents de scie mesurées à 218 % d'amplitude avant ce moteur.
@Suite("Évolution de portefeuille")
struct PortfolioEvolutionEngineTests {

    private let calendrier = Calendar.current
    private let maintenant = Date()

    /// Amplitude relative creux-à-pic, en %. Sur des cours stables, une valeur
    /// élevée est la signature du dentelé.
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

    /// Deux positions d'un même PEA synchronisées à des heures DIFFÉRENTES
    /// (9 h et 17 h), donc sur des grilles d'horodatage désalignées — la
    /// configuration qui produisait le dentelé.
    ///   30 parts à ~84 € (prix de revient 71) et 45 parts à ~40 € (revient 250).
    ///   Valeur de marché ≈ 4 350 €, total au prix de revient = 13 380 €.
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

    // MARK: - La régression du dentelé

    @Test("Des séries désalignées ne produisent pas de dents de scie")
    func seriesDesalignees() {
        let resultat = PortfolioEvolutionBuilder.build(inputs: portefeuilleRealiste(),
                                                       range: .threeMonth, now: maintenant)

        let amp = amplitude(resultat.points)
        #expect(amp < 10, "amplitude = \(amp) %")
        // 13 380 € est le total au prix de revient : la courbe ne doit jamais
        // s'en approcher, c'était exactement la hauteur des pics.
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

        // Elle est SIGNALÉE à l'interface plutôt que silencieusement absente :
        // l'utilisateur doit savoir que sa courbe ne couvre pas tout.
        #expect(resultat.unpricedPositionIds == [99],
                "obtenu : \(resultat.unpricedPositionIds.sorted())")
        let sommet = resultat.points.map(\.value).max() ?? 0
        #expect(sommet < 6_000, "sommet = \(sommet) €")
    }

    // MARK: - Forme de la série

    @Test("La grille est régulière, triée et sans date en double")
    func grilleReguliere() {
        let resultat = PortfolioEvolutionBuilder.build(inputs: portefeuilleRealiste(),
                                                       range: .threeMonth, now: maintenant)
        let dates = resultat.points.map(\.date)

        // Deux valeurs au même instant créent un segment vertical dans une aire :
        // c'est le rendu « code-barres ».
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

        // 10×100 + 10×50 = 1 500 sur toute la plage, le premier cours connu de
        // B étant reporté en arrière plutôt que remplacé par son prix de revient.
        let amp = amplitude(resultat.points)
        #expect(amp < 1, "amplitude = \(amp) %")
    }

    // MARK: - Vue à la journée

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

        // Auparavant : 2 points seulement, l'union des horodatages étant quasi
        // vide sur 24 h. L'autre position est maintenue à son dernier cours réel.
        #expect(resultat.points.count >= 40, "\(resultat.points.count) points")
        #expect(amplitude(resultat.points) < 10)
    }

    @Test("La vue 1J consultée hors séance montre la dernière cotation")
    func vueJournaliereHorsSeance() {
        // Un samedi : la dernière cotation date de vendredi 17 h 30, soit 46 h
        // plus tôt. Une grille bornée à [maintenant − 24 h] ne contiendrait
        // aucun point réel et la courbe s'aplatirait sur une valeur reportée.
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

        // Une valeur non finie propagée jusqu'au graphe casse tout le rendu.
        #expect(resultat.points.allSatisfy { $0.value.isFinite })
        #expect(amplitude(resultat.points) < 1, "aucun pic créé par les valeurs invalides")
    }
}
