import Foundation
import Testing
@testable import Nemoris

/// Amortization math: a pure engine, no database or network.
///
/// This is the most costly calculation in the whole app to get wrong. An
/// error here is silent — the displayed remaining principal stays plausible —
/// and propagates to net worth, projections, and goals.
///
/// The strategy is twofold: INVARIANTS that hold regardless of
/// the parameters, plus a zero-rate case whose result can be computed
/// exactly by hand. A test that merely pinned down the code's current
/// output would verify nothing beyond its own reproduction.
@Suite("LoanCalculator")
struct LoanCalculatorTests {

    private func pret(_ type: LoanType,
                      principal: Double = 200_000,
                      taux: Double = 0.03,
                      mois: Int = 240,
                      differe: Int = 0,
                      debut: String = "2020-01-01") -> PatrimoineLoan {
        PatrimoineLoan(id: 1, name: "Test", loanType: type, principal: principal,
                       annualRate: taux, durationMonths: mois, deferralMonths: differe,
                       startDate: date(debut), insuranceMonthly: 0,
                       linkedRealEstateId: nil, notes: nil, createdAt: date(debut))
    }

    /// Shifts a date by a whole number of months.
    private func apres(_ mois: Int, _ depart: String = "2020-01-01") -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: mois, to: date(depart))!
    }

    // MARK: - Cas exactement calculable

    @Test("À taux nul, l'amortissement est strictement linéaire")
    func tauxNul() {
        // With no interest, the formula reduces to RC(k) = P · (1 − k/n).
        // €12,000 over 12 months: after 6 months exactly €6,000 must remain.
        let p = pret(.amortizing, principal: 12_000, taux: 0, mois: 12)

        let moitie = LoanCalculator.compute(loan: p, asOf: apres(6))
        #expect(abs(moitie.remainingCapital - 6_000) < 0.01,
                "capital restant : \(moitie.remainingCapital)")
        #expect(abs(moitie.capitalPaid - 6_000) < 0.01)
        #expect(abs(moitie.interestsPaid) < 0.01, "un prêt à 0 % ne produit aucun intérêt")

        let tiers = LoanCalculator.compute(loan: p, asOf: apres(4))
        #expect(abs(tiers.remainingCapital - 8_000) < 0.01)
    }

    // MARK: - Invariants of an amortizing loan

    @Test("Au premier jour, rien n'est remboursé ; à l'échéance, tout l'est")
    func bornesDuPret() {
        let p = pret(.amortizing)

        let debut = LoanCalculator.compute(loan: p, asOf: apres(0))
        #expect(abs(debut.remainingCapital - p.principal) < 0.01)
        #expect(debut.monthsElapsed == 0)
        #expect(!debut.isCompleted)

        let fin = LoanCalculator.compute(loan: p, asOf: apres(p.durationMonths))
        #expect(fin.remainingCapital < 1.0, "capital résiduel : \(fin.remainingCapital)")
        #expect(fin.isCompleted)
    }

    @Test("Le capital restant décroît à chaque mois, sans jamais remonter")
    func decroissanceMonotone() {
        let p = pret(.amortizing)
        var precedent = Double.infinity

        for k in stride(from: 0, through: p.durationMonths, by: 6) {
            let etat = LoanCalculator.compute(loan: p, asOf: apres(k))
            #expect(etat.remainingCapital <= precedent + 0.01,
                    "remontée au mois \(k) : \(precedent) → \(etat.remainingCapital)")
            #expect(etat.remainingCapital >= -0.01, "capital négatif au mois \(k)")
            precedent = etat.remainingCapital
        }
    }

    @Test("Capital remboursé et capital restant se somment au capital emprunté")
    func conservationDuCapital() {
        let p = pret(.amortizing)

        for k in [0, 1, 60, 120, 239, 240] {
            let etat = LoanCalculator.compute(loan: p, asOf: apres(k))
            let total = etat.remainingCapital + etat.capitalPaid
            #expect(abs(total - p.principal) < 1.0,
                    "au mois \(k) : \(etat.capitalPaid) + \(etat.remainingCapital) = \(total)")
        }
    }

    @Test("Un taux plus élevé laisse plus de capital dû à mi-parcours")
    func effetDuTaux() {
        let doux = LoanCalculator.compute(loan: pret(.amortizing, taux: 0.01), asOf: apres(120))
        let fort = LoanCalculator.compute(loan: pret(.amortizing, taux: 0.05), asOf: apres(120))

        // With a recalculated installment, a higher rate amortizes more slowly at
        // the start: the interest portion is larger there.
        #expect(fort.remainingCapital > doux.remainingCapital,
                "doux \(doux.remainingCapital) vs fort \(fort.remainingCapital)")
        #expect(fort.interestsPaid > doux.interestsPaid)
    }

    // MARK: - Autres types

    @Test("Un prêt in fine ne rembourse aucun capital avant l'échéance")
    func inFine() {
        let p = pret(.inFine, principal: 150_000, taux: 0.024, mois: 120)

        let milieu = LoanCalculator.compute(loan: p, asOf: apres(60))
        #expect(abs(milieu.remainingCapital - 150_000) < 0.01,
                "le capital d'un in fine reste entier jusqu'au terme")
        #expect(abs(milieu.capitalPaid) < 0.01)
        // Installment = interest only: P · monthly rate.
        #expect(abs(milieu.monthlyPayment - 150_000 * 0.024 / 12) < 0.01,
                "mensualité : \(milieu.monthlyPayment)")

        let fin = LoanCalculator.compute(loan: p, asOf: apres(120))
        #expect(fin.remainingCapital < 1.0)
        #expect(fin.isCompleted)
    }

    @Test("Un différé total capitalise les intérêts sans exiger de mensualité")
    func differeTotal() {
        let p = pret(.deferredTotal, principal: 100_000, taux: 0.036, mois: 240, differe: 24)

        let pendant = LoanCalculator.compute(loan: p, asOf: apres(12))
        #expect(pendant.monthlyPayment == 0, "aucune mensualité pendant un différé total")
        #expect(pendant.remainingCapital >= 100_000,
                "les intérêts se capitalisent : la dette augmente, elle ne diminue pas")

        let apresDiffere = LoanCalculator.compute(loan: p, asOf: apres(120))
        #expect(apresDiffere.monthlyPayment > 0, "l'amortissement démarre après le différé")
        #expect(apresDiffere.remainingCapital < pendant.remainingCapital)
    }

    @Test("Un différé partiel paie les intérêts et laisse le capital intact")
    func differePartiel() {
        let p = pret(.deferredPartial, principal: 100_000, taux: 0.036, mois: 240, differe: 24)

        let pendant = LoanCalculator.compute(loan: p, asOf: apres(12))
        #expect(abs(pendant.remainingCapital - 100_000) < 0.01,
                "le capital ne bouge pas tant qu'on ne paie que les intérêts")
        #expect(abs(pendant.monthlyPayment - 100_000 * 0.036 / 12) < 0.01,
                "mensualité : \(pendant.monthlyPayment)")

        let apresDiffere = LoanCalculator.compute(loan: p, asOf: apres(120))
        #expect(apresDiffere.remainingCapital < 100_000)
    }

    @Test("Un crédit renouvelable prend le capital saisi et n'est jamais terminé")
    func revolving() {
        let p = pret(.revolving, principal: 3_500, mois: 12)

        // Well beyond the nominal term: revolving credit has no maturity date.
        let etat = LoanCalculator.compute(loan: p, asOf: apres(60))
        #expect(etat.remainingCapital == 3_500)
        #expect(etat.monthlyPayment == 0, "la mensualité varie selon l'usage, on ne l'invente pas")
        #expect(!etat.isCompleted)
    }

    // MARK: - Bornes temporelles

    @Test("Un prêt pas encore débuté est signalé et garde son capital entier")
    func pretNonDebute() {
        let p = pret(.amortizing, debut: "2030-01-01")

        let etat = LoanCalculator.compute(loan: p, asOf: date("2026-01-01"))
        #expect(etat.isPending)
        #expect(abs(etat.remainingCapital - p.principal) < 0.01)
        #expect(etat.monthsElapsed == 0)
    }

    @Test("Au-delà de l'échéance, les compteurs ne débordent pas")
    func apresEcheance() {
        let p = pret(.amortizing, mois: 120)

        let etat = LoanCalculator.compute(loan: p, asOf: apres(200))
        #expect(etat.isCompleted)
        #expect(etat.monthsElapsed == 120, "les mois écoulés sont plafonnés à la durée")
        #expect(etat.remainingCapital < 1.0)
        #expect(etat.remainingCapital >= 0, "jamais de capital négatif")
    }

    @Test("La progression reste bornée entre 0 et 1")
    func progressionBornee() {
        for type in LoanType.allCases {
            for k in [0, 60, 240, 400] {
                let etat = LoanCalculator.compute(loan: pret(type, differe: type == .deferredTotal || type == .deferredPartial ? 24 : 0),
                                                  asOf: apres(k))
                #expect(etat.progressRatio >= 0 && etat.progressRatio <= 1,
                        "\(type.rawValue) au mois \(k) : \(etat.progressRatio)")
            }
        }
    }
}
