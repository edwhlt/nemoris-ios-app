import Foundation
import Testing
@testable import Nemoris

/// Budget envelope suggestions from historical data.
///
/// This service proposes budgets the user didn't ask for. Too
/// permissive, it drowns the screen in marginal suggestions; too strict, it
/// suggests nothing and the feature looks broken. The thresholds are therefore what
/// needs to be locked down.
@Suite("EnvelopeSuggestionService")
struct EnvelopeSuggestionServiceTests {

    /// A fixed evaluation date: the 90-day window must be reproducible.
    private let maintenant = date("2026-04-01")

    private func fixture() throws -> (TestDatabase, TransactionRepository) {
        let db = try TestDatabase()
        let repo = TransactionRepository(store: db.store)
        _ = repo.addAccount(name: "Courant")
        return (db, repo)
    }

    /// Adds `count` expenses of `amount` in the given category.
    private func depenses(_ repo: TransactionRepository, categorie: Int?,
                          montant: Double, count: Int, depuis: String = "2026-03-01") {
        let compte = repo.fetchAccounts()[0]
        for i in 0..<count {
            _ = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: categorie,
                                    paymentTypeId: nil, information: "achat \(i)",
                                    amount: montant, date: date(depuis))
        }
    }

    private func categorie(_ repo: TransactionRepository, _ nom: String) -> Nemoris.Category {
        _ = repo.addCategory(name: nom, icon: "cart.fill")
        return repo.fetchCategories().first { $0.name == nom }!
    }

    private func suggestions(_ repo: TransactionRepository, categories: [Nemoris.Category],
                             enveloppes: [BudgetEnvelope] = []) -> [EnvelopeSuggestion] {
        EnvelopeSuggestionService.computeSuggestions(
            existingEnvelopes: enveloppes, allCategories: categories,
            txRepo: repo, now: maintenant)
    }

    // MARK: - Seuils de pertinence

    @Test("Une catégorie régulière et significative est suggérée")
    func categorieRetenue() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let alimentation = categorie(repo, "Alimentation")
        depenses(repo, categorie: alimentation.id, montant: -60, count: 6)

        let s = suggestions(repo, categories: [alimentation])
        #expect(s.count == 1, "obtenu : \(s.map(\.categoryName))")
        #expect(s[0].categoryId == alimentation.id)
        #expect(s[0].transactionCount == 6)
    }

    @Test("Moins de trois transactions ne suffisent pas")
    func seuilDeFrequence() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Électroménager")
        // Two purchases at €400: the amount is high, but two data points don't make
        // a habit. Suggesting a monthly budget on this makes no sense.
        depenses(repo, categorie: c.id, montant: -400, count: 2)

        #expect(suggestions(repo, categories: [c]).isEmpty)
    }

    @Test("Un cumul trop faible ne suffit pas non plus")
    func seuilDeMontant() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Presse")
        // Frequent but marginal: 5 × €2 = €10, below the €30 floor.
        depenses(repo, categorie: c.id, montant: -2, count: 5)

        #expect(suggestions(repo, categories: [c]).isEmpty,
                "une catégorie marginale noierait l'écran de suggestions")
    }

    @Test("Une catégorie déjà couverte par une enveloppe n'est pas reproposée")
    func categorieDejaCouverte() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Alimentation")
        depenses(repo, categorie: c.id, montant: -60, count: 6)

        let existante = BudgetEnvelope(id: 1, name: "Courses", categoryId: c.id, amount: 300,
                                       period: .monthly, startDate: date("2026-01-01"),
                                       isActive: true)

        #expect(suggestions(repo, categories: [c], enveloppes: [existante]).isEmpty)
    }

    // MARK: - What gets ignored

    @Test("Les transactions sans catégorie sont ignorées")
    func sansCategorie() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        depenses(repo, categorie: nil, montant: -80, count: 10)

        #expect(suggestions(repo, categories: []).isEmpty,
                "on ne peut pas budgéter ce qui n'est pas rangé")
    }

    @Test("Les recettes ne produisent pas de suggestion de budget")
    func recettesIgnorees() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Salaire")
        depenses(repo, categorie: c.id, montant: 2_500, count: 3)   // montants positifs

        #expect(suggestions(repo, categories: [c]).isEmpty,
                "une enveloppe encadre une dépense, pas un revenu")
    }

    @Test("Les dépenses hors fenêtre de 90 jours ne comptent pas")
    func horsFenetre() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Vacances")
        // Six months before the evaluation date: outside the 90-day rolling window.
        depenses(repo, categorie: c.id, montant: -200, count: 5, depuis: "2025-09-01")

        #expect(suggestions(repo, categories: [c]).isEmpty,
                "un train de vie ancien ne doit pas dicter le budget actuel")
    }

    // MARK: - Amount calculation

    @Test("Le budget suggéré dépasse la moyenne observée et tombe sur une dizaine")
    func arrondiEtMarge() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Alimentation")
        // €300 over the 90-day window → an average of €100/month.
        depenses(repo, categorie: c.id, montant: -60, count: 5)

        let s = suggestions(repo, categories: [c])[0]
        #expect(abs(s.averageMonthly - 100) < 0.01, "moyenne : \(s.averageMonthly)")

        // A 10% margin then rounded up to the nearest ten: a budget set to the
        // exact cent would put the user over budget from the first month.
        #expect(s.suggestedBudget >= s.averageMonthly,
                "budget \(s.suggestedBudget) sous la moyenne \(s.averageMonthly)")
        #expect(s.suggestedBudget.truncatingRemainder(dividingBy: 10) == 0,
                "budget non arrondi : \(s.suggestedBudget)")
        #expect(s.suggestedBudget == 110, "budget : \(s.suggestedBudget)")
    }

    @Test("Les suggestions sont triées par montant décroissant")
    func triParImpact() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let petite = categorie(repo, "Café")
        let grosse = categorie(repo, "Alimentation")
        depenses(repo, categorie: petite.id, montant: -15, count: 4)
        depenses(repo, categorie: grosse.id, montant: -120, count: 5)

        let s = suggestions(repo, categories: [petite, grosse])
        #expect(s.count == 2, "obtenu : \(s.map(\.categoryName))")
        #expect(s[0].categoryName == "Alimentation", "les plus impactantes d'abord")
        #expect(s[0].suggestedBudget >= s[1].suggestedBudget)
    }

    @Test("Un historique vide ne suggère rien sans planter")
    func historiqueVide() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        #expect(suggestions(repo, categories: []).isEmpty)
    }

    @Test("Une catégorie absente du référentiel n'est pas suggérée")
    func categorieInconnue() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let c = categorie(repo, "Alimentation")
        depenses(repo, categorie: c.id, montant: -60, count: 6)

        // The past reference data doesn't contain this category: without its
        // name or icon, the suggestion would be undisplayable.
        #expect(suggestions(repo, categories: []).isEmpty)
    }
}
