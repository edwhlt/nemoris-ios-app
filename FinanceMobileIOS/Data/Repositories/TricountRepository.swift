import Foundation
import SQLite3

private let SQLITE_TRANSIENT_TC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TricountRepository {

    // MARK: - Table Setup

    func setupTables() {
        guard DatabaseManager.shared.hasDatabase() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE IF NOT EXISTS tricount_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tricount_key TEXT NOT NULL,
            title TEXT NOT NULL,
            currency TEXT DEFAULT 'EUR',
            my_name TEXT NOT NULL,
            fetched_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tricount_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_id INTEGER NOT NULL REFERENCES tricount_groups(id) ON DELETE CASCADE,
            type_transaction TEXT NOT NULL DEFAULT 'NORMAL',
            who_paid TEXT NOT NULL,
            total REAL NOT NULL,
            currency TEXT NOT NULL DEFAULT 'EUR',
            description TEXT DEFAULT '',
            date TEXT NOT NULL,
            category TEXT DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS tricount_shares (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
            member_name TEXT NOT NULL,
            amount REAL NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Groups

    func fetchGroups() -> [TricountGroup] {
        guard DatabaseManager.shared.hasDatabase() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

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

    /// Saves (or replaces) a group and all its entries+shares atomically. Returns the new group id.
    @discardableResult
    func saveGroup(key: String, title: String, currency: String, myName: String,
                   entries: [ParsedTCEntry]) -> Int? {
        guard DatabaseManager.shared.hasDatabase() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)

        // Delete existing group with same key
        exec(db, "DELETE FROM tricount_groups WHERE tricount_key = ?") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT_TC) }

        // Insert group
        let fetchedAt = ISO8601DateFormatter().string(from: Date())
        let groupSQL = "INSERT INTO tricount_groups (tricount_key, title, currency, my_name, fetched_at) VALUES (?, ?, ?, ?, ?)"
        var groupId: Int?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, groupSQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(stmt, 3, currency, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(stmt, 4, myName, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(stmt, 5, fetchedAt, -1, SQLITE_TRANSIENT_TC)
            if sqlite3_step(stmt) == SQLITE_DONE {
                groupId = Int(sqlite3_last_insert_rowid(db))
            }
        }
        guard let gid = groupId else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return nil
        }

        // Insert entries + shares
        let entrySQL = "INSERT INTO tricount_entries (group_id, type_transaction, who_paid, total, currency, description, date, category) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        let shareSQL = "INSERT INTO tricount_shares (entry_id, member_name, amount) VALUES (?, ?, ?)"

        for entry in entries {
            var eStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, entrySQL, -1, &eStmt, nil) == SQLITE_OK, let eStmt else { continue }
            defer { sqlite3_finalize(eStmt) }
            sqlite3_bind_int(eStmt, 1, Int32(gid))
            sqlite3_bind_text(eStmt, 2, entry.typeTransaction, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(eStmt, 3, entry.whoPaid, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_double(eStmt, 4, entry.total)
            sqlite3_bind_text(eStmt, 5, entry.currency, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(eStmt, 6, entry.description, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(eStmt, 7, entry.date, -1, SQLITE_TRANSIENT_TC)
            sqlite3_bind_text(eStmt, 8, entry.category, -1, SQLITE_TRANSIENT_TC)
            guard sqlite3_step(eStmt) == SQLITE_DONE else { continue }
            let entryId = Int(sqlite3_last_insert_rowid(db))

            for (member, amount) in entry.shares {
                var sStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, shareSQL, -1, &sStmt, nil) == SQLITE_OK, let sStmt else { continue }
                defer { sqlite3_finalize(sStmt) }
                sqlite3_bind_int(sStmt, 1, Int32(entryId))
                sqlite3_bind_text(sStmt, 2, member, -1, SQLITE_TRANSIENT_TC)
                sqlite3_bind_double(sStmt, 3, amount)
                sqlite3_step(sStmt)
            }
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return gid
    }

    func deleteGroup(id: Int) {
        guard DatabaseManager.shared.hasDatabase() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        exec(db, "DELETE FROM tricount_groups WHERE id = ?") { sqlite3_bind_int($0, 1, Int32(id)) }
    }

    // MARK: - Entries + Shares

    func fetchEntries(groupId: Int) -> [TricountEntry] {
        guard DatabaseManager.shared.hasDatabase() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, group_id, type_transaction, who_paid, total, currency, description, date, category FROM tricount_entries WHERE group_id = ? ORDER BY date DESC, id DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(groupId))

        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        var entries: [TricountEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(TricountEntry(
                id: Int(sqlite3_column_int(stmt, 0)),
                groupId: Int(sqlite3_column_int(stmt, 1)),
                typeTransaction: str(stmt, 2),
                whoPaid: str(stmt, 3),
                total: sqlite3_column_double(stmt, 4),
                currency: str(stmt, 5),
                description: str(stmt, 6),
                date: fmt.date(from: str(stmt, 7)) ?? Date(),
                category: str(stmt, 8)
            ))
        }
        return entries
    }

    func fetchShares(groupId: Int) -> [TricountShare] {
        guard DatabaseManager.shared.hasDatabase() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

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

    // MARK: - Balance Computation

    func computeBalances(entries: [TricountEntry], shares: [TricountShare], myName: String) -> [TricountMemberBalance] {
        let sharesByEntry = Dictionary(grouping: shares, by: { $0.entryId })
        var balanceMap: [String: (iOwe: Double, theyOwe: Double)] = [:]

        for entry in entries {
            let entryShares = sharesByEntry[entry.id] ?? []
            if entry.whoPaid == myName {
                for share in entryShares where share.memberName != myName {
                    balanceMap[share.memberName, default: (0, 0)].theyOwe += share.amount
                }
            } else {
                if let myShare = entryShares.first(where: { $0.memberName == myName }) {
                    balanceMap[entry.whoPaid, default: (0, 0)].iOwe += myShare.amount
                }
            }
        }

        return balanceMap.map { name, amounts in
            TricountMemberBalance(memberName: name, iOwe: amounts.iOwe, theyOwe: amounts.theyOwe)
        }.sorted { abs($0.net) > abs($1.net) }
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
}

// MARK: - Parsed intermediate model

struct ParsedTCEntry {
    let typeTransaction: String
    let whoPaid: String
    let total: Double
    let currency: String
    let description: String
    let date: String // yyyy-MM-dd
    let shares: [(memberName: String, amount: Double)]
    let category: String
}
