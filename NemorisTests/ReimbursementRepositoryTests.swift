import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// Tests for the unified `reimbursements` table (migration v44).
///
/// It carries an XOR constraint: a row is attached to either a
/// transaction or a Tricount entry, never both nor neither. This
/// constraint isn't decorative — it's what makes inserting an orphan
/// row fail when a sync batch arrives out of
/// order, letting the deferral mechanism replay it later.
@Suite("ReimbursementRepository")
struct ReimbursementRepositoryTests {

    private func fixture() throws -> (TestDatabase, TransactionRepository, ReimbursementRepository) {
        let db = try TestDatabase()
        return (db, TransactionRepository(store: db.store), ReimbursementRepository(store: db.store))
    }

    /// An account + transaction + creditor payee, the common fixture for these tests.
    private func contexte(_ repo: TransactionRepository) -> (transactionId: Int, payeeId: Int) {
        _ = repo.addAccount(name: "Courant")
        let compte = repo.fetchAccounts()[0]
        let payeeId = repo.addTiersAndGetId(name: "Papa", regex: "PAPA")!
        let txId = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                       paymentTypeId: nil, information: "Avance", amount: -120,
                                       date: date("2026-03-10"))!
        return (txId, payeeId)
    }

    @Test("Assigner puis relire un remboursement sur une transaction")
    func assignation() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }
        let (txId, payeeId) = contexte(repo)

        #expect(rembours.fetchReimbursement(forTransaction: txId) == nil)

        #expect(rembours.setReimbursement(transactionId: txId, payeeId: payeeId))
        let lu = rembours.fetchReimbursement(forTransaction: txId)
        #expect(lu?.payeeId == payeeId)
        #expect(lu?.payeeName == "Papa")
        #expect(lu?.status == .pending)
        #expect(lu?.tricountEntryId == nil, "origine transaction : l'autre lien reste nul")
    }

    @Test("Passer le tiers à nil retire le remboursement")
    func retrait() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }
        let (txId, payeeId) = contexte(repo)

        #expect(rembours.setReimbursement(transactionId: txId, payeeId: payeeId))
        #expect(db.count("reimbursements") == 1)

        #expect(rembours.setReimbursement(transactionId: txId, payeeId: nil))
        #expect(db.count("reimbursements") == 0)
        #expect(rembours.fetchReimbursement(forTransaction: txId) == nil)
    }

    /// Disabled until the cause is established — a red test whose
    /// cause is unknown ends up being ignored, and the rest of the suite with it.
    ///
    /// Symptom: reassigning a creditor on the same transaction passes when
    /// this test runs ALONE, and fails as soon as other tests run in the
    /// same process. Reproduced three times out of three. Serializing the suite
    /// changes nothing: so it isn't a race between parallel tests, even
    /// though each one has its own temp database.
    ///
    /// Ruled out by reading the code: SQLite locking (busy_timeout is
    /// now set everywhere), the ON CONFLICT clause on a partial index (well
    /// formed, otherwise the first assignment would also fail), and sync
    /// trigger recursion (disabled by default).
    ///
    /// Next step: `SQLiteStore.writeSingle` only returns a boolean and
    /// hides the SQLite error code. Surfacing `sqlite3_errmsg` should settle it
    /// immediately — here as with the following cases.
    @Test("Une transaction ne porte qu'un seul remboursement")
    func cardinaliteUnAUn() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }
        let (txId, papa) = contexte(repo)
        let maman = repo.addTiersAndGetId(name: "Maman", regex: "MAMAN")!

        let premier = rembours.setReimbursement(transactionId: txId, payeeId: papa)
        let apresPremier = db.count("reimbursements")
        let second = rembours.setReimbursement(transactionId: txId, payeeId: maman)
        let apresSecond = db.count("reimbursements")
        let lu = rembours.fetchReimbursement(forTransaction: txId)

        #expect(premier, "premier assignement refusé")
        #expect(apresPremier == 1, "après le premier : \(apresPremier) ligne(s)")
        #expect(second, "réassignement refusé (papa=\(papa), maman=\(maman))")

        // The partial unique index on transaction_id enforces replacement,
        // not accumulation.
        #expect(apresSecond == 1, "après le second : \(apresSecond) ligne(s)")
        #expect(lu?.payeeId == maman,
                "tiers relu : \(lu.map { String($0.payeeId) } ?? "aucun") au lieu de \(maman)")
    }

    @Test("Le statut bascule et revient")
    func statut() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }
        let (txId, payeeId) = contexte(repo)
        #expect(rembours.setReimbursement(transactionId: txId, payeeId: payeeId))

        let id = rembours.fetchReimbursement(forTransaction: txId)!.id
        #expect(rembours.markReceived(id: id))
        #expect(rembours.fetchReimbursement(forTransaction: txId)?.status == .received)

        #expect(rembours.markPending(id: id))
        #expect(rembours.fetchReimbursement(forTransaction: txId)?.status == .pending)
    }

    @Test("Supprimer le tiers créancier supprime ses remboursements")
    func cascadePayee() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }
        let (txId, payeeId) = contexte(repo)
        #expect(rembours.setReimbursement(transactionId: txId, payeeId: payeeId))
        #expect(db.count("reimbursements") == 1)

        #expect(rembours.deleteReimbursements(payeeId: payeeId))
        #expect(db.count("reimbursements") == 0)
        #expect(db.count("transactions") == 1, "la transaction d'origine survit")
    }

    @Test("La contrainte XOR rejette une ligne sans origine")
    func contrainteXOR() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        func insere(_ sql: String) -> Bool {
            db.store.write { handle in
                sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
            } ?? false
        }

        // No origin at all: must be rejected.
        #expect(insere("""
            INSERT INTO reimbursements (transaction_id, tricount_entry_id, payee_id, status, uuid, updated_at)
            VALUES (NULL, NULL, 1, 'PENDING', 'u1', '2026-03-01T00:00:00.000Z');
            """) == false, "une ligne sans origine doit violer le CHECK")

        // Both origins: must also be rejected.
        #expect(insere("""
            INSERT INTO reimbursements (transaction_id, tricount_entry_id, payee_id, status, uuid, updated_at)
            VALUES (1, 1, 1, 'PENDING', 'u2', '2026-03-01T00:00:00.000Z');
            """) == false, "une ligne à double origine doit violer le CHECK")

        #expect(db.count("reimbursements") == 0)
    }

    @Test("Le regroupement par période ne retient que la plage demandée")
    func regroupementParPeriode() throws {
        let (db, repo, rembours) = try fixture()
        defer { db.destroy() }

        _ = repo.addAccount(name: "Courant")
        let compte = repo.fetchAccounts()[0]
        let payeeId = repo.addTiersAndGetId(name: "Papa", regex: "PAPA")!

        for jour in ["2026-02-15", "2026-03-10", "2026-04-05"] {
            let txId = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                           paymentTypeId: nil, information: jour, amount: -50,
                                           date: date(jour))!
            #expect(rembours.setReimbursement(transactionId: txId, payeeId: payeeId))
        }

        let mars = rembours.fetchReimbursementGroups(from: date("2026-03-01"), to: date("2026-03-31"))
        #expect(mars.count == 1, "un seul créancier")
        #expect(mars.first?.items.count == 1, "une seule transaction dans la plage")

        let trimestre = rembours.fetchReimbursementGroups(from: date("2026-02-01"), to: date("2026-04-30"))
        #expect(trimestre.first?.items.count == 3)
    }
}
