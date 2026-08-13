import Foundation
import Testing
@testable import Nemoris

/// Agrégations et opérations groupées sur les transactions.
///
/// Ce sont les chiffres que l'utilisateur lit en premier : totaux du mois,
/// répartition par catégorie, solde d'un compte. Une erreur ici ne se voit
/// jamais — elle donne un montant plausible.
@Suite("Agrégations des transactions")
struct TransactionAggregationTests {

    private struct Contexte {
        let db: TestDatabase
        let repo: TransactionRepository
        let courant: Int
        let livret: Int
    }

    private func fixture() throws -> Contexte {
        let db = try TestDatabase()
        let repo = TransactionRepository(store: db.store)
        #expect(repo.addAccount(name: "Courant", type: "COURANT"))
        #expect(repo.addAccount(name: "Livret", type: "EPARGNE"))
        let comptes = repo.fetchAccounts()
        return Contexte(db: db, repo: repo,
                        courant: comptes.first { $0.name == "Courant" }!.id,
                        livret: comptes.first { $0.name == "Livret" }!.id)
    }

    @discardableResult
    private func transaction(_ c: Contexte, compte: Int? = nil, tiers: Int? = nil,
                             categorie: Int? = nil, montant: Double,
                             jour: String) -> Int? {
        c.repo.addTransaction(accountId: compte ?? c.courant, tiersId: tiers,
                              categoryId: categorie, paymentTypeId: nil,
                              information: "", amount: montant, date: date(jour))
    }

    // MARK: - Totaux mensuels

