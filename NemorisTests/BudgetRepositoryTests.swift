import Foundation
import Testing
@testable import Nemoris

/// Le budget repose sur trois tables liées : les récurrents, les enveloppes, et
/// les prévisions engendrées par les récurrents.
@Suite("BudgetRepository")
struct BudgetRepositoryTests {

    private func fixture() throws -> (TestDatabase, BudgetRepository) {
        let db = try TestDatabase()
        return (db, BudgetRepository(store: db.store))
    }

    private func motif(nom: String = "Loyer", montant: Double = -1_200,
                       frequence: RecurrenceFrequency = .monthly,
                       actif: Bool = true) -> RecurringPattern {
        RecurringPattern(id: 0, name: nom, amountAvg: montant, amountTolerance: 10,
                         categoryId: nil, payeeId: nil, frequency: frequence,
                         anchorDay: 5, isActive: actif, isManual: true,
                         createdAt: Date(), lastDetectedAt: nil,
                         startDate: date("2026-01-01"), endDate: nil)
    }

    // MARK: - Récurrents

    @Test("Un récurrent créé est relu avec ses caractéristiques")
    func motifAllerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let id = repo.insertPattern(motif())
        #expect(id != nil)

        let relus = repo.fetchPatterns()
        #expect(relus.count == 1)
        let m = relus[0]
        #expect(m.name == "Loyer")
        #expect(m.amountAvg == -1_200)
        #expect(m.frequency == .monthly)
        #expect(m.anchorDay == 5)
        #expect(m.isActive)
        #expect(m.isManual)
    }

    @Test("Seuls les récurrents actifs remontent dans fetchActivePatterns")
    func motifsActifs() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        _ = repo.insertPattern(motif(nom: "Actif", actif: true))
        _ = repo.insertPattern(motif(nom: "Désactivé", actif: false))

        #expect(repo.fetchPatterns().count == 2)
        #expect(repo.fetchActivePatterns().map(\.name) == ["Actif"])
    }

    @Test("Chaque fréquence traverse la base sans se dénaturer")
    func frequences() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        for f in RecurrenceFrequency.allCases {
            _ = repo.insertPattern(motif(nom: f.rawValue, frequence: f))
        }

        let relus = Dictionary(uniqueKeysWithValues: repo.fetchPatterns().map { ($0.name, $0.frequency) })
        for f in RecurrenceFrequency.allCases {
            #expect(relus[f.rawValue] == f, "\(f.rawValue) relu incorrectement")
        }
    }

    @Test("Supprimer un récurrent emporte ses prévisions")
    func suppressionEnCascade() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif())!
        for mois in 1...3 {
            _ = repo.insertPrevision(BudgetPrevision(
                id: 0, recurringPatternId: motifId, amount: -1_200,
                expectedDate: date("2026-0\(mois)-05"), status: .pending,
                actualTransactionId: nil, notes: nil))
        }
        #expect(db.count("budget_previsions") == 3)

        repo.deletePattern(id: motifId)

        #expect(db.count("recurring_patterns") == 0)
        #expect(db.count("budget_previsions") == 0,
                "des prévisions orphelines réapparaîtraient dans le calendrier")
    }

    // MARK: - Enveloppes

    @Test("Une enveloppe créée est relue avec sa période")
    func enveloppeAllerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let id = repo.insertEnvelope(BudgetEnvelope(
            id: 0, name: "Courses", categoryId: nil, amount: 400,
            period: .monthly, startDate: date("2026-01-01"), isActive: true))
        #expect(id != nil)

        let e = repo.fetchEnvelopes()[0]
        #expect(e.name == "Courses")
        #expect(e.amount == 400)
        #expect(e.period == .monthly)
        #expect(e.isActive)
    }

    @Test("Une enveloppe annuelle reste annuelle en base")
    func enveloppeAnnuelle() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        _ = repo.insertEnvelope(BudgetEnvelope(
            id: 0, name: "Assurances", categoryId: nil, amount: 1_200,
            period: .yearly, startDate: date("2026-01-01"), isActive: true))

        // La mensualisation est le travail du calculateur, pas de la base :
        // stocker 100 au lieu de 1200 rendrait le montant saisi irrécupérable.
        let e = repo.fetchEnvelopes()[0]
        #expect(e.period == .yearly)
        #expect(e.amount == 1_200)
    }

    // MARK: - Prévisions

    @Test("Les prévisions sont filtrées par plage de dates, bornes incluses")
    func previsionsParPeriode() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif())!
        for jour in ["2026-01-05", "2026-02-05", "2026-03-05"] {
            _ = repo.insertPrevision(BudgetPrevision(
                id: 0, recurringPatternId: motifId, amount: -1_200,
                expectedDate: date(jour), status: .pending,
                actualTransactionId: nil, notes: nil))
        }

        #expect(repo.fetchPrevisions(from: date("2026-01-05"), to: date("2026-03-05")).count == 3)
        #expect(repo.fetchPrevisions(from: date("2026-02-01"), to: date("2026-02-28")).count == 1)
        #expect(repo.fetchPrevisions(forPatternId: motifId).count == 3)
    }

    @Test("Le statut d'une prévision bascule et retient la transaction rapprochée")
    func statutDePrevision() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif())!
        let prevId = repo.insertPrevision(BudgetPrevision(
            id: 0, recurringPatternId: motifId, amount: -1_200,
            expectedDate: date("2026-02-05"), status: .pending,
            actualTransactionId: nil, notes: nil))!

        repo.updatePrevisionStatus(id: prevId, status: .matched, transactionId: 42)

        let p = repo.fetchPrevisions(forPatternId: motifId)[0]
        #expect(p.status == .matched)
        #expect(p.actualTransactionId == 42)

        // Passer en ignoré doit relâcher le rapprochement.
        repo.updatePrevisionStatus(id: prevId, status: .skipped, transactionId: nil)
        let apres = repo.fetchPrevisions(forPatternId: motifId)[0]
        #expect(apres.status == .skipped)
        #expect(apres.actualTransactionId == nil)
    }

    @Test("Régénérer les prévisions ne les empile pas")
    func regenerationIdempotente() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let motifId = repo.insertPattern(motif())!
        let m = repo.fetchPatterns()[0]
        #expect(m.id == motifId)

        repo.regeneratePrevisions(for: m, monthsAhead: 3)
        let premier = db.count("budget_previsions")
        #expect(premier > 0, "un récurrent mensuel actif doit engendrer des prévisions")

        repo.regeneratePrevisions(for: m, monthsAhead: 3)
        #expect(db.count("budget_previsions") == premier,
                "une seconde génération dupliquerait les échéances du calendrier")
    }
}
