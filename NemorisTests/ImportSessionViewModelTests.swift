import Foundation
import Testing
@testable import Nemoris

/// An import session: sorting, grouping by label, and the decision cascade.
///
/// The cascade is what makes import bearable — deciding on one
/// row applies it to all its twins. It's also the most dangerous part: a
/// cascade that's too broad would overwrite decisions the user already
/// made, silently, in the middle of hundreds of rows.
@MainActor
@Suite("ImportSessionViewModel")
struct ImportSessionViewModelTests {

    private func ligne(_ n: Int, _ libelle: String, montant: Double = -20,
                       jour: String = "2026-03-10") -> ImportSessionRow {
        ImportSessionRow(sourceRowNumber: n, rawLabel: libelle,
                         date: date(jour), amount: montant)
    }

    private func fixture(_ rows: [ImportSessionRow]) throws -> (TestDatabase, ImportSessionViewModel) {
        let db = try TestDatabase()
        let session = ImportSession(id: UUID(), createdAt: Date(), updatedAt: Date(),
                                    status: .active, sourceFile: "test.csv", accountId: 1,
                                    rows: rows)
        return (db, ImportSessionViewModel(session: session, store: db.store))
    }

    // MARK: - Grouping by label

    @Test("Le regroupement ignore la casse, les accents et les espaces de bord")
    func cleDeRegroupement() {
        let base = ImportSessionViewModel.clusterKey("GRAB HEADQUARTERS SG")
        #expect(ImportSessionViewModel.clusterKey("  grab headquarters sg  ") == base)
        #expect(ImportSessionViewModel.clusterKey("Grab Headquarters SG") == base)
        #expect(ImportSessionViewModel.clusterKey("GRÂB HEADQUARTERS SG") == base,
                "un accent d'OCR ne doit pas casser le regroupement")
    }

    @Test("Deux libellés différents ne se regroupent pas")
    func regroupementsDistincts() {
        #expect(ImportSessionViewModel.clusterKey("CARREFOUR") != ImportSessionViewModel.clusterKey("CASINO"))
    }

    @Test("La taille d'un groupe compte la ligne elle-même")
    func tailleDuGroupe() throws {
        let rows = [ligne(1, "NETFLIX"), ligne(2, "netflix"), ligne(3, "SPOTIFY")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        #expect(vm.clusterSize(for: rows[0]) == 2, "obtenu : \(vm.clusterSize(for: rows[0]))")
        #expect(vm.clusterSize(for: rows[2]) == 1, "une ligne seule forme un groupe d'elle-même")
    }

    // MARK: - Cascade

    @Test("Confirmer une ligne confirme ses jumelles encore en attente")
    func cascadeDeConfirmation() throws {
        let rows = [ligne(1, "NETFLIX"), ligne(2, "NETFLIX"), ligne(3, "NETFLIX"), ligne(4, "SPOTIFY")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        let cascadees = vm.confirm(rowId: rows[0].id)

        #expect(cascadees == 2, "deux jumelles, obtenu : \(cascadees)")
        let etats = Dictionary(uniqueKeysWithValues: vm.displayedRows.map { ($0.sourceRowNumber, $0.userAction) })
        #expect(etats[1] == .confirmed)
        #expect(etats[2] == .confirmed)
        #expect(etats[3] == .confirmed)
        #expect(etats[4] == .pending, "une ligne d'un autre groupe ne doit pas bouger")
    }

    @Test("La cascade n'écrase jamais une décision déjà prise")
    func cascadeNEcrasePas() throws {
        let rows = [ligne(1, "NETFLIX"), ligne(2, "NETFLIX"), ligne(3, "NETFLIX")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        // The user deliberately dismisses a row from the group…
        _ = vm.skip(rowId: rows[1].id, cascade: false)
        // …then confirms another one. Their earlier decision must survive.
        _ = vm.confirm(rowId: rows[0].id)

        let etats = Dictionary(uniqueKeysWithValues: vm.displayedRows.map { ($0.sourceRowNumber, $0.userAction) })
        #expect(etats[2] == .skipped,
                "écraser un choix explicite au milieu de centaines de lignes serait invisible")
        #expect(etats[1] == .confirmed)
        #expect(etats[3] == .confirmed)
    }

    @Test("La cascade peut être refusée ligne par ligne")
    func cascadeDesactivable() throws {
        let rows = [ligne(1, "NETFLIX"), ligne(2, "NETFLIX")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        #expect(vm.confirm(rowId: rows[0].id, cascade: false) == 0)
        let etats = Dictionary(uniqueKeysWithValues: vm.displayedRows.map { ($0.sourceRowNumber, $0.userAction) })
        #expect(etats[2] == .pending)
    }

    @Test("Ignorer une ligne ignore ses jumelles en attente")
    func cascadeDIgnorance() throws {
        let rows = [ligne(1, "FRAIS BANCAIRES"), ligne(2, "FRAIS BANCAIRES")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        #expect(vm.skip(rowId: rows[0].id) == 1)
        #expect(vm.displayedRows.allSatisfy { $0.userAction == .skipped })
    }

    @Test("Réinitialiser une ligne ne touche jamais ses jumelles")
    func reinitialisationSansCascade() throws {
        let rows = [ligne(1, "NETFLIX"), ligne(2, "NETFLIX")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }
        _ = vm.confirm(rowId: rows[0].id)

        // Deliberate: it must be possible to revise ONE row without undoing the group.
        vm.resetAction(rowId: rows[0].id)

        let etats = Dictionary(uniqueKeysWithValues: vm.displayedRows.map { ($0.sourceRowNumber, $0.userAction) })
        #expect(etats[1] == .pending)
        #expect(etats[2] == .confirmed, "la jumelle garde la décision cascadée")
    }

    @Test("Agir sur une ligne inconnue ne fait rien")
    func ligneInconnue() throws {
        let rows = [ligne(1, "NETFLIX")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        #expect(vm.confirm(rowId: UUID()) == 0)
        #expect(vm.displayedRows[0].userAction == .pending)
    }

    // MARK: - Sorting

    @Test("Le tri par statut remonte les lignes en attente en premier")
    func triParStatut() throws {
        let rows = [ligne(1, "A"), ligne(2, "B"), ligne(3, "C")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }
        _ = vm.confirm(rowId: rows[0].id, cascade: false)
        _ = vm.skip(rowId: rows[1].id, cascade: false)

        vm.sortMode = .byStatus
        // What's left to handle must be first: that's the remaining work.
        #expect(vm.displayedRows.first?.sourceRowNumber == 3,
                "obtenu : \(vm.displayedRows.map(\.sourceRowNumber))")
    }

    @Test("Le tri par date fonctionne dans les deux sens")
    func triParDate() throws {
        let rows = [ligne(1, "A", jour: "2026-03-20"),
                    ligne(2, "B", jour: "2026-03-05"),
                    ligne(3, "C", jour: "2026-03-12")]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        vm.sortMode = .byDateAsc
        #expect(vm.displayedRows.map(\.sourceRowNumber) == [2, 3, 1])

        vm.sortMode = .byDateDesc
        #expect(vm.displayedRows.map(\.sourceRowNumber) == [1, 3, 2])
    }

    @Test("Le tri par montant utilise la valeur absolue")
    func triParMontant() throws {
        let rows = [ligne(1, "A", montant: -30),
                    ligne(2, "B", montant: 500),
                    ligne(3, "C", montant: -120)]
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        vm.sortMode = .byAmountAbs
        // A €500 income weighs as much as a €500 expense in the review.
        #expect(vm.displayedRows.map(\.sourceRowNumber) == [2, 3, 1])
    }

    @Test("Le tri ne perd ni ne duplique de ligne")
    func triConserveLesLignes() throws {
        let rows = (1...6).map { ligne($0, "Libellé \($0)", montant: Double(-$0 * 10)) }
        let (db, vm) = try fixture(rows)
        defer { db.destroy() }

        for mode in [ImportSortMode.byStatus, .byDateAsc, .byDateDesc, .byAmountAbs] {
            vm.sortMode = mode
            #expect(Set(vm.displayedRows.map(\.sourceRowNumber)).count == 6,
                    "\(mode) : \(vm.displayedRows.map(\.sourceRowNumber))")
        }
    }
}
