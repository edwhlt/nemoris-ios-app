import Foundation
import SQLite3

private let SQLITE_TRANSIENT_RB = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Remboursements — table unifiée `reimbursements` (v44, AXE R), rattachée à
/// une transaction simple (0..1 payee, `idx_reimbursements_transaction`) OU une
/// entrée Tricount (0..N payees, `idx_reimbursements_tricount`), jamais les
/// deux (CHECK XOR en base). Remplace la logique historiquement éclatée entre
/// `TransactionRepository` (colonne `reimbursement_payee_id`, retirée v44) et
/// `TricountRepository` (table `tricount_reimbursements`, migrée v44).
struct ReimbursementRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    // MARK: - Transaction simple (0..1, pas de montant — cf. doctrine v44)

    /// Assigne (ou retire si `payeeId == nil`) le payee remboursant d'une
    /// transaction. Upsert sur `idx_reimbursements_transaction` : changer de
    /// payee met à jour la ligne existante, ne crée jamais de doublon.
    @discardableResult
    func setReimbursement(transactionId: Int, payeeId: Int?) -> Bool {
        guard let payeeId else {
            return writeSingle(sql: "DELETE FROM reimbursements WHERE transaction_id = ?;") { stmt in
                sqlite3_bind_int(stmt, 1, Int32(transactionId))
            }
        }
        return writeSingle(sql: """
            INSERT INTO reimbursements (transaction_id, payee_id) VALUES (?, ?)
            ON CONFLICT(transaction_id) WHERE transaction_id IS NOT NULL
            DO UPDATE SET payee_id = excluded.payee_id;
            """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            sqlite3_bind_int(stmt, 2, Int32(payeeId))
        }
    }

    func fetchReimbursement(forTransaction transactionId: Int) -> Reimbursement? {
        let rows: [Reimbursement] = query(read: { db in
            let sql = """
            SELECT r.id, r.payee_id, COALESCE(p.name, ''), r.status, COALESCE(r.updated_at, ''),
                   t.amount, COALESCE(t.information, ''), COALESCE(t.tx_date, '')
            FROM reimbursements r
            JOIN payees p ON p.id = r.payee_id
            JOIN transactions t ON t.id = r.transaction_id
            WHERE r.transaction_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }

            let amount = sqlite3_column_double(stmt, 5)
            return [Reimbursement(
                id: Int(sqlite3_column_int(stmt, 0)),
                transactionId: transactionId,
                tricountEntryId: nil,
                payeeId: Int(sqlite3_column_int(stmt, 1)),
                payeeName: string(from: stmt, index: 2),
                status: ReimbursementStatus(rawValue: string(from: stmt, index: 3)) ?? .pending,
                updatedAt: parseUpdatedAt(string(from: stmt, index: 4)),
                amount: amount,
                currency: "EUR",
                eurAmount: amount,
                originDescription: string(from: stmt, index: 6),
                originDate: parseDate(string(from: stmt, index: 7))
            )]
        }) ?? []
        return rows.first
    }

    // MARK: - Tricount (0..N, montant obligatoire = part personnelle)

    /// Premier assignement (ou ajustement du montant) d'un remboursement pour
    /// un couple (entrée, payee). Upsert sur `idx_reimbursements_tricount`.
    @discardableResult
    func addOrUpdateReimbursement(tricountEntryId: Int, payeeId: Int, amount: Double, currency: String) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO reimbursements (tricount_entry_id, payee_id, amount, currency) VALUES (?, ?, ?, ?)
            ON CONFLICT(tricount_entry_id, payee_id) WHERE tricount_entry_id IS NOT NULL
            DO UPDATE SET amount = excluded.amount, currency = excluded.currency;
            """, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(tricountEntryId))
        sqlite3_bind_int(stmt, 2, Int32(payeeId))
        sqlite3_bind_double(stmt, 3, amount)
        sqlite3_bind_text(stmt, 4, currency, -1, SQLITE_TRANSIENT_RB)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Édition d'une ligne EXISTANTE par son id — au contraire de
    /// `addOrUpdateReimbursement` (keyé sur le couple entrée/payee), celle-ci
    /// met à jour la ligne identifiée même si le payee change, pour ne
    /// jamais dupliquer silencieusement (fix du bug "Modifier…").
    @discardableResult
    func updateReimbursement(id: Int, payeeId: Int, amount: Double, currency: String) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE reimbursements SET payee_id = ?, amount = ?, currency = ? WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(payeeId))
        sqlite3_bind_double(stmt, 2, amount)
        sqlite3_bind_text(stmt, 3, currency, -1, SQLITE_TRANSIENT_RB)
        sqlite3_bind_int(stmt, 4, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func deleteReimbursement(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM reimbursements WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    func fetchReimbursements(forTricountEntry entryId: Int) -> [Reimbursement] {
        query(read: { db in
            let sql = """
            SELECT r.id, r.payee_id, COALESCE(p.name, ''), r.status, COALESCE(r.updated_at, ''),
                   CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END,
                   r.currency,
                   CASE
                       WHEN r.currency = 'EUR' OR r.currency = '' THEN
                           CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END
                       WHEN e.local_currency = 'EUR' AND e.local_total IS NOT NULL AND e.total != 0 THEN
                           (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * (ABS(e.local_total) / ABS(e.total))
                       WHEN cr.rate IS NOT NULL THEN
                           (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * cr.rate
                       ELSE NULL
                   END,
                   COALESCE(e.description, ''), COALESCE(e.date, '')
            FROM reimbursements r
            JOIN payees p ON p.id = r.payee_id
            JOIN tricount_entries e ON e.id = r.tricount_entry_id
            LEFT JOIN currency_rates cr ON cr.from_currency = r.currency AND cr.to_currency = 'EUR' AND cr.date = e.date
            WHERE r.tricount_entry_id = ?
            ORDER BY e.date DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(entryId))
            var out: [Reimbursement] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(reimbursementFromTricountRow(stmt, tricountEntryId: entryId))
            }
            return out
        }) ?? []
    }

    /// Remboursements d'un groupe Tricount spécifique, groupés par payee.
    func fetchReimbursements(forTricountGroup groupId: Int) -> [ReimbursementGroup] {
        query(read: { db in
            let sql = tricountGroupSQL(where: "e.group_id = ?")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(groupId))
            return groupedRows(stmt)
        }) ?? []
    }

    // MARK: - Vue unifiée (transactions simples + Tricount)

    /// Remplace TransactionRepository.fetchReimbursementGroups ET
    /// TricountRepository.fetchReimbursementGroups — une seule requête au lieu
    /// d'un merge applicatif de 2 sources (ex-ReimbursementsSheet.load()).
    func fetchReimbursementGroups(from: Date, to: Date) -> [ReimbursementGroup] {
        var grouped: [Int: (name: String, items: [Reimbursement])] = [:]
        for item in fetchReimbursementRows(from: from, to: to) {
            grouped[item.payeeId, default: (item.payeeName, [])].items.append(item)
        }
        return grouped.map { id, pair in
            ReimbursementGroup(payeeId: id, payeeName: pair.name, items: pair.items)
        }.sorted { $0.payeeName.localizedCaseInsensitiveCompare($1.payeeName) == .orderedAscending }
    }

    /// Liste plate des remboursements (transaction + Tricount confondus) sur
    /// une période, avec catégorie résolue (utilisée pour le sous-détail par
    /// catégorie au sein d'un payee, calculé côté vue — cf. ReimbursementsSheet).
    private func fetchReimbursementRows(from: Date, to: Date) -> [Reimbursement] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to))
        let toRaw   = fmt.string(from: max(from, to))

        return query(read: { db in
            let sql = """
            SELECT r.id, r.transaction_id, r.tricount_entry_id, r.payee_id, COALESCE(p.name, ''),
                   r.status, COALESCE(r.updated_at, ''),
                   CASE
                       WHEN r.transaction_id IS NOT NULL THEN t.amount
                       WHEN e.type_transaction = 'NORMAL' THEN -r.amount
                       ELSE r.amount
                   END,
                   CASE WHEN r.transaction_id IS NOT NULL THEN 'EUR' ELSE r.currency END,
                   CASE
                       WHEN r.transaction_id IS NOT NULL THEN t.amount
                       WHEN r.currency = 'EUR' OR r.currency = '' THEN
                           CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END
                       WHEN e.local_currency = 'EUR' AND e.local_total IS NOT NULL AND e.total != 0 THEN
                           (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * (ABS(e.local_total) / ABS(e.total))
                       WHEN cr.rate IS NOT NULL THEN
                           (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * cr.rate
                       ELSE NULL
                   END,
                   COALESCE(t.information, e.description, ''),
                   COALESCE(t.tx_date, e.date, ''),
                   COALESCE(t.category_id, e.user_category_id),
                   COALESCE(c.name, ''),
                   COALESCE(ti.name, '')
            FROM reimbursements r
            JOIN payees p ON p.id = r.payee_id
            LEFT JOIN transactions t ON t.id = r.transaction_id
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN tricount_entries e ON e.id = r.tricount_entry_id
            LEFT JOIN categories c ON c.id = COALESCE(t.category_id, e.user_category_id)
            LEFT JOIN currency_rates cr ON cr.from_currency = r.currency AND cr.to_currency = 'EUR' AND cr.date = e.date
            WHERE COALESCE(t.tx_date, e.date) >= ? AND COALESCE(t.tx_date, e.date) <= ?
            ORDER BY COALESCE(t.tx_date, e.date) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, fromRaw, -1, SQLITE_TRANSIENT_RB)
            sqlite3_bind_text(stmt, 2, toRaw, -1, SQLITE_TRANSIENT_RB)

            var out: [Reimbursement] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func optInt(_ col: Int32) -> Int? {
                    sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
                }
                let eurAmount: Double? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9)
                out.append(Reimbursement(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    transactionId: optInt(1),
                    tricountEntryId: optInt(2),
                    payeeId: Int(sqlite3_column_int(stmt, 3)),
                    payeeName: string(from: stmt, index: 4),
                    status: ReimbursementStatus(rawValue: string(from: stmt, index: 5)) ?? .pending,
                    updatedAt: parseUpdatedAt(string(from: stmt, index: 6)),
                    amount: sqlite3_column_double(stmt, 7),
                    currency: string(from: stmt, index: 8),
                    eurAmount: eurAmount,
                    originDescription: string(from: stmt, index: 10),
                    originDate: parseDate(string(from: stmt, index: 11)),
                    categoryId: optInt(12),
                    categoryName: string(from: stmt, index: 13),
                    originPayeeName: string(from: stmt, index: 14)
                ))
            }
            return out
        }) ?? []
    }

    // MARK: - Statut

    @discardableResult
    func markReceived(id: Int) -> Bool {
        writeSingle(sql: "UPDATE reimbursements SET status = 'RECEIVED' WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    @discardableResult
    func markPending(id: Int) -> Bool {
        writeSingle(sql: "UPDATE reimbursements SET status = 'PENDING' WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    // MARK: - Cascade suppression payee

    /// Remplace les 2 statements séparés de l'ancien
    /// TransactionRepository.deleteTiers (NULL sur reimbursement_payee_id +
    /// DELETE tricount_reimbursements) par UN SEUL — bénéfice direct de
    /// l'unification.
    @discardableResult
    func deleteReimbursements(payeeId: Int) -> Bool {
        writeSingle(sql: "DELETE FROM reimbursements WHERE payee_id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(payeeId))
        }
    }

    // MARK: - Helpers privés

    private func tricountGroupSQL(where condition: String) -> String {
        """
        SELECT r.id, r.payee_id, COALESCE(p.name, ''), r.status, COALESCE(r.updated_at, ''),
               CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END,
               r.currency,
               CASE
                   WHEN r.currency = 'EUR' OR r.currency = '' THEN
                       CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END
                   WHEN e.local_currency = 'EUR' AND e.local_total IS NOT NULL AND e.total != 0 THEN
                       (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * (ABS(e.local_total) / ABS(e.total))
                   WHEN cr.rate IS NOT NULL THEN
                       (CASE WHEN e.type_transaction = 'NORMAL' THEN -r.amount ELSE r.amount END) * cr.rate
                   ELSE NULL
               END,
               COALESCE(e.description, ''), COALESCE(e.date, ''), r.tricount_entry_id
        FROM reimbursements r
        JOIN payees p ON p.id = r.payee_id
        JOIN tricount_entries e ON e.id = r.tricount_entry_id
        LEFT JOIN currency_rates cr ON cr.from_currency = r.currency AND cr.to_currency = 'EUR' AND cr.date = e.date
        WHERE \(condition)
        ORDER BY p.name COLLATE NOCASE, e.date DESC;
        """
    }

    private func groupedRows(_ stmt: OpaquePointer) -> [ReimbursementGroup] {
        var grouped: [Int: (name: String, items: [Reimbursement])] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let payeeId = Int(sqlite3_column_int(stmt, 1))
            let payeeName = string(from: stmt, index: 2)
            let eurAmount: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
            let item = Reimbursement(
                id: Int(sqlite3_column_int(stmt, 0)),
                transactionId: nil,
                tricountEntryId: Int(sqlite3_column_int(stmt, 10)),
                payeeId: payeeId,
                payeeName: payeeName,
                status: ReimbursementStatus(rawValue: string(from: stmt, index: 3)) ?? .pending,
                updatedAt: parseUpdatedAt(string(from: stmt, index: 4)),
                amount: sqlite3_column_double(stmt, 5),
                currency: string(from: stmt, index: 6),
                eurAmount: eurAmount,
                originDescription: string(from: stmt, index: 8),
                originDate: parseDate(string(from: stmt, index: 9))
            )
            grouped[payeeId, default: (payeeName, [])].items.append(item)
        }
        return grouped.map { id, pair in
            ReimbursementGroup(payeeId: id, payeeName: pair.name, items: pair.items)
        }.sorted { $0.payeeName.localizedCaseInsensitiveCompare($1.payeeName) == .orderedAscending }
    }

    private func reimbursementFromTricountRow(_ stmt: OpaquePointer, tricountEntryId: Int) -> Reimbursement {
        let eurAmount: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
        return Reimbursement(
            id: Int(sqlite3_column_int(stmt, 0)),
            transactionId: nil,
            tricountEntryId: tricountEntryId,
            payeeId: Int(sqlite3_column_int(stmt, 1)),
            payeeName: string(from: stmt, index: 2),
            status: ReimbursementStatus(rawValue: string(from: stmt, index: 3)) ?? .pending,
            updatedAt: parseUpdatedAt(string(from: stmt, index: 4)),
            amount: sqlite3_column_double(stmt, 5),
            currency: string(from: stmt, index: 6),
            eurAmount: eurAmount,
            originDescription: string(from: stmt, index: 8),
            originDate: parseDate(string(from: stmt, index: 9))
        )
    }

    private func parseDate(_ raw: String) -> Date {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: raw) ?? Date()
    }

    private func parseUpdatedAt(_ raw: String) -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? Date()
    }

    private func query<T>(read block: (OpaquePointer) -> T) -> T? { store.read(block) }

    @discardableResult
    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        store.writeSingle(sql: sql, bind: bind)
    }

}
