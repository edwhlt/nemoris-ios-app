import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// Non-regression: an UPSERT must remain possible on a synced table.
///
/// SQLite documents that if the statement triggering a trigger carries an
/// `ON CONFLICT` clause, that outer statement's conflict-resolution policy
/// overrides the one written in the trigger's body. The sync triggers'
/// `INSERT OR REPLACE INTO sync_pending` therefore lost its `OR REPLACE`
/// and failed on the uniqueness constraint, making the whole UPSERT fail.
///
/// The user-facing symptom before the fix: changing the creditor on an
/// already-assigned reimbursement did nothing, with no error message.
@Suite("Triggers de synchronisation et UPSERT")
struct SyncTriggerUpsertTests {

    @Test("Un UPSERT réussit sur une ligne déjà mise en file de synchronisation")
    func upsertRepete() throws {
        let db = try TestDatabase()
        defer { db.destroy() }
        let repo = TransactionRepository(store: db.store)

        _ = repo.addAccount(name: "Courant")
        let compte = repo.fetchAccounts()[0]
        let papa = repo.addTiersAndGetId(name: "Papa", regex: "PAPA")!
        let maman = repo.addTiersAndGetId(name: "Maman", regex: "MAMAN")!
        let txId = repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                       paymentTypeId: nil, information: "Avance", amount: -120,
                                       date: date("2026-03-10"))!

        let sql = """
            INSERT INTO reimbursements (transaction_id, payee_id) VALUES (?, ?)
            ON CONFLICT(transaction_id) WHERE transaction_id IS NOT NULL
            DO UPDATE SET payee_id = excluded.payee_id;
            """

        /// Returns SQLite's error message, or `nil` if the write succeeded.
        func upsert(_ payeeId: Int) -> String? {
            db.store.write { handle -> String? in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    return "prepare : " + String(cString: sqlite3_errmsg(handle))
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(txId))
                sqlite3_bind_int(stmt, 2, Int32(payeeId))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    return String(cString: sqlite3_errmsg(handle))
                }
                return nil
            } ?? "connexion impossible"
        }

        #expect(upsert(papa) == nil)

        // The first pass enqueued the row. It's this second UPSERT that was
        // failing, on "UNIQUE constraint failed: sync_pending".
        let erreur = upsert(maman)
        #expect(erreur == nil, "second UPSERT refusé : \(erreur ?? "")")

        #expect(db.count("reimbursements") == 1)
        #expect(db.count("sync_pending") >= 1, "la ligne reste bien en file de synchronisation")
    }
}
