import Foundation
import Testing
@testable import Nemoris

/// Tests du repository central : c'est lui qui écrit les données que
/// l'utilisateur ne peut pas reconstituer s'il les perd.
@Suite("TransactionRepository")
struct TransactionRepositoryTests {

    /// Base neuve + repository branché dessus, pour chaque test.
    private func fixture() throws -> (TestDatabase, TransactionRepository) {
        let db = try TestDatabase()
        return (db, TransactionRepository(store: db.store))
    }

    // MARK: - Référentiel

    @Test("Un compte créé est relu avec son nom et son type")
    func compte() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Compte courant", type: "COURANT"))
        #expect(repo.addAccount(name: "Livret A", type: "EPARGNE"))

        let comptes = repo.fetchAccounts()
        #expect(comptes.count == 2)
        #expect(comptes.first(where: { $0.name == "Livret A" })?.type == "EPARGNE")
    }

    @Test("Une catégorie enfant connaît son parent")
    func categorieHierarchique() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addCategory(name: "Alimentation", icon: "cart.fill"))
        let parent = repo.fetchCategories().first { $0.name == "Alimentation" }!
        #expect(repo.addCategory(name: "Restaurants", parentId: parent.id))

        let enfant = repo.fetchCategories().first { $0.name == "Restaurants" }
        #expect(enfant?.parentId == parent.id)
    }

    @Test("Déplacer une catégorie change son parent")
    func deplacerCategorie() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addCategory(name: "Racine A"))
        #expect(repo.addCategory(name: "Racine B"))
        #expect(repo.addCategory(name: "Feuille"))
        let cats = repo.fetchCategories()
        let a = cats.first { $0.name == "Racine A" }!
        let b = cats.first { $0.name == "Racine B" }!
        let feuille = cats.first { $0.name == "Feuille" }!

        #expect(repo.moveCategory(id: feuille.id, toParentId: a.id))
        #expect(repo.fetchCategories().first { $0.id == feuille.id }?.parentId == a.id)

        #expect(repo.moveCategory(id: feuille.id, toParentId: b.id))
        #expect(repo.fetchCategories().first { $0.id == feuille.id }?.parentId == b.id)

        // Remonter à la racine
        #expect(repo.moveCategory(id: feuille.id, toParentId: nil))
        #expect(repo.fetchCategories().first { $0.id == feuille.id }?.parentId == nil)
    }

    // MARK: - Transactions

    @Test("Une transaction créée est relue avec ses montants et ses liens")
    func transactionAllerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        #expect(repo.addCategory(name: "Alimentation"))
        let categorie = repo.fetchCategories()[0]
        let payeeId = repo.addTiersAndGetId(name: "Carrefour", regex: "CARREFOUR")
        #expect(payeeId != nil)

        let id = repo.addTransaction(
            accountId: compte.id, tiersId: payeeId, categoryId: categorie.id,
            paymentTypeId: nil, information: "Courses", amount: -42.50,
            date: date("2026-03-15"))
        #expect(id != nil)

        let relue = repo.fetchTransaction(id: id!)
        #expect(relue?.amount == -42.50)
        #expect(relue?.tiersName == "Carrefour")
        #expect(relue?.categoryName == "Alimentation")
        #expect(relue?.information == "Courses")
    }

    @Test("La plage de dates est inclusive à ses deux bornes")
    func bornesDeDates() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        for jour in ["2026-03-01", "2026-03-15", "2026-03-31"] {
            _ = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                    paymentTypeId: nil, information: jour, amount: -10,
                                    date: date(jour))
        }

        let dansLeMois = repo.fetchTransactions(accountId: compte.id,
                                                from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(dansLeMois.count == 3, "les deux bornes doivent être incluses")

        let auMilieu = repo.fetchTransactions(accountId: compte.id,
                                              from: date("2026-03-02"), to: date("2026-03-30"))
        #expect(auMilieu.count == 1)
    }

    @Test("Une plage de dates inversée est corrigée au lieu de ne rien renvoyer")
    func plageInversee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        _ = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                paymentTypeId: nil, information: "x", amount: -10,
                                date: date("2026-03-15"))

        let inversee = repo.fetchTransactions(accountId: compte.id,
                                              from: date("2026-03-31"), to: date("2026-03-01"))
        #expect(inversee.count == 1)
    }

    @Test("Le compte 0 est le sentinel « tous les comptes »")
    func sentinelTousComptes() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "A"))
        #expect(repo.addAccount(name: "B"))
        let comptes = repo.fetchAccounts()
        for c in comptes {
            _ = repo.addTransaction(accountId: c.id, tiersId: nil, categoryId: nil,
                                    paymentTypeId: nil, information: c.name, amount: -5,
                                    date: date("2026-03-10"))
        }

        let unSeul = repo.fetchTransactions(accountId: comptes[0].id,
                                            from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(unSeul.count == 1)

        let tous = repo.fetchTransactions(accountId: 0,
                                          from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(tous.count == 2)
    }

    @Test("Supprimer plusieurs transactions les retire toutes")
    func suppressionMultiple() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        var ids: Set<Int> = []
        for i in 1...3 {
            if let id = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                            paymentTypeId: nil, information: "t\(i)", amount: -1,
                                            date: date("2026-03-0\(i)")) {
                ids.insert(id)
            }
        }
        #expect(ids.count == 3)

        #expect(repo.deleteTransactions(ids: ids) == 3)
        #expect(db.count("transactions") == 0)
    }

    @Test("Le compteur de suppression compte les instructions, pas les lignes touchées")
    func semantiqueDuCompteurDeSuppression() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // SQLite renvoie SQLITE_DONE pour un DELETE qui ne touche aucune ligne.
        // deleteTransactions additionne donc les instructions réussies, pas les
        // lignes réellement supprimées : un identifiant périmé est compté. Sans
        // conséquence tant que l'appelant part d'une sélection à jour, mais le
        // comportement est verrouillé ici pour qu'un changement soit délibéré.
        #expect(repo.deleteTransactions(ids: [999_998, 999_999]) == 2)
        #expect(db.count("transactions") == 0)
    }

    // MARK: - Intégrité référentielle

    @Test("Un compte portant des transactions ne peut pas être supprimé")
    func compteProtegeParSesTransactions() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        let txId = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                       paymentTypeId: nil, information: "x", amount: -1,
                                       date: date("2026-03-01"))!

        // Garde-fou délibéré : supprimer le compte détruirait un historique que
        // l'utilisateur ne peut pas reconstituer. Il doit d'abord vider le compte.
        #expect(repo.deleteAccount(id: compte.id) == false)
        #expect(repo.fetchAccounts().count == 1)
        #expect(db.count("transactions") == 1)

        #expect(repo.deleteTransaction(id: txId))
        #expect(repo.deleteAccount(id: compte.id), "une fois vidé, le compte part")
        #expect(repo.fetchAccounts().isEmpty)
    }

    @Test("Supprimer un compte n'affecte pas les autres")
    func suppressionCompteIsolee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "À supprimer"))
        #expect(repo.addAccount(name: "À garder"))
        let comptes = repo.fetchAccounts()
        let aGarder = comptes.first { $0.name == "À garder" }!
        let aSupprimer = comptes.first { $0.name == "À supprimer" }!

        _ = repo.addTransaction(accountId: aGarder.id, tiersId: nil, categoryId: nil,
                                paymentTypeId: nil, information: "y", amount: -1,
                                date: date("2026-03-01"))

        #expect(repo.deleteAccount(id: aSupprimer.id))
        #expect(repo.fetchAccounts().map(\.name) == ["À garder"])
        #expect(db.count("transactions") == 1)
    }

    @Test("Supprimer une catégorie ne détruit pas les transactions qui la portaient")
    func suppressionCategorie() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        #expect(repo.addCategory(name: "Éphémère"))
        let categorie = repo.fetchCategories()[0]

        let id = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: categorie.id,
                                     paymentTypeId: nil, information: "x", amount: -1,
                                     date: date("2026-03-01"))
        #expect(id != nil)

        #expect(repo.deleteCategory(id: categorie.id))
        #expect(db.count("transactions") == 1, "la transaction survit à sa catégorie")
        #expect(repo.fetchTransaction(id: id!)?.categoryId == nil)
    }

    // MARK: - Comptages

    @Test("Les comptages par dimension reflètent les transactions")
    func comptages() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        #expect(repo.addCategory(name: "Alimentation"))
        let categorie = repo.fetchCategories()[0]
        let payeeId = repo.addTiersAndGetId(name: "Carrefour", regex: "CARREFOUR")!

        for i in 1...3 {
            _ = repo.addTransaction(accountId: compte.id, tiersId: payeeId, categoryId: categorie.id,
                                    paymentTypeId: nil, information: "t\(i)", amount: -10,
                                    date: date("2026-03-0\(i)"))
        }
        // Une transaction sans catégorie ni tiers : elle ne doit compter nulle part.
        _ = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                paymentTypeId: nil, information: "orpheline", amount: -1,
                                date: date("2026-03-04"))

        #expect(repo.countTransactionsByAccount()[compte.id] == 4)
        #expect(repo.countTransactionsByCategory()[categorie.id] == 3)
        #expect(repo.countTransactionsByPayee()[payeeId] == 3)
    }

    // MARK: - Étiquettes

    @Test("findOrCreateTag ne crée pas de doublon")
    func tagIdempotent() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let premier = repo.findOrCreateTag(name: "Vacances")
        let second = repo.findOrCreateTag(name: "Vacances")

        #expect(premier != nil)
        #expect(premier == second, "le même nom doit rendre le même identifiant")
        #expect(repo.fetchAllTags().count == 1)
    }

    @Test("Supprimer une étiquette délie les transactions sans les supprimer")
    func suppressionTag() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAccount(name: "Courant"))
        let compte = repo.fetchAccounts()[0]
        let txId = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                       paymentTypeId: nil, information: "x", amount: -1,
                                       date: date("2026-03-01"))!
        let tagId = repo.findOrCreateTag(name: "Vacances")!
        #expect(repo.setTags([tagId], forTransaction: txId))
        #expect(repo.fetchTags(forTransaction: txId).count == 1)

        #expect(repo.deleteTag(id: tagId))
        #expect(db.count("transactions") == 1, "la transaction survit à son étiquette")
        #expect(repo.fetchTags(forTransaction: txId).isEmpty)
    }
}
