import Foundation
import Testing
@testable import Nemoris

/// Persisting an import session.
///
/// This is the only repository whose defect makes the user LOSE
/// work: classifying a statement's rows takes long minutes, and
/// a poorly restored session resets to zero. Hence two requirements — the
/// round-trip must be faithful, and the format already written to disk must stay
/// readable by future versions.
@Suite("Session d'import")
struct ImportSessionRepositoryTests {

    private func fixture() throws -> (TestDatabase, ImportSessionRepository) {
        let db = try TestDatabase()
        return (db, ImportSessionRepository(store: db.store))
    }

    private func ligne(_ n: Int, _ libelle: String, montant: Double = -20,
                       jour: String = "2026-03-10") -> ImportSessionRow {
        ImportSessionRow(sourceRowNumber: n, rawLabel: libelle,
                         date: date(jour), amount: montant)
    }

    // MARK: - Aller-retour

    @Test("Une session créée se relit avec toutes ses lignes")
    func allerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let resume = try #require(repo.createSession(
            rows: [ligne(1, "CARREFOUR"), ligne(2, "NETFLIX", montant: -12.99)],
            accountId: 7, sourceFile: "releve.csv"))

        let session = try #require(repo.fetchSession(id: resume.id))
        #expect(session.accountId == 7)
        #expect(session.sourceFile == "releve.csv")
        #expect(session.rows.count == 2)
        #expect(session.rows.map(\.rawLabel) == ["CARREFOUR", "NETFLIX"],
                "l'ordre des lignes est celui du relevé")
        #expect(abs((session.rows.last?.amount ?? 0) + 12.99) < 0.005,
                "les centimes survivent à l'aller-retour")
    }

    @Test("Une session sans ligne n'est pas créée")
    func sessionVideRefusee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // An "import in progress" banner with nothing to classify would be a dead end.
        #expect(repo.createSession(rows: [], accountId: 1, sourceFile: "vide.csv") == nil)
        #expect(repo.fetchSummaries().isEmpty)
    }

    @Test("Les décisions prises sur les lignes sont conservées")
    func decisionsConservees() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let resume = try #require(repo.createSession(
            rows: [ligne(1, "A"), ligne(2, "B"), ligne(3, "C")],
            accountId: 1, sourceFile: nil))
        var session = try #require(repo.fetchSession(id: resume.id))

        session.rows[0].userAction = .confirmed
        session.rows[1].userAction = .skipped
        #expect(repo.saveSession(session))

        // This is exactly the work the user must not have to redo.
        let relue = try #require(repo.fetchSession(id: resume.id))
        #expect(relue.rows[0].userAction == .confirmed)
        #expect(relue.rows[1].userAction == .skipped)
        #expect(relue.rows[2].userAction == .pending)
    }

    @Test("Le nombre de lignes restantes suit les décisions")
    func comptageDesRestantes() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let resume = try #require(repo.createSession(
            rows: [ligne(1, "A"), ligne(2, "B"), ligne(3, "C")],
            accountId: 1, sourceFile: nil))
        #expect(resume.pendingRows == 3)

        var session = try #require(repo.fetchSession(id: resume.id))
        session.rows[0].userAction = .confirmed
        #expect(repo.saveSession(session))

        // This counter feeds the banner and the reminder: it must reflect the
        // work remaining, not the total.
        let apres = try #require(repo.fetchActiveSummary())
        #expect(apres.pendingRows == 2, "obtenu : \(apres.pendingRows)")
        #expect(apres.totalRows == 3)
    }

    // MARK: - Session active

    @Test("Une seule session active est proposée à la reprise")
    func sessionActiveUnique() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.createSession(rows: [ligne(1, "A")], accountId: 1, sourceFile: "a.csv")

        let active = try #require(repo.fetchActiveSummary())
        #expect(active.sourceFile == "a.csv")
    }

    @Test("Une session terminée n'est plus proposée")
    func sessionTermineeEcartee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let resume = try #require(repo.createSession(rows: [ligne(1, "A")],
                                                     accountId: 1, sourceFile: nil))
        var session = try #require(repo.fetchSession(id: resume.id))

        session.status = .completed
        #expect(repo.saveSession(session))

        // Otherwise the "import in progress" banner would survive the commit.
        #expect(repo.fetchActiveSummary() == nil)
        #expect(repo.fetchSummaries(status: .completed).count == 1,
                "elle reste consultable, simplement plus active")
    }

    @Test("Supprimer une session la retire complètement")
    func suppression() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let resume = try #require(repo.createSession(rows: [ligne(1, "A")],
                                                     accountId: 1, sourceFile: nil))

        #expect(repo.deleteSession(id: resume.id))
        #expect(repo.fetchSession(id: resume.id) == nil)
        #expect(repo.fetchActiveSummary() == nil)
    }

    @Test("Lire une session inexistante rend l'absence")
    func sessionInexistante() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.fetchSession(id: UUID()) == nil)
        #expect(repo.fetchActiveSummary() == nil)
    }

    // MARK: - Sessions d'investissement

    @Test("Une analyse d'investissements survit au redémarrage")
    func sessionInvestissements() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let lot = ImportBatchResult(elements: [
            ImportElement(origin: ImportElementOrigin(sourceName: "avis.pdf", kind: .pdf),
                          payload: .investmentOrder(ExtractedStatementOrder(
                              orderType: "BUY", assetName: "ISHS CORE", isin: "IE0008471009",
                              quantity: 4, unitPrice: 55.62, fees: 1.11,
                              executedAt: "2026-03-10", currency: "EUR",
                              notes: nil, confidence: 0.9)))
        ])

        let resume = try #require(repo.createSession(batch: lot, accountId: 3,
                                                     sourceFile: "avis.pdf"))

        // Analyzing a statement takes tens of seconds: losing it
        // on app relaunch was the asymmetry this table fixes.
        let session = try #require(repo.fetchSession(id: resume.id))
        #expect(session.destination == .investments)
        #expect(session.batch?.elements.count == 1)
        #expect(resume.destination == .investments)
    }

    @Test("Un lot d'investissements vide n'est pas persisté")
    func lotVideRefuse() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.createSession(batch: ImportBatchResult(),
                                   accountId: 1, sourceFile: nil) == nil)
    }

    @Test("Les deux natures de session ne se confondent pas")
    func naturesDistinctes() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        _ = repo.createSession(rows: [ligne(1, "A")], accountId: 1, sourceFile: "tx.csv")

        // The content of `rows_json` differs by destination: it's the
        // column that decides, never a decoding attempt.
        let session = try #require(repo.fetchSummaries().first)
        #expect(session.destination == .transactions)
    }

    // MARK: - Remembering file formats

    @Test("Un format de colonnes déjà rencontré est retrouvé par sa signature")
    func memoireDuFormat() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let mapping = ColumnMapping(headerSignature: "date|libelle|montant",
                                    dateColumnIndex: 0, amountColumnIndex: 2,
                                    labelColumnIndex: 1, separator: ";",
                                    dateFormat: "dd/MM/yyyy", amountDecimal: ",")

        #expect(repo.saveMapping(mapping))

        let relu = try #require(repo.findMapping(headerSignature: "date|libelle|montant"))
        #expect(relu.dateColumnIndex == 0)
        #expect(relu.amountColumnIndex == 2)
        #expect(relu.separator == ";")
        #expect(relu.amountDecimal == ",", "la convention décimale fait partie du format")
    }

    @Test("Réenregistrer un format le met à jour au lieu de le dupliquer")
    func formatMisAJour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let signature = "date|libelle|montant"
        #expect(repo.saveMapping(ColumnMapping(headerSignature: signature,
                                               dateColumnIndex: 0, amountColumnIndex: 1,
                                               labelColumnIndex: 2, separator: ";",
                                               dateFormat: nil, amountDecimal: ",")))
        #expect(repo.saveMapping(ColumnMapping(headerSignature: signature,
                                               dateColumnIndex: 2, amountColumnIndex: 0,
                                               labelColumnIndex: 1, separator: ",",
                                               dateFormat: nil, amountDecimal: ".")))

        // The user corrected their mapping: it's the correction that must
        // be offered on the next import, not the original version.
        let relu = try #require(repo.findMapping(headerSignature: signature))
        #expect(relu.dateColumnIndex == 2)
        #expect(relu.separator == ",")
    }

    @Test("Un format inconnu n'est pas inventé")
    func formatInconnu() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.findMapping(headerSignature: "jamais|vu") == nil)
    }

    @Test("La signature d'en-tête ignore la casse et les accents")
    func signatureNormalisee() {
        let reference = ColumnMappingSignature.compute(headers: ["Date", "Libellé", "Montant"])
        // Two statements from the same institution often only differ by
        // this; treating them as distinct formats would force remapping for nothing.
        #expect(ColumnMappingSignature.compute(headers: ["date", "libelle", "montant"]) == reference)
        #expect(ColumnMappingSignature.compute(headers: ["DATE", "LIBELLE", "MONTANT"]) == reference)
        #expect(ColumnMappingSignature.compute(headers: ["Date", "Montant", "Libellé"]) != reference,
                "l'ordre des colonnes, lui, change bien le format")
    }
}