    @Test("Recettes et dépenses sont séparées par mois")
    func totauxMensuels() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, montant: 2_500, jour: "2026-03-01")
        transaction(c, montant: -800, jour: "2026-03-15")
        transaction(c, montant: -200, jour: "2026-04-02")

        let totaux = c.repo.fetchMonthlyTotals(from: date("2026-01-01"), to: date("2026-12-31"))

        #expect(totaux.count == 2, "obtenu : \(totaux.map(\.month))")
        let mars = try #require(totaux.first { $0.month == "2026-03" })
        #expect(abs(mars.income - 2_500) < 0.005)
        #expect(abs(mars.expense + 800) < 0.005, "les dépenses restent négatives")
    }

    @Test("Un virement entre comptes personnels ne compte ni en recette ni en dépense")
    func virementInterneExclu() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        // Un tiers « virement interne » pointe vers un autre compte de l'utilisateur.
        let tiersInterne = try #require(c.repo.addTiersAndGetId(name: "Vers Livret", regex: ""))
        var tiers = try #require(c.repo.fetchTiers().first { $0.id == tiersInterne })
        tiers.linkedCompteId = c.livret
        #expect(c.repo.updatePayeeFull(tiers))

        transaction(c, montant: -1_000, jour: "2026-03-10")                      // vraie dépense
        transaction(c, tiers: tiersInterne, montant: -5_000, jour: "2026-03-11") // déplacement

        let mars = try #require(c.repo.fetchMonthlyTotals(from: date("2026-03-01"),
                                                          to: date("2026-03-31")).first)
        // Déplacer son propre argent n'appauvrit personne : le compter
        // gonflerait les dépenses du mois de 5 000 €.
        #expect(abs(mars.expense + 1_000) < 0.005, "obtenu : \(mars.expense)")
    }

    @Test("Les bornes de dates sont inclusives et se réordonnent seules")
    func bornesDeDates() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, montant: -10, jour: "2026-03-01")
        transaction(c, montant: -20, jour: "2026-03-31")

        let normal = c.repo.fetchMonthlyTotals(from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(abs((normal.first?.expense ?? 0) + 30) < 0.005,
                "les deux bornes sont incluses")

        // Bornes inversées : rendre une liste vide serait un piège pour l'appelant.
        let inverse = c.repo.fetchMonthlyTotals(from: date("2026-03-31"), to: date("2026-03-01"))
        #expect(abs((inverse.first?.expense ?? 0) + 30) < 0.005)
    }

    @Test("Le filtre par compte isole les totaux")
    func totauxParCompte() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, compte: c.courant, montant: -100, jour: "2026-03-10")
        transaction(c, compte: c.livret, montant: -50, jour: "2026-03-10")

        let courant = c.repo.fetchMonthlyTotals(accountId: c.courant,
                                                from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(abs((courant.first?.expense ?? 0) + 100) < 0.005)
    }

    // MARK: - Répartition par catégorie

    @Test("Les dépenses se cumulent par catégorie")
    func totauxParCategorie() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        #expect(c.repo.addCategory(name: "Alimentation", parentId: nil, icon: nil))
        let alimentation = try #require(c.repo.fetchCategories().first)
        transaction(c, categorie: alimentation.id, montant: -60, jour: "2026-03-10")
        transaction(c, categorie: alimentation.id, montant: -40, jour: "2026-03-12")

        let totaux = c.repo.fetchCategoryTotals(from: date("2026-03-01"), to: date("2026-03-31"))

        let ligne = try #require(totaux.first { $0.category == "Alimentation" })
        #expect(abs(ligne.total + 100) < 0.005, "obtenu : \(ligne.total)")
    }

    @Test("Les transactions sans catégorie sont regroupées, pas ignorées")
    func nonCategorisees() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, montant: -75, jour: "2026-03-10")

        let totaux = c.repo.fetchCategoryTotals(from: date("2026-03-01"), to: date("2026-03-31"))

        // Les faire disparaître ferait mentir la somme de la répartition.
        #expect(totaux.contains { $0.category == "Non catégorisé" },
                "catégories trouvées : \(totaux.map(\.category))")
    }

    @Test("Le compteur de non catégorisées reflète la période")
    func compteurNonCategorisees() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        #expect(c.repo.addCategory(name: "Alimentation", parentId: nil, icon: nil))
        let categorie = try #require(c.repo.fetchCategories().first)
        transaction(c, montant: -10, jour: "2026-03-10")
        transaction(c, montant: -20, jour: "2026-03-11")
        transaction(c, categorie: categorie.id, montant: -30, jour: "2026-03-12")
        transaction(c, montant: -40, jour: "2026-05-01")

        let mars = c.repo.fetchUncategorizedCount(accountId: c.courant,
                                                  from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(mars == 2, "obtenu : \(mars)")
    }

    // MARK: - Solde

    @Test("Le solde d'un compte est la somme de ses mouvements")
    func soldeDeCompte() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, montant: 2_000, jour: "2026-01-05")
        transaction(c, montant: -350, jour: "2026-02-10")
        transaction(c, compte: c.livret, montant: 9_999, jour: "2026-02-10")

        #expect(abs(c.repo.fetchAccountBalance(accountId: c.courant) - 1_650) < 0.005,
                "obtenu : \(c.repo.fetchAccountBalance(accountId: c.courant))")
    }

    @Test("Le solde peut être arrêté à une date")
    func soldeArreteALaDate() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, montant: 1_000, jour: "2026-01-05")
        transaction(c, montant: -300, jour: "2026-06-01")

        // C'est ce qui permet d'afficher le solde tel qu'il était à une date
        // passée, sans que les mouvements postérieurs le contaminent.
        #expect(abs(c.repo.fetchAccountBalance(accountId: c.courant,
                                               upToDate: date("2026-03-01")) - 1_000) < 0.005)
    }

    @Test("Le compte zéro désigne tous les comptes")
    func soldeTousComptes() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        transaction(c, compte: c.courant, montant: 100, jour: "2026-03-01")
        transaction(c, compte: c.livret, montant: 250, jour: "2026-03-01")

        #expect(abs(c.repo.fetchAccountBalance(accountId: 0) - 350) < 0.005,
                "zéro est la sentinelle « tous les comptes »")
    }

    @Test("Un compte sans mouvement a un solde nul, pas indéfini")
    func soldeCompteVide() throws {
        let c = try fixture()
        defer { c.db.destroy() }

        #expect(c.repo.fetchAccountBalance(accountId: c.livret) == 0)
    }

    // MARK: - Opérations groupées

    @Test("Recatégoriser en lot ne touche que les transactions visées")
    func recategorisationGroupee() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        #expect(c.repo.addCategory(name: "Alimentation", parentId: nil, icon: nil))
        let categorie = try #require(c.repo.fetchCategories().first)
        let a = try #require(transaction(c, montant: -10, jour: "2026-03-01"))
        let b = try #require(transaction(c, montant: -20, jour: "2026-03-02"))
        let epargnee = try #require(transaction(c, montant: -30, jour: "2026-03-03"))

        let touchees = c.repo.updateTransactionsCategory(ids: [a, b], categoryId: categorie.id)

        #expect(touchees == 2, "obtenu : \(touchees)")
        let comptes = c.repo.countTransactionsByCategory()
        #expect(comptes[categorie.id] == 2)
        #expect(c.repo.fetchTransaction(id: epargnee)?.categoryId == nil)
    }

    @Test("Recatégoriser vers rien décatégorise")
    func decategorisationGroupee() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        #expect(c.repo.addCategory(name: "Alimentation", parentId: nil, icon: nil))
        let categorie = try #require(c.repo.fetchCategories().first)
        let id = try #require(transaction(c, categorie: categorie.id, montant: -10, jour: "2026-03-01"))

        #expect(c.repo.updateTransactionsCategory(ids: [id], categoryId: nil) == 1)
        #expect(c.repo.fetchTransaction(id: id)?.categoryId == nil)
    }

    // MARK: - Hiérarchie des catégories

    @Test("Une catégorie peut être rattachée puis détachée d'un parent")
    func deplacementDeCategorie() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        #expect(c.repo.addCategory(name: "Alimentation", parentId: nil, icon: nil))
        #expect(c.repo.addCategory(name: "Supermarché", parentId: nil, icon: nil))
        let parent = try #require(c.repo.fetchCategories().first { $0.name == "Alimentation" })
        let enfant = try #require(c.repo.fetchCategories().first { $0.name == "Supermarché" })

        #expect(c.repo.moveCategory(id: enfant.id, toParentId: parent.id))
        #expect(c.repo.fetchCategories().first { $0.id == enfant.id }?.parentId == parent.id)

        #expect(c.repo.moveCategory(id: enfant.id, toParentId: nil))
        #expect(c.repo.fetchCategories().first { $0.id == enfant.id }?.parentId == nil,
                "une catégorie doit pouvoir redevenir racine")
    }

    // MARK: - Comptages

    @Test("Les comptages par dimension ne comptent que ce qui est renseigné")
    func comptagesParDimension() throws {
        let c = try fixture()
        defer { c.db.destroy() }
        let tiers = try #require(c.repo.addTiersAndGetId(name: "Netflix", regex: ""))
        transaction(c, tiers: tiers, montant: -12, jour: "2026-03-01")
        transaction(c, montant: -30, jour: "2026-03-02")   // sans tiers

        let parTiers = c.repo.countTransactionsByPayee()
        #expect(parTiers[tiers] == 1)
        let parCompte = c.repo.countTransactionsByAccount()
        #expect(parCompte[c.courant] == 2, "le compte, lui, est toujours renseigné")
    }
}
