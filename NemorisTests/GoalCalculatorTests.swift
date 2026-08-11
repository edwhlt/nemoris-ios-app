import Foundation
import Testing
@testable import Nemoris

/// Résolution de l'avancement d'un objectif.
///
/// La subtilité tient au fait que « où j'en suis » ne se lit pas au même
/// endroit selon la nature de l'objectif : dans les actifs liquides, dans le
/// patrimoine net, dans la dette remboursée, ou dans une valeur saisie à la
/// main. Se tromper de source donne un pourcentage crédible mais faux.
@Suite("GoalCalculator")
struct GoalCalculatorTests {

    private func objectif(_ kind: GoalKind, cible: Double,
                          saisi: Double = 0, echeance: String? = nil) -> Goal {
        Goal(id: 1, name: kind.rawValue, kind: kind, targetAmount: cible,
             deadlineDate: echeance.map { date($0) }, customCurrentAmount: saisi,
             notes: nil, createdAt: date("2026-01-01"))
    }

    private func patrimoine(actifs: Double, dettes: Double) -> PatrimoineSnapshot {
        PatrimoineSnapshot(totalAssets: actifs, totalLiabilities: dettes,
                           assetsCount: 1, realEstateCount: 0, loansCount: 1)
    }

    // MARK: - Où se lit l'avancement

    @Test("Un objectif d'épargne se lit dans les actifs liquides, pas dans le patrimoine")
    func sourceEpargne() {
        let p = GoalCalculator.progress(
            for: objectif(.savings, cible: 10_000),
            snapshot: patrimoine(actifs: 500_000, dettes: 0),
            totalAssetsValue: 2_500)

        #expect(p.currentAmount == 2_500,
                "500 000 € de patrimoine ne remplissent pas un objectif d'épargne liquide")
        #expect(abs(p.ratio - 0.25) < 0.0001)
    }

    @Test("Un objectif de patrimoine net se lit actifs moins dettes")
    func sourcePatrimoineNet() {
        let p = GoalCalculator.progress(
            for: objectif(.netWorth, cible: 100_000),
            snapshot: patrimoine(actifs: 250_000, dettes: 200_000),
            totalAssetsValue: 9_999)

        #expect(p.currentAmount == 50_000, "250 000 − 200 000")
        #expect(abs(p.ratio - 0.5) < 0.0001)
    }

    @Test("Un objectif de remboursement mesure ce qui a été remboursé")
    func sourceRemboursement() {
        // Dette initiale 200 000, il en reste 150 000 : 50 000 remboursés.
        let p = GoalCalculator.progress(
            for: objectif(.debtPayoff, cible: 200_000),
            snapshot: patrimoine(actifs: 0, dettes: 150_000),
            totalAssetsValue: 0,
            initialDebtForPayoff: 200_000)

        #expect(p.currentAmount == 50_000)
        #expect(abs(p.ratio - 0.25) < 0.0001)
    }

    @Test("Une dette qui a augmenté ne produit pas d'avancement négatif")
    func detteAugmentee() {
        // Un nouveau prêt après création de l'objectif : la dette dépasse
        // l'initiale. Un avancement négatif casserait la barre de progression.
        let p = GoalCalculator.progress(
            for: objectif(.debtPayoff, cible: 100_000),
            snapshot: patrimoine(actifs: 0, dettes: 130_000),
            totalAssetsValue: 0,
            initialDebtForPayoff: 100_000)

        #expect(p.currentAmount >= 0, "avancement : \(p.currentAmount)")
        #expect(p.ratio >= 0)
    }

    @Test("Un objectif libre prend la valeur saisie à la main")
    func sourceLibre() {
        let p = GoalCalculator.progress(
            for: objectif(.custom, cible: 1_000, saisi: 400),
            snapshot: patrimoine(actifs: 999_999, dettes: 0),
            totalAssetsValue: 999_999)

        #expect(p.currentAmount == 400, "aucune source automatique ne doit primer")
    }

    // MARK: - Bornes

    @Test("Le ratio est plafonné à 1 même en cas de dépassement")
    func ratioPlafonne() {
        let p = GoalCalculator.progress(
            for: objectif(.savings, cible: 1_000),
            snapshot: .empty, totalAssetsValue: 5_000)

        #expect(p.ratio == 1.0, "ratio : \(p.ratio)")
        #expect(p.isCompleted)
        #expect(p.amountRemaining == 0, "rien ne reste à faire une fois dépassé")
    }

    @Test("Un objectif à cible nulle n'affiche pas 100 % par accident")
    func cibleNulle() {
        // Saisie incohérente : sans garde, la division par zéro afficherait
        // « atteint » sur un objectif vide.
        let p = GoalCalculator.progress(
            for: objectif(.savings, cible: 0),
            snapshot: .empty, totalAssetsValue: 0)

        #expect(p.ratio.isFinite, "ratio non fini : \(p.ratio)")
        #expect(p.ratio == 0)
    }

    // MARK: - Effort mensuel

    @Test("L'effort mensuel répartit le reste à faire jusqu'à l'échéance")
    func effortMensuel() {
        let p = GoalCalculator.progress(
            for: objectif(.savings, cible: 12_000, echeance: "2026-07-01"),
            snapshot: .empty, totalAssetsValue: 6_000,
            asOf: date("2026-01-01"))

        // 6 000 restants sur 6 mois.
        let effort = GoalCalculator.monthlyContributionNeeded(for: p, asOf: date("2026-01-01"))
        #expect(effort != nil)
        #expect(abs((effort ?? 0) - 1_000) < 0.01, "effort : \(effort ?? -1)")
    }

    @Test("Aucun effort n'est demandé sans échéance ou sur un objectif atteint")
    func effortNonApplicable() {
        let sansEcheance = GoalCalculator.progress(
            for: objectif(.savings, cible: 10_000),
            snapshot: .empty, totalAssetsValue: 0)
        #expect(GoalCalculator.monthlyContributionNeeded(for: sansEcheance) == nil)

        let atteint = GoalCalculator.progress(
            for: objectif(.savings, cible: 1_000, echeance: "2027-01-01"),
            snapshot: .empty, totalAssetsValue: 5_000)
        #expect(GoalCalculator.monthlyContributionNeeded(for: atteint) == nil,
                "un objectif atteint ne réclame plus rien")
    }

    @Test("Une échéance dépassée ne fait pas diverger l'effort mensuel")
    func echeanceDepassee() {
        let p = GoalCalculator.progress(
            for: objectif(.savings, cible: 10_000, echeance: "2026-01-01"),
            snapshot: .empty, totalAssetsValue: 2_000,
            asOf: date("2026-06-01"))

        // Le nombre de mois est planché à 1 : sans ce garde, une échéance
        // passée donnerait une division par zéro ou un montant négatif.
        let effort = GoalCalculator.monthlyContributionNeeded(for: p, asOf: date("2026-06-01"))
        #expect(effort != nil)
        #expect((effort ?? 0) > 0 && (effort ?? 0).isFinite, "effort : \(effort ?? -1)")
        #expect(p.isOverdue)
    }
}
