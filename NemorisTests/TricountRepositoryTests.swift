import Foundation
import Testing
@testable import Nemoris

/// Dépôt des dépenses partagées.
///
/// Ici les montants ne sont pas indicatifs : ils disent qui doit combien à
/// qui. Une erreur d'agrégation ne produit pas un écran cassé mais un chiffre
/// crédible et faux, qu'aucune relecture ne rattrape.
@Suite("Dépôt des dépenses partagées")
struct TricountRepositoryTests {

    private func fixture() throws -> (TestDatabase, TricountRepository) {
        let db = try TestDatabase()
        return (db, TricountRepository(store: db.store))
    }

    private func depense(_ identifiant: String, paye par: String, total: Double,
                         parts: [(String, Double)], libelle: String = "Dépense",
                         jour: String = "2026-03-10",
                         devise: String = "EUR",
                         totalLocal: Double? = nil,
                         deviseLocale: String? = nil) -> ParsedTCEntry {
        ParsedTCEntry(sourceUUID: identifiant, sourceUpdatedAt: nil,
                      typeTransaction: "NORMAL", whoPaid: par, total: total,
                      currency: devise, localTotal: totalLocal, localCurrency: deviseLocale,
                      description: libelle, date: jour,
                      shares: parts.map { (memberName: $0.0, amount: $0.1) },
                      category: "")
    }

    // MARK: - Enregistrement d'un groupe

