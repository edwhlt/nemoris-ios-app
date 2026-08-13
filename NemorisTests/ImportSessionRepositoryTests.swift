import Foundation
import Testing
@testable import Nemoris

/// Persistance d'une session d'import.
///
/// C'est le seul dépôt dont un défaut fait perdre du TRAVAIL à
/// l'utilisateur : classer les lignes d'un relevé prend de longues minutes, et
/// une session mal relue renvoie à zéro. D'où deux exigences — l'aller-retour
/// doit être fidèle, et le format déjà écrit sur disque doit rester lisible
/// par les versions suivantes.
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

        // Un bandeau « import en cours » sans rien à classer serait une impasse.
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

        // C'est exactement le travail que l'utilisateur ne doit pas refaire.
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

        // Ce compteur alimente le bandeau et le rappel : il doit refléter le
        // travail restant, pas le total.
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

        // Sinon le bandeau « import en cours » survivrait au commit.
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

        // Une analyse de relevé se compte en dizaines de secondes : la perdre
        // au relancement de l'app était l'asymétrie que cette table corrige.
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

        // Le contenu de `rows_json` diffère selon la destination : c'est la
        // colonne qui tranche, jamais une tentative de décodage.
        let session = try #require(repo.fetchSummaries().first)
        #expect(session.destination == .transactions)
    }

    // MARK: - Mémoire des formats de fichier

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

        // L'utilisateur a corrigé son mapping : c'est la correction qui doit
        // être proposée au prochain import, pas la version d'origine.
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
        // Deux relevés du même établissement ne diffèrent souvent que par ça ;
        // les traiter comme des formats distincts ferait remapper pour rien.
        #expect(ColumnMappingSignature.compute(headers: ["date", "libelle", "montant"]) == reference)
        #expect(ColumnMappingSignature.compute(headers: ["DATE", "LIBELLE", "MONTANT"]) == reference)
        #expect(ColumnMappingSignature.compute(headers: ["Date", "Montant", "Libellé"]) != reference,
                "l'ordre des colonnes, lui, change bien le format")
    }
}
