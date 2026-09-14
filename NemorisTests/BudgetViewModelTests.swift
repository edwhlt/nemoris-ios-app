import Foundation
import Testing
@testable import Nemoris

/// The budget's presentation logic.
///
/// The ViewModel is `@MainActor` and its `refresh()` launches a detached
/// task, so it can't be awaited from outside. The tests target what's
/// deterministic: in-memory state transformations, navigation between
/// months, and writes, which are synchronous.
@MainActor
@Suite("BudgetViewModel")
struct BudgetViewModelTests {

    private func fixture() throws -> (TestDatabase, BudgetViewModel, BudgetRepository) {
        let db = try TestDatabase()
        return (db, BudgetViewModel(store: db.store), BudgetRepository(store: db.store))
    }

    private func motif(id: Int, nom: String, categorie: Int? = nil,
                       montant: Double = -50) -> RecurringPattern {
        RecurringPattern(id: id, name: nom, amountAvg: montant, amountTolerance: 0.1,
                         categoryId: categorie, payeeId: nil, frequency: .monthly,
                         anchorDay: 5, isActive: true, isManual: true,
                         createdAt: date("2026-01-01"), lastDetectedAt: nil,
                         startDate: date("2026-01-01"), endDate: nil)
    }

    private func prevision(id: Int, motifId: Int? = nil, montant: Double = -50,
                           jour: String = "2026-03-05",
                           statut: PrevisionStatus = .pending) -> BudgetPrevision {
        BudgetPrevision(id: id, recurringPatternId: motifId, amount: montant,
                        expectedDate: date(jour), status: statut,
                        actualTransactionId: nil, notes: nil)
    }

    private func enveloppe(id: Int, categorie: Int?, montant: Double,
                           periode: BudgetPeriod = .monthly,
                           active: Bool = true) -> BudgetEnvelope {
        BudgetEnvelope(id: id, name: "Enveloppe \(id)", categoryId: categorie,
                       amount: montant, period: periode,
                       startDate: date("2026-01-01"), isActive: active)
    }

    // MARK: - Enrichissement

    @Test("Une prévision est enrichie du nom de son récurrent et de sa catégorie")
    func enrichissement() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.categories = [Nemoris.Category(id: 3, name: "Logement")]
        vm.patterns = [motif(id: 1, nom: "Loyer", categorie: 3)]
        vm.previsions = [prevision(id: 10, motifId: 1)]

