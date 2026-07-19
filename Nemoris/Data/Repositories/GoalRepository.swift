import Foundation
import SQLite3

// MARK: - GoalRepository
//
// CRUD pour la table `goals` (migration v39). Pattern aligné sur les autres
// repositories : struct + `query` READONLY + `writeSingle` READWRITE + helpers
// (string, bindOptionalText) recopiés localement pour rester self-contained.

private let SQLITE_TRANSIENT_GOAL = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct GoalRepository {
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Fetch

    /// Tous les goals triés du plus récent au plus ancien.
    func fetchGoals() -> [Goal] {
        query { db in
            let sql = """
            SELECT id, name, kind, target_amount,
                   COALESCE(deadline_date, ''),
                   COALESCE(custom_current_amount, 0),
                   COALESCE(notes, ''),
                   created_at
            FROM goals
            ORDER BY created_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [Goal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let kindRaw = string(from: stmt, index: 2)
                let deadlineRaw = string(from: stmt, index: 4)
                let notesRaw = string(from: stmt, index: 6)
                results.append(Goal(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    kind: GoalKind(rawValue: kindRaw) ?? .custom,
                    targetAmount: sqlite3_column_double(stmt, 3),
                    deadlineDate: deadlineRaw.isEmpty ? nil : dateFormatter.date(from: deadlineRaw),
                    customCurrentAmount: sqlite3_column_double(stmt, 5),
                    notes: notesRaw.isEmpty ? nil : notesRaw,
                    createdAt: dateFormatter.date(from: string(from: stmt, index: 7)) ?? Date()
                ))
            }
            return results
        } ?? []
    }

    // MARK: - Write

    @discardableResult
    func addGoal(name: String, kind: GoalKind, targetAmount: Double,
                 deadlineDate: Date?, customCurrentAmount: Double, notes: String?) -> Bool {
        let sql = """
        INSERT INTO goals
            (name, kind, target_amount, deadline_date, custom_current_amount, notes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_GOAL)
            sqlite3_bind_text(stmt, 2, kind.rawValue, -1, SQLITE_TRANSIENT_GOAL)
            sqlite3_bind_double(stmt, 3, targetAmount)
            if let deadlineDate {
                sqlite3_bind_text(stmt, 4, dateFormatter.string(from: deadlineDate), -1, SQLITE_TRANSIENT_GOAL)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, customCurrentAmount)
            bindOptionalText(stmt, 6, notes)
            sqlite3_bind_text(stmt, 7, dateFormatter.string(from: Date()), -1, SQLITE_TRANSIENT_GOAL)
        }
    }

    @discardableResult
    func updateGoal(_ goal: Goal) -> Bool {
        let sql = """
        UPDATE goals
        SET name = ?, kind = ?, target_amount = ?, deadline_date = ?,
            custom_current_amount = ?, notes = ?
        WHERE id = ?;
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, goal.name, -1, SQLITE_TRANSIENT_GOAL)
            sqlite3_bind_text(stmt, 2, goal.kind.rawValue, -1, SQLITE_TRANSIENT_GOAL)
            sqlite3_bind_double(stmt, 3, goal.targetAmount)
            if let deadline = goal.deadlineDate {
                sqlite3_bind_text(stmt, 4, dateFormatter.string(from: deadline), -1, SQLITE_TRANSIENT_GOAL)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, goal.customCurrentAmount)
            bindOptionalText(stmt, 6, goal.notes)
            sqlite3_bind_int(stmt, 7, Int32(goal.id))
        }
    }

    @discardableResult
    func deleteGoal(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM goals WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    // MARK: - Helpers internes

    private func query<T>(_ block: (OpaquePointer) -> T) -> T? {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        return block(db)
    }

    @discardableResult
    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func string(from stmt: OpaquePointer?, index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value, !v.isEmpty {
            sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT_GOAL)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