    @Test("Un groupe enregistré se relit avec ses dépenses et ses parts")
    func enregistrementInitial() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let id = try #require(repo.saveGroup(
            key: "abc123", title: "Vacances", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 90,
                              parts: [("Moi", 30), ("Alice", 30), ("Bob", 30)])]))

        let groupe = try #require(repo.fetchGroup(id: id))
        #expect(groupe.title == "Vacances")
        #expect(groupe.myName == "Moi")
        #expect(repo.fetchEntries(groupId: id).count == 1)
        #expect(repo.fetchShares(groupId: id).count == 3)
    }

    @Test("Recharger le même groupe le met à jour au lieu de le dupliquer")
    func rechargementIdempotent() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let premier = try #require(repo.saveGroup(
            key: "abc123", title: "Vacances", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 90,
                              parts: [("Moi", 45), ("Alice", 45)])]))
        let second = try #require(repo.saveGroup(
            key: "abc123", title: "Vacances 2026", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 90,
                              parts: [("Moi", 45), ("Alice", 45)])]))

        // La clé du Tricount fait l'identité : sans upsert, chaque
        // rafraîchissement créerait un groupe de plus et doublerait les dettes.
        #expect(premier == second, "l'identifiant local reste stable")
        #expect(repo.fetchGroups().count == 1)
        #expect(repo.fetchGroup(id: premier)?.title == "Vacances 2026", "le titre est rafraîchi")
        #expect(repo.fetchEntries(groupId: premier).count == 1, "la dépense n'est pas dupliquée")
    }

    @Test("Deux clés différentes donnent deux groupes distincts")
    func groupesDistincts() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        _ = repo.saveGroup(key: "voyage", title: "Voyage", currency: "EUR",
                           myName: "Moi", entries: [])
        _ = repo.saveGroup(key: "coloc", title: "Coloc", currency: "EUR",
                           myName: "Moi", entries: [])

        #expect(repo.fetchGroups().count == 2)
    }

    // MARK: - Soldes

    @Test("Le solde de chacun s'annule sur l'ensemble du groupe")
    func soldesEquilibres() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 90,
                              parts: [("Moi", 30), ("Alice", 30), ("Bob", 30)])]))
        let entrees = repo.fetchEntries(groupId: id)
        let parts = repo.fetchShares(groupId: id)

        // Les soldes sont exprimés du point de vue d'UNE personne ; on vérifie
        // donc la propriété qui vaut pour le groupe entier : la somme des
        // positions nettes de chacun est nulle, sinon de l'argent apparaît.
        var somme = 0.0
        for membre in ["Moi", "Alice", "Bob"] {
            let soldes = repo.computeBalances(entries: entrees, shares: parts, myName: membre)
            somme += soldes.reduce(0) { $0 + $1.net }
        }
        #expect(abs(somme) < 0.005, "somme des positions nettes : \(somme)")
    }

    @Test("Celui qui a payé est créditeur de la part des autres")
    func creancierIdentifie() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 60,
                              parts: [("Moi", 30), ("Alice", 30)])]))

        let soldes = repo.computeBalances(entries: repo.fetchEntries(groupId: id),
                                          shares: repo.fetchShares(groupId: id),
                                          myName: "Moi")

        let alice = try #require(soldes.first { $0.memberName == "Alice" })
        #expect(abs(alice.net - 30) < 0.005,
                "Alice doit sa part à celui qui a avancé : \(alice.net)")
    }

    @Test("Le point de vue s'inverse selon la personne")
    func pointDeVueInverse() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 60,
                              parts: [("Moi", 30), ("Alice", 30)])]))
        let entrees = repo.fetchEntries(groupId: id)
        let parts = repo.fetchShares(groupId: id)

        let vuDeMoi = repo.computeBalances(entries: entrees, shares: parts, myName: "Moi")
            .first { $0.memberName == "Alice" }?.net ?? 0
        let vuDAlice = repo.computeBalances(entries: entrees, shares: parts, myName: "Alice")
            .first { $0.memberName == "Moi" }?.net ?? 0

        #expect(abs(vuDeMoi + vuDAlice) < 0.005,
                "ce qu'Alice me doit est exactement ce que je lui dois en négatif")
    }

    @Test("Des dépenses croisées se compensent")
    func compensationDesDepenses() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 60, parts: [("Moi", 30), ("Alice", 30)]),
                      depense("e2", paye: "Alice", total: 60, parts: [("Moi", 30), ("Alice", 30)])]))

        let soldes = repo.computeBalances(entries: repo.fetchEntries(groupId: id),
                                          shares: repo.fetchShares(groupId: id),
                                          myName: "Moi")

        // Chacun a avancé autant : personne ne doit rien.
        let alice = soldes.first { $0.memberName == "Alice" }?.net ?? 0
        #expect(abs(alice) < 0.005, "solde attendu nul, obtenu : \(alice)")
    }

    @Test("Un groupe sans dépense a des soldes vides")
    func groupeVide() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(key: "k", title: "T", currency: "EUR",
                                             myName: "Moi", entries: []))

        #expect(repo.computeBalances(entries: repo.fetchEntries(groupId: id),
                                     shares: repo.fetchShares(groupId: id),
                                     myName: "Moi").isEmpty)
    }

    // MARK: - Devise étrangère

    @Test("Le montant converti est conservé à côté du montant d'origine")
    func deviseEtrangere() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // Un repas à 1 000 000 VND payé 40 € : garder les deux permet de
        // dériver le taux réel plus tard, sans réinterroger un service.
        let id = try #require(repo.saveGroup(
            key: "k", title: "Vietnam", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 1_000_000,
                              parts: [("Moi", 500_000), ("Alice", 500_000)],
                              devise: "VND", totalLocal: 40, deviseLocale: "EUR")]))

        let entree = try #require(repo.fetchEntries(groupId: id).first)
        #expect(entree.currency == "VND")
        #expect(abs(entree.total - 1_000_000) < 0.5)
        #expect(entree.localTotal.map { abs($0 - 40) < 0.005 } == true,
                "le montant converti doit survivre à l'enregistrement")
    }

    // MARK: - Rattachements

    @Test("Une dépense peut être catégorisée localement")
    func categorisationLocale() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 20, parts: [("Moi", 20)])]))
        let entree = try #require(repo.fetchEntries(groupId: id).first)
        let txRepo = TransactionRepository(store: db.store)
        #expect(txRepo.addCategory(name: "Restaurant", parentId: nil, icon: nil))
        let categorie = try #require(txRepo.fetchCategories().first)

        #expect(repo.updateEntryCategory(entryId: entree.id, categoryId: categorie.id))

        // La catégorie est un choix LOCAL : le service partagé n'en sait rien,
        // elle doit donc survivre au prochain rafraîchissement.
        #expect(repo.fetchEntries(groupId: id).first?.userCategoryId == categorie.id)
    }

    @Test("Une dépense peut être reliée à une transaction du compte")
    func rattachementTransaction() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 20, parts: [("Moi", 20)])]))
        let entree = try #require(repo.fetchEntries(groupId: id).first)

        #expect(repo.updateLinkedTransaction(entryId: entree.id, transactionId: 42))
        #expect(repo.fetchEntries(groupId: id).first?.linkedTransactionId == 42)

        // Le lien doit pouvoir être défait sans supprimer la dépense.
        #expect(repo.updateLinkedTransaction(entryId: entree.id, transactionId: nil))
        #expect(repo.fetchEntries(groupId: id).first?.linkedTransactionId == nil)
    }

    // MARK: - Suppression

    @Test("Supprimer un groupe emporte ses dépenses et leurs parts")
    func suppressionEnCascade() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.saveGroup(
            key: "k", title: "T", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 60,
                              parts: [("Moi", 30), ("Alice", 30)])]))

        repo.deleteGroup(id: id)

        #expect(repo.fetchGroups().isEmpty)
        // Des parts orphelines fausseraient tout solde recalculé plus tard.
        #expect(repo.fetchEntries(groupId: id).isEmpty)
        #expect(repo.fetchShares(groupId: id).isEmpty)
    }

    @Test("Supprimer un groupe n'affecte pas les autres")
    func suppressionIsolee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let voyage = try #require(repo.saveGroup(
            key: "voyage", title: "Voyage", currency: "EUR", myName: "Moi",
            entries: [depense("e1", paye: "Moi", total: 20, parts: [("Moi", 20)])]))
        let coloc = try #require(repo.saveGroup(
            key: "coloc", title: "Coloc", currency: "EUR", myName: "Moi",
            entries: [depense("e2", paye: "Moi", total: 30, parts: [("Moi", 30)])]))

        repo.deleteGroup(id: voyage)

        #expect(repo.fetchGroups().count == 1)
        #expect(repo.fetchEntries(groupId: coloc).count == 1)
    }
}