        #expect(vm.enrichedPrevisions.count == 1)
        #expect(vm.enrichedPrevisions[0].patternName == "Loyer")
        #expect(vm.enrichedPrevisions[0].categoryName == "Logement")
    }

    @Test("Une prévision sans récurrent est étiquetée manuelle plutôt que vide")
    func previsionManuelle() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.previsions = [prevision(id: 10, motifId: nil)]

        #expect(vm.enrichedPrevisions[0].patternName == "Manuel",
                "un libellé vide dans le calendrier ne dirait rien à l'utilisateur")
        #expect(vm.enrichedPrevisions[0].categoryName == nil)
    }

    @Test("L'enrichissement se reconstruit quelle que soit la source modifiée")
    func cacheJamaisObsolete() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        // The three sources each carry a didSet that rebuilds the list. That's
        // what guarantees it can never go stale, whatever
        // the assignment order — loading, refresh, skip.
        vm.previsions = [prevision(id: 10, motifId: 1)]
        #expect(vm.enrichedPrevisions[0].patternName == "Manuel", "aucun motif connu encore")

        vm.patterns = [motif(id: 1, nom: "Loyer", categorie: 3)]
        #expect(vm.enrichedPrevisions[0].patternName == "Loyer", "le motif arrivé après doit être pris")

        vm.categories = [Nemoris.Category(id: 3, name: "Logement")]
        #expect(vm.enrichedPrevisions[0].categoryName == "Logement",
                "la catégorie arrivée en dernier doit l'être aussi")
    }

    @Test("Les prévisions enrichies sont triées par date")
    func triParDate() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.previsions = [prevision(id: 1, jour: "2026-03-20"),
                         prevision(id: 2, jour: "2026-03-05"),
                         prevision(id: 3, jour: "2026-03-12")]

        #expect(vm.enrichedPrevisions.map(\.prevision.id) == [2, 3, 1],
                "obtenu : \(vm.enrichedPrevisions.map(\.prevision.id))")
    }

    @Test("Seules les prévisions en attente alimentent la liste des échéances")
    func previsionsEnAttente() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.previsions = [prevision(id: 1, statut: .pending),
                         prevision(id: 2, statut: .matched),
                         prevision(id: 3, statut: .skipped)]

        #expect(vm.pendingPrevisions.map(\.prevision.id) == [1])
    }

    // MARK: - Navigation between months

    @Test("La navigation avance et recule d'un mois exactement")
    func navigationMensuelle() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.displayedMonth = date("2026-03-01")
        vm.nextMonth()
        #expect(Calendar.current.component(.month, from: vm.displayedMonth) == 4)

        vm.previousMonth()
        vm.previousMonth()
        #expect(Calendar.current.component(.month, from: vm.displayedMonth) == 2)
    }

    @Test("La navigation franchit correctement le changement d'année")
    func passageDAnnee() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.displayedMonth = date("2026-12-01")
        vm.nextMonth()

        let cal = Calendar.current
        #expect(cal.component(.year, from: vm.displayedMonth) == 2027)
        #expect(cal.component(.month, from: vm.displayedMonth) == 1)
    }

    // MARK: - Monthly summary

    @Test("Le prévu fixe somme les prévisions de dépense, en ignorant les ignorées")
    func previsionnelFixe() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.previsions = [prevision(id: 1, montant: -950),
                         prevision(id: 2, montant: -50),
                         prevision(id: 3, montant: -300, statut: .skipped),
                         prevision(id: 4, montant: 2_000)]   // un revenu

        let resume = vm.monthlySummary(transactions: [])
        #expect(abs(resume.forecastedExpenses - 1_000) < 0.01,
                "prévu : \(resume.forecastedExpenses)")
    }

    @Test("Une enveloppe déjà couverte par un récurrent n'est pas comptée deux fois")
    func pasDeDoubleComptage() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        // A €950 recurring pattern and a €1,100 envelope on the same
        // category: the forecast must be €1,100, not €2,050. Without this
        // deduction, the budget would show a forecast double the real amount.
        vm.categories = [Nemoris.Category(id: 3, name: "Logement")]
        vm.patterns = [motif(id: 1, nom: "Loyer", categorie: 3, montant: -950)]
        vm.previsions = [prevision(id: 10, motifId: 1, montant: -950)]
        vm.envelopes = [enveloppe(id: 1, categorie: 3, montant: 1_100)]

        let resume = vm.monthlySummary(transactions: [])
        #expect(abs(resume.forecastedExpenses - 1_100) < 1.0,
                "prévu : \(resume.forecastedExpenses)")
    }

    @Test("Une enveloppe annuelle est mensualisée dans le prévisionnel")
    func enveloppeAnnuelleMensualisee() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        // €1,200 a year must weigh €100 on the displayed month.
        vm.envelopes = [enveloppe(id: 1, categorie: nil, montant: 1_200, periode: .yearly)]

        let resume = vm.monthlySummary(transactions: [])
        #expect(abs(resume.forecastedExpenses - 100) < 0.01,
                "prévu : \(resume.forecastedExpenses)")
    }

    @Test("Une enveloppe désactivée ne pèse pas sur le prévisionnel")
    func enveloppeDesactivee() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.envelopes = [enveloppe(id: 1, categorie: nil, montant: 500, active: false)]

        #expect(vm.monthlySummary(transactions: []).forecastedExpenses == 0)
    }

    // MARK: - Writes

    @Test("Ignorer une prévision la marque comme telle en base")
    func ignorerUnePrevision() throws {
        let (db, vm, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif(id: 0, nom: "Loyer"))!
        let prevId = repo.insertPrevision(prevision(id: 0, motifId: motifId))!

        vm.skipPrevision(prevision(id: prevId, motifId: motifId))

        let relue = repo.fetchPrevisions(forPatternId: motifId).first
        #expect(relue?.status == .skipped)
    }

    @Test("Rapprocher une prévision retient la transaction associée")
    func rapprocherUnePrevision() throws {
        let (db, vm, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif(id: 0, nom: "Loyer"))!
        let prevId = repo.insertPrevision(prevision(id: 0, motifId: motifId))!

        vm.matchPrevision(prevision(id: prevId, motifId: motifId), to: 42)

        let relue = repo.fetchPrevisions(forPatternId: motifId).first
        #expect(relue?.status == .matched)
        #expect(relue?.actualTransactionId == 42)
    }
}
