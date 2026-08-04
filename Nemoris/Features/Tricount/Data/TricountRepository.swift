import Foundation
import SQLite3

private let SQLITE_TRANSIENT_TC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TricountRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    nonisolated(unsafe) private(set) static var lastSaveError: String? = nil

    // MARK: - Table Setup

    /// Schema is now managed centrally by DatabaseManager.migrateIfNeeded().
    /// This stub exists so call sites in views don't need to change.
    func setupTables() {
        DatabaseManager.shared.migrateIfNeeded()
    }

    // MARK: - Groups

    func fetchGroups() -> [TricountGroup] {
        guard store.databaseExists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let sql = """
        SELECT g.id, g.tricount_key, g.title, g.currency, g.my_name, g.fetched_at,
               COUNT(DISTINCT e.id)
        FROM tricount_groups g
        LEFT JOIN tricount_entries e ON e.group_id = g.id
        GROUP BY g.id ORDER BY g.fetched_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        var groups: [TricountGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            groups.append(TricountGroup(
                id: Int(sqlite3_column_int(stmt, 0)),
                tricountKey: str(stmt, 1),
                title: str(stmt, 2),
                currency: str(stmt, 3),
                myName: str(stmt, 4),
                fetchedAt: iso.date(from: str(stmt, 5)) ?? Date(),
                entryCount: Int(sqlite3_column_int(stmt, 6))
            ))
        }
        return groups
    }

    /// Saves (or updates) a group and syncs entries by source UUID atomically.
    /// Existing entries are updated, missing ones are inserted, and stale ones are deleted.
    @discardableResult
    func saveGroup(key: String, title: String, currency: String, myName: String,
                   entries: [ParsedTCEntry]) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        // Upsert group by tricount key to keep a stable local group id.
        let fetchedAt = ISO8601DateFormatter().string(from: Date())
        var gid: Int?
        do {
            var findStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id FROM tricount_groups WHERE tricount_key = ? LIMIT 1", -1, &findStmt, nil) == SQLITE_OK, let findStmt else {
                rollbackAndCapture(db: db)
                return nil
            }
            defer { sqlite3_finalize(findStmt) }
            sqlite3_bind_text(findStmt, 1, key, -1, SQLITE_TRANSIENT_TC)

            if sqlite3_step(findStmt) == SQLITE_ROW {
                let existingId = Int(sqlite3_column_int(findStmt, 0))
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "UPDATE tricount_groups SET title = ?, currency = ?, my_name = ?, fetched_at = ? WHERE id = ?", -1, &updateStmt, nil) == SQLITE_OK, let updateStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_text(updateStmt, 1, title, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 2, currency, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 3, myName, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 4, fetchedAt, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_int(updateStmt, 5, Int32(existingId))
                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                gid = existingId
            } else {
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO tricount_groups (tricount_key, title, currency, my_name, fetched_at) VALUES (?, ?, ?, ?, ?)", -1, &insertStmt, nil) == SQLITE_OK, let insertStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_text(insertStmt, 1, key, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 2, title, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 3, currency, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 4, myName, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 5, fetchedAt, -1, SQLITE_TRANSIENT_TC)
                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                gid = Int(sqlite3_last_insert_rowid(db))
            }
        }

        guard let gid else {
            rollbackAndCapture(db: db)
            return nil
        }

        let selectEntrySQL = "SELECT id FROM tricount_entries WHERE group_id = ? AND source_entry_uuid = ? LIMIT 1"
        let insertEntrySQL = "INSERT INTO tricount_entries (group_id, source_entry_uuid, source_updated_at, type_transaction, who_paid, total, currency, local_total, local_currency, description, date, category) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        let updateEntrySQL = "UPDATE tricount_entries SET source_entry_uuid = ?, source_updated_at = ?, type_transaction = ?, who_paid = ?, total = ?, currency = ?, local_total = ?, local_currency = ?, description = ?, date = ?, category = ? WHERE id = ?"
        let deleteSharesSQL = "DELETE FROM tricount_shares WHERE entry_id = ?"
        let shareSQL = "INSERT INTO tricount_shares (entry_id, member_name, amount) VALUES (?, ?, ?)"
        var seenEntryIds: [Int] = []

        for entry in entries {
            var currentEntryId: Int?

            if !entry.sourceUUID.isEmpty {
                var selectStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, selectEntrySQL, -1, &selectStmt, nil) == SQLITE_OK, let selectStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(selectStmt) }
                sqlite3_bind_int(selectStmt, 1, Int32(gid))
                sqlite3_bind_text(selectStmt, 2, entry.sourceUUID, -1, SQLITE_TRANSIENT_TC)
                if sqlite3_step(selectStmt) == SQLITE_ROW {
                    currentEntryId = Int(sqlite3_column_int(selectStmt, 0))
                }
            }

            if let existingEntryId = currentEntryId {
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateEntrySQL, -1, &updateStmt, nil) == SQLITE_OK, let updateStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_text(updateStmt, 1, entry.sourceUUID, -1, SQLITE_TRANSIENT_TC)
                bindOptionalText(updateStmt, index: 2, value: entry.sourceUpdatedAt)
                sqlite3_bind_text(updateStmt, 3, entry.typeTransaction, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 4, entry.whoPaid, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_double(updateStmt, 5, entry.total)
                sqlite3_bind_text(updateStmt, 6, entry.currency, -1, SQLITE_TRANSIENT_TC)
                if let localTotal = entry.localTotal {
                    sqlite3_bind_double(updateStmt, 7, localTotal)
                } else {
                    sqlite3_bind_null(updateStmt, 7)
                }
                bindOptionalText(updateStmt, index: 8, value: entry.localCurrency)
                sqlite3_bind_text(updateStmt, 9, entry.description, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 10, entry.date, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(updateStmt, 11, entry.category, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_int(updateStmt, 12, Int32(existingEntryId))
                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                currentEntryId = existingEntryId
            } else {
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertEntrySQL, -1, &insertStmt, nil) == SQLITE_OK, let insertStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_int(insertStmt, 1, Int32(gid))
                bindOptionalText(insertStmt, index: 2, value: entry.sourceUUID.isEmpty ? nil : entry.sourceUUID)
                bindOptionalText(insertStmt, index: 3, value: entry.sourceUpdatedAt)
                sqlite3_bind_text(insertStmt, 4, entry.typeTransaction, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 5, entry.whoPaid, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_double(insertStmt, 6, entry.total)
                sqlite3_bind_text(insertStmt, 7, entry.currency, -1, SQLITE_TRANSIENT_TC)
                if let localTotal = entry.localTotal {
                    sqlite3_bind_double(insertStmt, 8, localTotal)
                } else {
                    sqlite3_bind_null(insertStmt, 8)
                }
                bindOptionalText(insertStmt, index: 9, value: entry.localCurrency)
                sqlite3_bind_text(insertStmt, 10, entry.description, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 11, entry.date, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_text(insertStmt, 12, entry.category, -1, SQLITE_TRANSIENT_TC)
                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                currentEntryId = Int(sqlite3_last_insert_rowid(db))
            }

            guard let entryId = currentEntryId else {
                rollbackAndCapture(db: db)
                return nil
            }
            seenEntryIds.append(entryId)

            exec(db, deleteSharesSQL) { sqlite3_bind_int($0, 1, Int32(entryId)) }

            for (member, amount) in entry.shares {
                var sStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, shareSQL, -1, &sStmt, nil) == SQLITE_OK, let sStmt else {
                    rollbackAndCapture(db: db)
                    return nil
                }
                defer { sqlite3_finalize(sStmt) }
                sqlite3_bind_int(sStmt, 1, Int32(entryId))
                sqlite3_bind_text(sStmt, 2, member, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_double(sStmt, 3, amount)
                guard sqlite3_step(sStmt) == SQLITE_DONE else {
                    rollbackAndCapture(db: db)
                    return nil
                }
            }
        }

        // Remove entries that no longer exist in the latest payload (user-filtered).
        // Child records (shares, reimbursements) must be deleted first to avoid FK violations
        // that would otherwise cause the entire transaction to rollback silently.
        if seenEntryIds.isEmpty {
            exec(db, "DELETE FROM reimbursements WHERE tricount_entry_id IN (SELECT id FROM tricount_entries WHERE group_id = ?)") {
                sqlite3_bind_int($0, 1, Int32(gid))
            }
            exec(db, "DELETE FROM tricount_shares WHERE entry_id IN (SELECT id FROM tricount_entries WHERE group_id = ?)") {
                sqlite3_bind_int($0, 1, Int32(gid))
            }
            exec(db, "DELETE FROM tricount_entries WHERE group_id = ?") { sqlite3_bind_int($0, 1, Int32(gid)) }
        } else {
            let placeholders = Array(repeating: "?", count: seenEntryIds.count).joined(separator: ",")
            let staleSubquery = "SELECT id FROM tricount_entries WHERE group_id = ? AND id NOT IN (\(placeholders))"

            // 1. Delete reimbursements for stale entries
            let reimbSQL = "DELETE FROM reimbursements WHERE tricount_entry_id IN (\(staleSubquery))"
            var reimbStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, reimbSQL, -1, &reimbStmt, nil) == SQLITE_OK, let reimbStmt {
                defer { sqlite3_finalize(reimbStmt) }
                sqlite3_bind_int(reimbStmt, 1, Int32(gid))
                for (i, eid) in seenEntryIds.enumerated() { sqlite3_bind_int(reimbStmt, Int32(i + 2), Int32(eid)) }
                sqlite3_step(reimbStmt)
            }

            // 2. Delete shares for stale entries
            let sharesSQL = "DELETE FROM tricount_shares WHERE entry_id IN (\(staleSubquery))"
            var sharesStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sharesSQL, -1, &sharesStmt, nil) == SQLITE_OK, let sharesStmt {
                defer { sqlite3_finalize(sharesStmt) }
                sqlite3_bind_int(sharesStmt, 1, Int32(gid))
                for (i, eid) in seenEntryIds.enumerated() { sqlite3_bind_int(sharesStmt, Int32(i + 2), Int32(eid)) }
                sqlite3_step(sharesStmt)
            }

            // 3. Delete stale entries
            let deleteStaleSQL = "DELETE FROM tricount_entries WHERE group_id = ? AND id NOT IN (\(placeholders))"
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteStaleSQL, -1, &deleteStmt, nil) == SQLITE_OK, let deleteStmt else {
                rollbackAndCapture(db: db)
                return nil
            }
            defer { sqlite3_finalize(deleteStmt) }
            sqlite3_bind_int(deleteStmt, 1, Int32(gid))
            for (index, entryId) in seenEntryIds.enumerated() {
                sqlite3_bind_int(deleteStmt, Int32(index + 2), Int32(entryId))
            }
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                rollbackAndCapture(db: db)
                return nil
            }
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return gid
    }

    /// Charge un groupe par son ID local (utile pour la navigation depuis une transaction liée).
    func fetchGroup(id: Int) -> TricountGroup? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
        SELECT g.id, g.tricount_key, g.title, g.currency, g.my_name, g.fetched_at,
               COUNT(DISTINCT e.id)
        FROM tricount_groups g
        LEFT JOIN tricount_entries e ON e.group_id = g.id
        WHERE g.id = ?
        GROUP BY g.id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(id))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let iso = ISO8601DateFormatter()
        return TricountGroup(
            id: Int(sqlite3_column_int(stmt, 0)),
            tricountKey: str(stmt, 1),
            title: str(stmt, 2),
            currency: str(stmt, 3),
            myName: str(stmt, 4),
            fetchedAt: iso.date(from: str(stmt, 5)) ?? Date(),
            entryCount: Int(sqlite3_column_int(stmt, 6))
        )
    }

    func deleteGroup(id: Int) {
        guard store.databaseExists else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        exec(db, "DELETE FROM tricount_groups WHERE id = ?") { sqlite3_bind_int($0, 1, Int32(id)) }
    }

    // MARK: - Entries + Shares

    func fetchEntries(groupId: Int) -> [TricountEntry] {
        guard store.databaseExists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

         let sql = """
         SELECT e.id, e.group_id, e.source_entry_uuid, e.source_updated_at,
             e.type_transaction, e.who_paid, e.total, e.currency,
             e.local_total, e.local_currency, e.description, e.date, e.category,
             e.user_category_id, COALESCE(c.name, ''), e.linked_transaction_id
        FROM tricount_entries e
        LEFT JOIN categories c ON c.id = e.user_category_id
        WHERE e.group_id = ? ORDER BY e.date DESC, e.id DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(groupId))

        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        var entries: [TricountEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sourceUUID: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : str(stmt, 2)
            let sourceUpdatedAt: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : str(stmt, 3)
            let localTotal: Double? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
            let localCurrency: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : str(stmt, 9)
            let catId: Int? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 13))
            let linkedTxId: Int? = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 15))
            entries.append(TricountEntry(
                id: Int(sqlite3_column_int(stmt, 0)),
                groupId: Int(sqlite3_column_int(stmt, 1)),
                sourceUUID: sourceUUID,
                sourceUpdatedAt: sourceUpdatedAt,
                typeTransaction: str(stmt, 4),
                whoPaid: str(stmt, 5),
                total: sqlite3_column_double(stmt, 6),
                currency: str(stmt, 7),
                localTotal: localTotal,
                localCurrency: localCurrency,
                description: str(stmt, 10),
                date: fmt.date(from: str(stmt, 11)) ?? Date(),
                category: str(stmt, 12),
                userCategoryId: catId,
                userCategoryName: str(stmt, 14),
                linkedTransactionId: linkedTxId
            ))
        }
        return entries
    }

    @discardableResult
    func updateEntryCategory(entryId: Int, categoryId: Int?) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tricount_entries SET user_category_id = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        if let cid = categoryId { sqlite3_bind_int(stmt, 1, Int32(cid)) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int(stmt, 2, Int32(entryId))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func fetchShares(groupId: Int) -> [TricountShare] {
        guard store.databaseExists else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let sql = """
        SELECT s.id, s.entry_id, s.member_name, s.amount
        FROM tricount_shares s
        JOIN tricount_entries e ON e.id = s.entry_id
        WHERE e.group_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(groupId))

        var shares: [TricountShare] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            shares.append(TricountShare(
                id: Int(sqlite3_column_int(stmt, 0)),
                entryId: Int(sqlite3_column_int(stmt, 1)),
                memberName: str(stmt, 2),
                amount: sqlite3_column_double(stmt, 3)
            ))
        }
        return shares
    }

    // MARK: - Linked Transaction

    @discardableResult
    func updateLinkedTransaction(entryId: Int, transactionId: Int?) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tricount_entries SET linked_transaction_id = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        if let tid = transactionId { sqlite3_bind_int(stmt, 1, Int32(tid)) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int(stmt, 2, Int32(entryId))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Balance Computation

    func computeBalances(entries: [TricountEntry], shares: [TricountShare], myName: String) -> [TricountMemberBalance] {
        let sharesByEntry = Dictionary(grouping: shares, by: { $0.entryId })

        // Compute net group debt for every member across the full group.
        // groupDebt[M] > 0 → M owes the group (net debtor)
        // groupDebt[M] < 0 → group owes M (net creditor)
        // This mirrors Tricount's own balance logic, so cross-party settlements
        // (e.g. Nathan → Périé → Elisa → Edwin) zero out correctly after all BALANCE entries.
        var groupDebt: [String: Double] = [:]

        for entry in entries {
            let entryShares = sharesByEntry[entry.id] ?? []
            let type = entry.typeTransaction.uppercased()
            let payer = entry.whoPaid

            if type == "NORMAL" {
                for share in entryShares {
                    let member = share.memberName
                    guard member != payer else { continue }
                    groupDebt[member, default: 0] += share.amount   // member consumed → owes
                    groupDebt[payer, default: 0]  -= share.amount   // payer advanced → credited
                }
            } else if type == "INCOME" {
                for share in entryShares {
                    let member = share.memberName
                    guard member != payer else { continue }
                    groupDebt[member, default: 0] -= share.amount   // opposite of expense
                    groupDebt[payer, default: 0]  += share.amount
                }
            } else if type == "BALANCE" || type == "TRANSFER" {
                // payer is settling; each non-zero allocation is a recipient.
                for share in entryShares where share.amount > 0 && share.memberName != payer {
                    groupDebt[payer, default: 0]             -= share.amount  // paying off debt
                    groupDebt[share.memberName, default: 0]  += share.amount  // credit consumed
                }
            }
        }

        return groupDebt
            .filter { $0.key != myName }
            .map { name, debt in
                TricountMemberBalance(
                    memberName: name,
                    iOwe:    debt < 0 ? -debt : 0,
                    theyOwe: debt > 0 ?  debt : 0
                )
            }
            .sorted { abs($0.net) > abs($1.net) }
    }

    // MARK: - Helpers

    private func str(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func exec(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        sqlite3_step(stmt)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_TC)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func rollbackAndCapture(db: OpaquePointer) {
        TricountRepository.lastSaveError = String(cString: sqlite3_errmsg(db))
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }
}

// MARK: - Parsed intermediate model

struct ParsedTCEntry {
    let sourceUUID: String
    let sourceUpdatedAt: String?
    let typeTransaction: String
    let whoPaid: String
    let total: Double
    let currency: String
    let localTotal: Double?
    let localCurrency: String?
    let description: String
    let date: String // yyyy-MM-dd
    let shares: [(memberName: String, amount: Double)]
    let category: String
}
