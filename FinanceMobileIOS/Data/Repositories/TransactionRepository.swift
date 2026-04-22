import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TransactionRepository {
    func fetchAccounts() -> [Account] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, '') FROM comptes ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [Account] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Account(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1)))
            }
            return items
        }) ?? []
    }

    func fetchTransactions(accountId: Int, from: Date, to: Date, limit: Int = 100, offset: Int = 0) -> [FinanceTransaction] {
        let normalizedFrom = min(from, to)
        let normalizedTo = max(from, to)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fromRaw = formatter.string(from: normalizedFrom)
        let toRaw = formatter.string(from: normalizedTo)

        return query(read: { db in
            let sql = """
            SELECT
                t.id,
                t.comptes_id,
                COALESCE(ti.name, ''),
                COALESCE(c.name, ''),
                COALESCE(m.name, ''),
                COALESCE(t.information, ''),
                t.montant,
                COALESCE(t.date_op, ''),
                t.tiers_id,
                t.categorie_id,
                t.mdp_id
            FROM transactions t
            LEFT JOIN tiers ti ON ti.id = t.tiers_id
            LEFT JOIN category c ON c.id = t.categorie_id
            LEFT JOIN mdp m ON m.id = t.mdp_id
            WHERE t.comptes_id = ?
              AND t.date_op >= ?
              AND t.date_op <= ?
            ORDER BY t.date_op DESC, t.id DESC
            LIMIT ? OFFSET ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(accountId))
            sqlite3_bind_text(stmt, 2, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, toRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(limit))
            sqlite3_bind_int(stmt, 5, Int32(offset))

            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }

            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let accId = Int(sqlite3_column_int(stmt, 1))
                let tiersName = string(from: stmt, index: 2)
                let categoryName = string(from: stmt, index: 3)
                let paymentTypeName = string(from: stmt, index: 4)
                let information = string(from: stmt, index: 5)
                let amount = sqlite3_column_double(stmt, 6)
                let dateRaw = string(from: stmt, index: 7)
                let date = formatter.date(from: dateRaw) ?? Date()

                results.append(
                    FinanceTransaction(
                        id: id,
                        accountId: accId,
                        tiersId: optInt(8),
                        categoryId: optInt(9),
                        paymentTypeId: optInt(10),
                        tiersName: tiersName,
                        categoryName: categoryName,
                        paymentTypeName: paymentTypeName,
                        information: information,
                        amount: amount,
                        date: date
                    )
                )
            }

            return results
        }) ?? []
    }

    func fetchCategories() -> [Category] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, '') FROM category ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [Category] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Category(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1)))
            }
            return items
        }) ?? []
    }

    func fetchTiers() -> [Tiers] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, ''), COALESCE(cm_name, '') FROM tiers ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [Tiers] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let regex = string(from: stmt, index: 2)
                items.append(
                    Tiers(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        name: string(from: stmt, index: 1),
                        regex: regex.isEmpty ? nil : regex
                    )
                )
            }
            return items
        }) ?? []
    }

    func fetchPaymentTypes() -> [PaymentType] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, ''), COALESCE(cm_name, '') FROM mdp ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [PaymentType] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let regex = string(from: stmt, index: 2)
                items.append(
                    PaymentType(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        name: string(from: stmt, index: 1),
                        regex: regex.isEmpty ? nil : regex
                    )
                )
            }
            return items
        }) ?? []
    }

    @discardableResult
    func insertTransactions(_ transactions: [PendingTransaction]) -> Int {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return 0 }

        var db: OpaquePointer?
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let sql = """
        INSERT INTO transactions (comptes_id, tiers_id, mdp_id, information, montant, date_op)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var inserted = 0
        for tx in transactions {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(tx.accountId))
            if let tiersId = tx.tiersId { sqlite3_bind_int(stmt, 2, Int32(tiersId)) }
            else { sqlite3_bind_null(stmt, 2) }
            if let mdpId = tx.mdpId { sqlite3_bind_int(stmt, 3, Int32(mdpId)) }
            else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_text(stmt, 4, tx.information, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, tx.amount)
            sqlite3_bind_text(stmt, 6, formatter.string(from: tx.date), -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_DONE { inserted += 1 }
        }
        return inserted
    }

    // MARK: - Transaction CRUD

    @discardableResult
    func deleteTransaction(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM transactions WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    func deleteTransactions(ids: Set<Int>) -> Int {
        ids.reduce(0) { deleteTransaction(id: $1) ? $0 + 1 : $0 }
    }

    @discardableResult
    func updateTransaction(_ draft: TransactionEditDraft) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: draft.date)
        return writeSingle(sql: """
            UPDATE transactions
            SET tiers_id = ?, categorie_id = ?, mdp_id = ?, information = ?, montant = ?, date_op = ?
            WHERE id = ?
            """) { stmt in
            if let v = draft.tiersId { sqlite3_bind_int(stmt, 1, Int32(v)) } else { sqlite3_bind_null(stmt, 1) }
            if let v = draft.categoryId { sqlite3_bind_int(stmt, 2, Int32(v)) } else { sqlite3_bind_null(stmt, 2) }
            if let v = draft.paymentTypeId { sqlite3_bind_int(stmt, 3, Int32(v)) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_text(stmt, 4, draft.information, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, draft.amount)
            sqlite3_bind_text(stmt, 6, dateStr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, Int32(draft.id))
        }
    }

    /// Insère un nouveau tiers et retourne son ID généré.
    func addTiersAndGetId(name: String, regex: String) -> Int? {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return nil }
        var db: OpaquePointer?
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO tiers (name, cm_name) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    // MARK: - Reference Data CRUD

    @discardableResult
    func updateAccount(id: Int, name: String) -> Bool {
        writeSingle(sql: "UPDATE comptes SET name = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    @discardableResult
    func addAccount(name: String) -> Bool {
        writeSingle(sql: "INSERT INTO comptes (name) VALUES (?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        }
    }

    @discardableResult
    func updateCategory(id: Int, name: String) -> Bool {
        writeSingle(sql: "UPDATE category SET name = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    @discardableResult
    func addCategory(name: String) -> Bool {
        writeSingle(sql: "INSERT INTO category (name) VALUES (?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        }
    }

    @discardableResult
    func updateTiers(id: Int, name: String, regex: String) -> Bool {
        writeSingle(sql: "UPDATE tiers SET name = ?, cm_name = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(id))
        }
    }

    @discardableResult
    func addTiers(name: String, regex: String) -> Bool {
        writeSingle(sql: "INSERT INTO tiers (name, cm_name) VALUES (?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        }
    }

    @discardableResult
    func updatePaymentType(id: Int, name: String, regex: String) -> Bool {
        writeSingle(sql: "UPDATE mdp SET name = ?, cm_name = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(id))
        }
    }

    @discardableResult
    func addPaymentType(name: String, regex: String) -> Bool {
        writeSingle(sql: "INSERT INTO mdp (name, cm_name) VALUES (?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        }
    }

    // MARK: - Mise à jour rapide catégorie

    @discardableResult
    func updateTransactionCategory(id: Int, categoryId: Int?) -> Bool {
        writeSingle(sql: "UPDATE transactions SET categorie_id = ? WHERE id = ?") { stmt in
            if let cid = categoryId { sqlite3_bind_int(stmt, 1, Int32(cid)) }
            else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    // MARK: - Données pour graphiques

    func fetchMonthlyTotals(accountId: Int, from: Date, to: Date) -> [MonthlyTotals] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to)); let toRaw = fmt.string(from: max(from, to))
        return query(read: { db in
            let sql = """
            SELECT strftime('%Y-%m', date_op) AS mois,
                   SUM(CASE WHEN montant > 0 THEN montant ELSE 0 END),
                   SUM(CASE WHEN montant < 0 THEN montant ELSE 0 END)
            FROM transactions
            WHERE comptes_id = ? AND date_op >= ? AND date_op <= ?
            GROUP BY mois ORDER BY mois ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(accountId))
            sqlite3_bind_text(stmt, 2, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, toRaw, -1, SQLITE_TRANSIENT)
            var results: [MonthlyTotals] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(MonthlyTotals(
                    month: string(from: stmt, index: 0),
                    income: sqlite3_column_double(stmt, 1),
                    expense: sqlite3_column_double(stmt, 2)
                ))
            }
            return results
        }) ?? []
    }

    func fetchCategoryTotals(accountId: Int, from: Date, to: Date) -> [CategoryTotal] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to)); let toRaw = fmt.string(from: max(from, to))
        return query(read: { db in
            let sql = """
            SELECT COALESCE(c.name, 'Non catégorisé') as name, SUM(t.montant) as total
            FROM transactions t
            LEFT JOIN category c ON c.id = t.categorie_id
            WHERE t.comptes_id = ? AND t.date_op >= ? AND t.date_op <= ?
            GROUP BY t.categorie_id
            ORDER BY ABS(SUM(t.montant)) DESC LIMIT 10;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(accountId))
            sqlite3_bind_text(stmt, 2, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, toRaw, -1, SQLITE_TRANSIENT)
            var results: [CategoryTotal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(CategoryTotal(category: string(from: stmt, index: 0), total: sqlite3_column_double(stmt, 1)))
            }
            return results
        }) ?? []
    }

    // MARK: - Console SQL

    func executeSQL(_ sql: String) -> Result<SQLQueryResult, SQLError> {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return .failure(SQLError(message: "Aucune base de données disponible")) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return .failure(SQLError(message: "Impossible d'ouvrir la base de données"))
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(SQLError(message: "Erreur SQL : \(String(cString: sqlite3_errmsg(db)))"))
        }
        defer { sqlite3_finalize(stmt) }
        let colCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<colCount).map { i in
            sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
        }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW && rows.count < 2000 {
            let row = (0..<colCount).map { i -> String in
                switch sqlite3_column_type(stmt, Int32(i)) {
                case SQLITE_INTEGER: return String(sqlite3_column_int64(stmt, Int32(i)))
                case SQLITE_FLOAT:   return String(sqlite3_column_double(stmt, Int32(i)))
                case SQLITE_TEXT:    return String(cString: sqlite3_column_text(stmt, Int32(i)))
                case SQLITE_NULL:    return "NULL"
                default:             return "BLOB"
                }
            }
            rows.append(row)
        }
        return .success(SQLQueryResult(columns: columns, rows: rows))
    }

    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return false }
        var db: OpaquePointer?
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func query<T>(read block: (OpaquePointer) -> T) -> T? {
        guard DatabaseManager.shared.hasDatabaseCopy() else {
            return nil
        }

        var db: OpaquePointer?
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        return block(db)
    }

    private func string(from statement: OpaquePointer?, index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: cString)
    }
}
