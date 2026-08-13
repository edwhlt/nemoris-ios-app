import Foundation
import Testing
@testable import Nemoris

/// Calcul du dépensé par enveloppe budgétaire.
///
/// Ce calcul a existé en QUATRE implémentations divergentes : le tableau de
/// bord ignorait les enveloppes annuelles, les alertes ignoraient les
/// sous-catégories, le widget faisait un troisième mélange. Une même enveloppe
/// pouvait donc être « dépassée » dans le bandeau d'alertes et « saine » dans
/// le bandeau budget, **sur le même écran**. Ce moteur est l'unique source.
@Suite("Dépensé par enveloppe")
struct EnvelopeSpendingEngineTests {

    private let maintenant = Date()

    /// « Alimentation » avec deux enfants, « Loisirs » sans enfant.
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

    /// Fabrique une transaction complète — le montant et la catégorie sont les
    /// seuls champs que ce moteur regarde, le reste est du remplissage.
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

    // MARK: - Hiérarchie des catégories

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
        // 1 200 €/an = 100 €/mois, donc 150 € dépensés est un dépassement.
        // L'ancien tableau de bord comparait 150 à 1 200 et concluait « saine ».
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 20, montant: 1200, periode: .yearly)],
            transactions: [depense(1, categorie: 20, 150)],
            categories: categories)

        #expect(abs(avancement[0].allocated - 100) < 0.005)
        #expect(avancement[0].healthState == .exceeded)
        #expect(avancement[0].isOverBudget)
    }

    // MARK: - Seuils de santé

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

        // `ratio` est une largeur de barre, donc plafonné à 1. Sans `rawRatio`
        // à côté, l'ampleur d'un dépassement serait indétectable.
        #expect(abs(avancement[0].ratio - 1.0) < 0.005)
        #expect(abs(avancement[0].rawRatio - 2.5) < 0.005)
        #expect(avancement[0].healthState == .exceeded)
    }

    // MARK: - Ce qui ne compte pas

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

    // MARK: - Part récurrente et prévisionnel

    @Test("Le dépensé se répartit entre part récurrente et part variable")
    func partRecurrenteEtPrevisionnel() {
        let recurrent = RecurringPattern(
            id: 7, name: "Abonnement", amountAvg: -60, amountTolerance: 0.1,
            categoryId: 11, payeeId: nil, frequency: .monthly, anchorDay: 5,
            isActive: true, isManual: true, createdAt: maintenant,
            startDate: maintenant, endDate: nil)

        let previsions = [
            // Confirmée : sa transaction réelle constitue la part fixe.
            BudgetPrevision(id: 100, recurringPatternId: 7, amount: -60,
                            expectedDate: maintenant, status: .matched,
                            actualTransactionId: 1, notes: nil),
            // Encore attendue : compte au prévisionnel.
            BudgetPrevision(id: 101, recurringPatternId: 7, amount: -60,
                            expectedDate: maintenant, status: .pending,
                            actualTransactionId: nil, notes: nil),
            // Écartée par l'utilisateur : ne compte nulle part.
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
        // C'est la forme utilisée par le tableau de bord, les alertes et le
        // widget : exiger les prévisions les obligerait à les charger pour rien.
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 200)],
            transactions: [depense(1, categorie: 11, 50)],
            categories: categories)

        #expect(abs(avancement[0].spent - 50) < 0.005)
        #expect(abs(avancement[0].recurringSpent - 0) < 0.005)
        #expect(abs(avancement[0].forecasted - 0) < 0.005)
        #expect(avancement[0].categoryName == "Alimentation")
    }

    // MARK: - Synthèse

    @Test("La synthèse agrège les états sans les recalculer")
    func synthese() {
        // Catégories FEUILLES distinctes : une enveloppe posée sur la parente
        // capterait aussi les dépenses des filles et fausserait le décompte.
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

    // MARK: - La régression croisée

    @Test("Une sous-catégorie sur une enveloppe annuelle est enfin détectée")
    func regressionCroisee() {
        // Le cas que l'ancien moteur d'alertes ratait deux fois : il ne voyait
        // ni la sous-catégorie ni la mensualisation, donc comparait 0 € à
        // 1 200 € et n'alertait jamais.
        let avancement = EnvelopeSpendingCalculator.progresses(
            envelopes: [enveloppe(1, categorie: 10, montant: 1200, periode: .yearly)],
            transactions: [depense(1, categorie: 11, 130)],
            categories: categories)

        #expect(abs(avancement[0].allocated - 100) < 0.005, "mensualisée")
        #expect(abs(avancement[0].spent - 130) < 0.005, "sous-catégorie captée")
        #expect(avancement[0].healthState == .exceeded)
    }
}
