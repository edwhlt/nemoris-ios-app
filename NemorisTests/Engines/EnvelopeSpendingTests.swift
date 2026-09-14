import Foundation
import Testing
@testable import Nemoris

/// Computing spending per budget envelope.
///
/// This calculation existed in FOUR divergent implementations: the
/// dashboard ignored yearly envelopes, alerts ignored
/// subcategories, the widget did a third mix. So the same envelope
/// could be "overspent" in the alerts banner and "healthy" in
/// the budget banner, **on the same screen**. This engine is the single source of truth.
@Suite("Dépensé par enveloppe")
struct EnvelopeSpendingEngineTests {

    private let maintenant = Date()

    /// "Groceries" with two children, "Leisure" with none.
    private let categories: [Nemoris.Category] = [
        .init(id: 10, name: "Alimentation"),
        .init(id: 11, name: "Supermarché", parentId: 10),
        .init(id: 12, name: "Restaurant", parentId: 10),
        .init(id: 20, name: "Loisirs")
    ]

    private func enveloppe(_ id: Int, categorie: Int?, montant: Double,
                           periode: BudgetPeriod = .monthly) -> BudgetEnvelope {
        BudgetEnvelope(id: id, name: "Enveloppe \(id)", categoryId: categorie,
                       amount: montant, period: periode, startDate: maintenant, isActive: true)
    }

    /// Builds a full transaction — the amount and category are the
    /// only fields this engine looks at, the rest is padding.
    private func transaction(_ id: Int, categorie: Int?, montant: Double) -> FinanceTransaction {
        FinanceTransaction(id: id, accountId: 1, tiersId: nil, categoryId: categorie,
                           paymentTypeId: nil, remboursementTiersId: nil,
                           tiersName: "", categoryName: "", paymentTypeName: "",
                           remboursementTiersName: "", information: "",
                           libelleBrut: nil, amount: montant, date: maintenant)
    }

    private func depense(_ id: Int, categorie: Int?, _ montant: Double) -> FinanceTransaction {
        transaction(id, categorie: categorie, montant: -abs(montant))
    }

    // MARK: - Category hierarchy

