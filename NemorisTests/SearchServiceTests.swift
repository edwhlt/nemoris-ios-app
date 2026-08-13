import Foundation
import Testing
@testable import Nemoris

/// Recherche globale.
///
/// Elle balaie une douzaine de tables et classe le tout par pertinence. Deux
/// propriétés comptent plus que le reste : elle ne doit rien remonter d'un
/// module que l'utilisateur a désactivé — un résultat menant vers un onglet
/// masqué est une impasse — et elle ne doit pas se déclencher sur une lettre,
/// sous peine de tout faire correspondre.
@Suite("Recherche globale")
struct SearchServiceTests {

    private func fixture() throws -> (TestDatabase, SearchService, TransactionRepository) {
        let db = try TestDatabase()
        return (db, SearchService(store: db.store), TransactionRepository(store: db.store))
    }

    // MARK: - Seuil de déclenchement

    @Test("Une requête d'une seule lettre ne renvoie rien")
    func requeteTropCourte() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Alimentation", regex: "", categoryId: nil)

        // Sans ce garde, la première frappe balaierait toute la base pour
        // remonter presque tout.
        #expect(recherche.search("a").isEmpty)
        #expect(recherche.search("").isEmpty)
        #expect(recherche.search("  ").isEmpty, "les espaces ne comptent pas")
    }

    @Test("Deux lettres suffisent à déclencher la recherche")
    func seuilAtteint() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Netflix", regex: "", categoryId: nil)

        #expect(!recherche.search("ne").isEmpty)
    }

    // MARK: - Correspondance

    @Test("La recherche ignore la casse et les espaces de bord")
    func correspondanceSouple() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Carrefour Market", regex: "", categoryId: nil)

        for saisie in ["carrefour", "CARREFOUR", "  Carrefour  ", "market"] {
            #expect(!recherche.search(saisie).isEmpty, "« \(saisie) » devrait correspondre")
        }
    }

    @Test("Une correspondance exacte passe devant un simple préfixe")
    func ordreDePertinence() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Fnac Darty Boulevard", regex: "", categoryId: nil)
        _ = repo.addTiersAndGetId(name: "Fnac", regex: "", categoryId: nil)

        let resultats = recherche.search("fnac")

        // Celui qui cherche « fnac » veut « Fnac » en tête, pas une déclinaison.
        if case .payee(let premier) = resultats.first {
            #expect(premier.name == "Fnac", "obtenu : \(premier.name)")
        } else {
            Issue.record("aucun tiers en tête : \(resultats.count) résultats")
        }
    }

    @Test("Une correspondance au milieu du nom est trouvée mais classée après")
    func correspondanceInterne() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Super Marché Bio", regex: "", categoryId: nil)
        _ = repo.addTiersAndGetId(name: "Marché", regex: "", categoryId: nil)

        let noms = recherche.search("marché").compactMap { resultat -> String? in
            if case .payee(let t) = resultat { return t.name }
            return nil
        }
        #expect(noms.count == 2)
        #expect(noms.first == "Marché", "obtenu : \(noms)")
    }

    @Test("Rien ne remonte quand la requête ne correspond à aucune donnée")
    func aucuneCorrespondance() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Netflix", regex: "", categoryId: nil)

        #expect(recherche.search("zzzzz").isEmpty)
    }

    // MARK: - Portée par module

    @Test("Un module désactivé ne remonte aucun de ses résultats")
    func moduleDesactive() throws {
        let (db, recherche, _) = try fixture()
        defer { db.destroy() }
        let budget = BudgetRepository(store: db.store)
        #expect(budget.insertEnvelope(BudgetEnvelope(
            id: 0, name: "Vacances", categoryId: nil, amount: 500,
            period: .monthly, startDate: date("2026-01-01"), isActive: true)) != nil)

        #expect(!recherche.search("vacances", showBudget: true).isEmpty,
                "prérequis : l'enveloppe est trouvable module actif")

        // Un résultat menant vers un onglet masqué serait une impasse.
        let sansBudget = recherche.search("vacances", showBudget: false)
        #expect(!sansBudget.contains { if case .budgetEnvelope = $0 { return true }; return false },
                "obtenu : \(sansBudget.count) résultats")
    }

    @Test("Désactiver un module n'affecte pas les autres")
    func porteeIndependante() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Vacances Voyage", regex: "", categoryId: nil)
        let budget = BudgetRepository(store: db.store)
        #expect(budget.insertEnvelope(BudgetEnvelope(
            id: 0, name: "Vacances", categoryId: nil, amount: 500,
            period: .monthly, startDate: date("2026-01-01"), isActive: true)) != nil)

        let resultats = recherche.search("vacances", showBudget: false)
        #expect(resultats.contains { if case .payee = $0 { return true }; return false },
                "le tiers doit rester trouvable")
    }

    // MARK: - Couverture des domaines

    @Test("Les tiers, comptes, catégories et étiquettes sont couverts")
    func domainesDeBase() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.addTiersAndGetId(name: "Zenith Tiers", regex: "", categoryId: nil)
        #expect(repo.addAccount(name: "Zenith Compte", type: "COURANT"))
        #expect(repo.addCategory(name: "Zenith Catégorie", parentId: nil, icon: nil))
        #expect(repo.findOrCreateTag(name: "Zenith Tag") != nil)

        let resultats = recherche.search("zenith")

        var domaines = Set<String>()
        for resultat in resultats {
            switch resultat {
            case .payee: domaines.insert("tiers")
            case .account: domaines.insert("compte")
            case .category: domaines.insert("catégorie")
            case .tag: domaines.insert("étiquette")
            default: break
            }
        }
        #expect(domaines == ["tiers", "compte", "catégorie", "étiquette"],
                "domaines trouvés : \(domaines.sorted())")
    }

    @Test("Le patrimoine est couvert, adresse comprise")
    func domainePatrimoine() throws {
        let (db, recherche, _) = try fixture()
        defer { db.destroy() }
        let patrimoine = PatrimoineRepository(store: db.store)
        #expect(patrimoine.addRealEstate(name: "Studio", purchasePrice: 150_000,
                                         purchaseDate: date("2022-01-01"),
                                         currentValue: 180_000, estimatedAt: nil,
                                         address: "12 rue Zenith", notes: nil))

        // Chercher un bien par son adresse est le réflexe naturel quand on ne
        // se souvient plus du nom qu'on lui a donné.
        let resultats = recherche.search("zenith")
        #expect(resultats.contains { if case .realEstate = $0 { return true }; return false })
    }

    @Test("Une transaction est trouvée par son tiers")
    func domaineTransactions() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        #expect(repo.addAccount(name: "Compte", type: "COURANT"))
        let compte = try #require(repo.fetchAccounts().first)
        let tiers = try #require(repo.addTiersAndGetId(name: "Zenith Boutique",
                                                       regex: "", categoryId: nil))
        _ = repo.addTransaction(accountId: compte.id, tiersId: tiers, categoryId: nil,
                                paymentTypeId: nil, information: "", amount: -42,
                                date: date("2026-03-10"))

        let resultats = recherche.search("zenith")
        #expect(resultats.contains { if case .transaction = $0 { return true }; return false })
    }

    // MARK: - Bornes

    @Test("Une base vide ne fait pas échouer la recherche")
    func baseVide() throws {
        let (db, recherche, _) = try fixture()
        defer { db.destroy() }

        #expect(recherche.search("quoi que ce soit").isEmpty)
    }

    @Test("Le nombre de résultats par domaine est borné")
    func bornageDesResultats() throws {
        let (db, recherche, repo) = try fixture()
        defer { db.destroy() }
        for i in 1...30 {
            _ = repo.addTiersAndGetId(name: "Zenith \(i)", regex: "", categoryId: nil)
        }

        let tiers = recherche.search("zenith").filter {
            if case .payee = $0 { return true }; return false
        }
        // Sans borne, une requête courte noierait l'écran et les autres domaines
        // deviendraient invisibles.
        #expect(tiers.count <= 8, "obtenu : \(tiers.count)")
    }
}
