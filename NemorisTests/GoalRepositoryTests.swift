import Foundation
import Testing
@testable import Nemoris

@Suite("GoalRepository")
struct GoalRepositoryTests {

    private func fixture() throws -> (TestDatabase, GoalRepository) {
        let db = try TestDatabase()
        return (db, GoalRepository(store: db.store))
    }

    @Test("Un objectif créé est relu avec ses montants et son échéance")
    func allerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addGoal(name: "Apport appartement", kind: .savings,
                             targetAmount: 30_000, deadlineDate: date("2027-06-30"),
                             customCurrentAmount: 4_500, notes: "hors frais de notaire"))

        let objectifs = repo.fetchGoals()
        #expect(objectifs.count == 1)
        let g = objectifs[0]
        #expect(g.name == "Apport appartement")
        #expect(g.kind == .savings)
        #expect(g.targetAmount == 30_000)
        #expect(g.customCurrentAmount == 4_500)
        #expect(g.notes == "hors frais de notaire")
        #expect(g.deadlineDate != nil)
    }

    @Test("Une échéance et une note absentes restent nulles")
    func champsOptionnels() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addGoal(name: "Fonds d'urgence", kind: .savings, targetAmount: 10_000,
                             deadlineDate: nil, customCurrentAmount: 0, notes: nil))

        let g = repo.fetchGoals().first
        #expect(g?.deadlineDate == nil)
        #expect(g?.notes == nil, "une note absente ne doit pas devenir une chaîne vide")
    }

    @Test("La mise à jour écrase les valeurs modifiées et préserve les autres")
    func miseAJour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addGoal(name: "Voyage", kind: .savings, targetAmount: 2_000,
                             deadlineDate: nil, customCurrentAmount: 100, notes: nil))
        var g = repo.fetchGoals()[0]
        g.name = "Voyage Japon"
        g.customCurrentAmount = 1_750

        #expect(repo.updateGoal(g))

        let relu = repo.fetchGoals()[0]
        #expect(relu.name == "Voyage Japon")
        #expect(relu.customCurrentAmount == 1_750)
        #expect(relu.targetAmount == 2_000, "les champs non touchés sont préservés")
        #expect(relu.id == g.id)
    }

    @Test("Chaque nature d'objectif fait l'aller-retour sans se dénaturer")
    func naturesDObjectif() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        for kind in GoalKind.allCases {
            #expect(repo.addGoal(name: kind.rawValue, kind: kind, targetAmount: 1_000,
                                 deadlineDate: nil, customCurrentAmount: 0, notes: nil))
        }

        let relus = Dictionary(uniqueKeysWithValues: repo.fetchGoals().map { ($0.name, $0.kind) })
        for kind in GoalKind.allCases {
            #expect(relus[kind.rawValue] == kind, "\(kind.rawValue) relu incorrectement")
        }
    }

    @Test("La suppression ne retire que l'objectif visé")
    func suppressionCiblee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        for nom in ["A", "B", "C"] {
            #expect(repo.addGoal(name: nom, kind: .savings, targetAmount: 100,
                                 deadlineDate: nil, customCurrentAmount: 0, notes: nil))
        }
        let aSupprimer = repo.fetchGoals().first { $0.name == "B" }!

        #expect(repo.deleteGoal(id: aSupprimer.id))
        #expect(repo.fetchGoals().map(\.name).sorted() == ["A", "C"])
    }

    @Test("Supprimer un objectif inexistant ne casse rien")
    func suppressionInexistante() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        _ = repo.deleteGoal(id: 999_999)
        #expect(db.count("goals") == 0)
    }
}