    @Test("Une dépense sur une sous-catégorie compte dans l'enveloppe parente")
    func hierarchieDesCategories() {
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 400)],
            transactions: [depense(1, categorie: 11, 120),
                           depense(2, categorie: 12, 80),
                           depense(3, categorie: 10, 50),
                           depense(4, categorie: 20, 999)],
            categories: categories)

        #expect(abs(avancement[0].spent - 250) < 0.005,
                "obtenu : \(avancement[0].spent)")
        #expect(avancement[0].healthState == .healthy)
        #expect(abs(avancement[0].allocated - 400) < 0.005,
                "une enveloppe mensuelle alloue son montant tel quel")
    }

    @Test("Une enveloppe annuelle est mensualisée")
    func enveloppeAnnuelle() {
        // €1,200/year = €100/month, so €150 spent is an overspend.
        // The old dashboard compared 150 to 1,200 and concluded "healthy".
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 20, montant: 1200, periode: .yearly)],
            transactions: [depense(1, categorie: 20, 150)],
            categories: categories)

        #expect(abs(avancement[0].allocated - 100) < 0.005)
        #expect(avancement[0].healthState == .exceeded)
        #expect(avancement[0].isOverBudget)
    }

    // MARK: - Health thresholds

    @Test("Les seuils distinguent sain, vigilance et dépassement")
    func seuilsDeSante() {
        func etat(_ depenseeEnEuros: Double) -> EnvelopeHealth {
            EnvelopeSpendingCalculator.progresses(
                envelopes: [enveloppe(1, categorie: 20, montant: 100)],
                transactions: [depense(1, categorie: 20, depenseeEnEuros)],
                categories: categories)[0].healthState
        }

        #expect(etat(79) == .healthy)
        #expect(etat(80) == .warning, "le seuil de vigilance est atteint à 80 %")
        #expect(etat(100) == .warning, "consommer exactement son budget n'est pas un dépassement")
        #expect(etat(101) == .exceeded)
    }

    @Test("Le ratio brut n'est pas plafonné, contrairement à la barre")
    func ratioBrut() {
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 20, montant: 100)],
            transactions: [depense(1, categorie: 20, 250)],
            categories: categories)

        // `ratio` is a bar width, so it's capped at 1. Without `rawRatio`
        // alongside it, the extent of an overspend would be undetectable.
        #expect(abs(avancement[0].ratio - 1.0) < 0.005)
        #expect(abs(avancement[0].rawRatio - 2.5) < 0.005)
        #expect(avancement[0].healthState == .exceeded)
    }

    // MARK: - What doesn't count

    @Test("Les recettes ne comptent pas comme des dépenses")
    func recettesIgnorees() {
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 20, montant: 100),
                        enveloppe(2, categorie: nil, montant: 100)],
            transactions: [transaction(1, categorie: 20, montant: 2500),
                           depense(2, categorie: 20, 30),
                           transaction(3, categorie: nil, montant: -40)],
            categories: categories)

        #expect(abs(avancement[0].spent - 30) < 0.005,
                "un salaire versé sur une catégorie ne consomme pas son enveloppe")
        #expect(abs(avancement[1].spent - 0) < 0.005,
                "une enveloppe sans catégorie ne capte rien")
        #expect(avancement[1].healthState == .healthy, "et reste saine plutôt que dépassée")
    }

    // MARK: - Recurring share and forecast

    @Test("Le dépensé se répartit entre part récurrente et part variable")
    func partRecurrenteEtPrevisionnel() {
        let recurrent = RecurringPattern(
            id: 7, name: "Abonnement", amountAvg: -60, amountTolerance: 0.1,
            categoryId: 11, payeeId: nil, frequency: .monthly, anchorDay: 5,
            isActive: true, isManual: true, createdAt: maintenant,
            startDate: maintenant, endDate: nil)

        let previsions = [
            // Confirmed: its real transaction makes up the fixed portion.
            BudgetPrevision(id: 100, recurringPatternId: 7, amount: -60,
                            expectedDate: maintenant, status: .matched,
                            actualTransactionId: 1, notes: nil),
            // Still pending: counts toward the forecast.
            BudgetPrevision(id: 101, recurringPatternId: 7, amount: -60,
                            expectedDate: maintenant, status: .pending,
                            actualTransactionId: nil, notes: nil),
            // Dismissed by the user: doesn't count anywhere.
            BudgetPrevision(id: 102, recurringPatternId: 7, amount: -60,
                            expectedDate: maintenant, status: .skipped,
                            actualTransactionId: nil, notes: nil)
        ]

        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 400)],
            transactions: [depense(1, categorie: 11, 60), depense(2, categorie: 12, 40)],
            categories: categories, previsions: previsions, patterns: [recurrent])

        #expect(abs(avancement[0].spent - 100) < 0.005)
        #expect(abs(avancement[0].recurringSpent - 60) < 0.005, "part d'un récurrent confirmé")
        #expect(abs(avancement[0].variableSpent - 40) < 0.005, "le reste est arbitrable")
        #expect(abs(avancement[0].forecasted - 120) < 0.005,
                "confirmée + attendue, l'écartée est exclue")
    }

    @Test("L'appel minimal fonctionne sans prévision ni récurrent")
    func appelMinimal() {
        // This is the form used by the dashboard, alerts, and the
        // widget: requiring forecasts would force them to load them for nothing.
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 200)],
            transactions: [depense(1, categorie: 11, 50)],
            categories: categories)

        #expect(abs(avancement[0].spent - 50) < 0.005)
        #expect(abs(avancement[0].recurringSpent - 0) < 0.005)
        #expect(abs(avancement[0].forecasted - 0) < 0.005)
        #expect(avancement[0].categoryName == "Alimentation")
    }

    // MARK: - Summary

    @Test("La synthèse agrège les états sans les recalculer")
    func synthese() {
        // Distinct LEAF categories: an envelope set on the parent
        // would also capture the children's spending and throw off the count.
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 20, montant: 100),
                        enveloppe(2, categorie: 11, montant: 100),
                        enveloppe(3, categorie: 12, montant: 10)],
            transactions: [depense(1, categorie: 20, 30),
                           depense(2, categorie: 11, 85),
                           depense(3, categorie: 12, 90)],
            categories: categories)

        let synthese = BudgetRecap.from(avancement)
        #expect(synthese.totalCount == 3)
        #expect(synthese.healthyCount == 1)
        #expect(synthese.warningCount == 1)
        #expect(synthese.exceededCount == 1)
        #expect(synthese.hasIssue)

        #expect(BudgetRecap.from([]).totalCount == 0)
        #expect(!BudgetRecap.from([]).hasData, "aucune enveloppe n'est un état vide, pas un zéro")
    }

    // MARK: - The cross-regression

    @Test("Une sous-catégorie sur une enveloppe annuelle est enfin détectée")
    func regressionCroisee() {
        // The case the old alert engine missed twice over: it saw
        // neither the subcategory nor the monthly conversion, so it compared €0 to
        // €1,200 and never alerted.
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 1200, periode: .yearly)],
            transactions: [depense(1, categorie: 11, 130)],
            categories: categories)

        #expect(abs(avancement[0].allocated - 100) < 0.005, "mensualisée")
        #expect(abs(avancement[0].spent - 130) < 0.005, "sous-catégorie captée")
        #expect(avancement[0].healthState == .exceeded)
    }
}
