import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - BudgetRepository
//
// CRUD pour les tables budget (recurring_patterns, budget_envelopes, budget_previsions).
// Meme pattern que les autres repositories : OpaquePointer SQLite3, pas de Combine.

final class BudgetRepository: @unchecked Sendable {
    static let shared = BudgetRepository()

    private let store: SQLiteStore

    /// `shared` reste le point d'accès de l'application ; l'init injectable
    /// permet aux tests d'instancier le repository sur une base temporaire.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    // MARK: - Recurring Patterns

    func fetchPatterns() -> [RecurringPattern] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var results: [RecurringPattern] = []
        let sql = """
            SELECT id, name, amount_avg, amount_tolerance, category_id, payee_id,
                   frequency, anchor_day, is_active, is_manual, created_at, last_detected_at,
                   start_date, end_date
            FROM recurring_patterns
            ORDER BY is_active DESC, name ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = rowToPattern(stmt) { results.append(p) }
        }
        return results
    }

    func fetchActivePatterns() -> [RecurringPattern] {
        fetchPatterns().filter { $0.isActive }
    }

    @discardableResult
    func insertPattern(_ p: RecurringPattern) -> Int? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            INSERT INTO recurring_patterns
            (name, amount_avg, amount_tolerance, category_id, payee_id,
             frequency, anchor_day, is_active, is_manual, created_at, last_detected_at,
             start_date, end_date)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, p.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, p.amountAvg)
        sqlite3_bind_double(stmt, 3, p.amountTolerance)
        bindOptionalInt(stmt, 4, p.categoryId)
        bindOptionalInt(stmt, 5, p.payeeId)
        sqlite3_bind_text(stmt, 6, p.frequency.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 7, p.anchorDay)
        sqlite3_bind_int(stmt, 8, p.isActive ? 1 : 0)
        sqlite3_bind_int(stmt, 9, p.isManual ? 1 : 0)
        sqlite3_bind_text(stmt, 10, isoString(p.createdAt), -1, SQLITE_TRANSIENT)
        if let d = p.lastDetectedAt {
            sqlite3_bind_text(stmt, 11, isoString(d), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_text(stmt, 12, isoString(p.startDate), -1, SQLITE_TRANSIENT)
        if let e = p.endDate {
            sqlite3_bind_text(stmt, 13, isoString(e), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func updatePattern(_ p: RecurringPattern) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            UPDATE recurring_patterns
            SET name=?, amount_avg=?, amount_tolerance=?, category_id=?, payee_id=?,
                frequency=?, anchor_day=?, is_active=?, last_detected_at=?,
                start_date=?, end_date=?
            WHERE id=?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, p.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, p.amountAvg)
        sqlite3_bind_double(stmt, 3, p.amountTolerance)
        bindOptionalInt(stmt, 4, p.categoryId)
        bindOptionalInt(stmt, 5, p.payeeId)
        sqlite3_bind_text(stmt, 6, p.frequency.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 7, p.anchorDay)
        sqlite3_bind_int(stmt, 8, p.isActive ? 1 : 0)
        if let d = p.lastDetectedAt {
            sqlite3_bind_text(stmt, 9, isoString(d), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_text(stmt, 10, isoString(p.startDate), -1, SQLITE_TRANSIENT)
        if let e = p.endDate {
            sqlite3_bind_text(stmt, 11, isoString(e), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_int(stmt, 12, Int32(p.id))
        sqlite3_step(stmt)
    }

    /// ⚠️ `PRAGMA foreign_keys = ON` est indispensable ici.
    ///
    /// SQLite désactive les clés étrangères PAR CONNEXION et par défaut. Le
    /// `ON DELETE CASCADE` déclaré sur `budget_previsions.recurring_pattern_id`
    /// ne se déclenche donc pas tout seul : sans ce pragma, supprimer un
    /// récurrent laissait ses prévisions orphelines, et elles continuaient
    /// d'apparaître au calendrier sans récurrent pour les expliquer.
    func deletePattern(id: Int) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM recurring_patterns WHERE id=?;", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(id))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Budget Envelopes

    func fetchEnvelopes() -> [BudgetEnvelope] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var results: [BudgetEnvelope] = []
        let sql = """
            SELECT id, name, category_id, amount, period, start_date, is_active
            FROM budget_envelopes
            ORDER BY is_active DESC, name ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let e = rowToEnvelope(stmt) { results.append(e) }
        }
        return results
    }

    @discardableResult
    func insertEnvelope(_ e: BudgetEnvelope) -> Int? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            INSERT INTO budget_envelopes (name, category_id, amount, period, start_date, is_active)
            VALUES (?,?,?,?,?,?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, e.name, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 2, e.categoryId)
        sqlite3_bind_double(stmt, 3, e.amount)
        sqlite3_bind_text(stmt, 4, e.period.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, isoString(e.startDate), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 6, e.isActive ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func updateEnvelope(_ e: BudgetEnvelope) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            UPDATE budget_envelopes
            SET name=?, category_id=?, amount=?, period=?, is_active=?
            WHERE id=?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, e.name, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 2, e.categoryId)
        sqlite3_bind_double(stmt, 3, e.amount)
        sqlite3_bind_text(stmt, 4, e.period.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 5, e.isActive ? 1 : 0)
        sqlite3_bind_int(stmt, 6, Int32(e.id))
        sqlite3_step(stmt)
    }

    func deleteEnvelope(id: Int) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM budget_envelopes WHERE id=?;", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(id))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Budget Previsions

    func fetchPrevisions(from startDate: Date, to endDate: Date) -> [BudgetPrevision] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var results: [BudgetPrevision] = []
        let sql = """
            SELECT id, recurring_pattern_id, amount, expected_date, status,
                   actual_transaction_id, notes
            FROM budget_previsions
            WHERE expected_date >= ? AND expected_date <= ?
            ORDER BY expected_date ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoString(startDate), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, isoString(endDate), -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = rowToPrevision(stmt) { results.append(p) }
        }
        return results
    }

    func fetchPrevisions(forPatternId patternId: Int) -> [BudgetPrevision] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var results: [BudgetPrevision] = []
        let sql = """
            SELECT id, recurring_pattern_id, amount, expected_date, status,
                   actual_transaction_id, notes
            FROM budget_previsions
            WHERE recurring_pattern_id = ?
            ORDER BY expected_date ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(patternId))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = rowToPrevision(stmt) { results.append(p) }
        }
        return results
    }

    @discardableResult
    func insertPrevision(_ p: BudgetPrevision) -> Int? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            INSERT INTO budget_previsions
            (recurring_pattern_id, amount, expected_date, status, actual_transaction_id, notes)
            VALUES (?,?,?,?,?,?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindOptionalInt(stmt, 1, p.recurringPatternId)
        sqlite3_bind_double(stmt, 2, p.amount)
        sqlite3_bind_text(stmt, 3, isoString(p.expectedDate), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, p.status.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 5, p.actualTransactionId)
        if let n = p.notes {
            sqlite3_bind_text(stmt, 6, n, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func updatePrevisionStatus(id: Int, status: PrevisionStatus, transactionId: Int?) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "UPDATE budget_previsions SET status=?, actual_transaction_id=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalInt(stmt, 2, transactionId)
        sqlite3_bind_int(stmt, 3, Int32(id))
        sqlite3_step(stmt)
    }

    func deletePrevision(id: Int) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM budget_previsions WHERE id=?;", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(id))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Supprime toutes les previsions PENDING d'un pattern, puis les regenere sur toute la
    /// plage active (jusqu'a 6 mois en arriere, 3 mois en avant).
    /// Les previsions MATCHED et SKIPPED sont conservees.
    func regeneratePrevisions(for pattern: RecurringPattern, monthsAhead: Int = 3) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Supprimer UNIQUEMENT les PENDING (MATCHED et SKIPPED sont preserves)
        var stmt: OpaquePointer?
        let deleteSql = "DELETE FROM budget_previsions WHERE recurring_pattern_id = ? AND status = 'PENDING';"
        if sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(pattern.id))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Cleanup global : supprimer les PENDING trop anciens (> 2 ans) pour eviter le gonflement de la base
        let now = Date()
        let twoYearsAgoStr = isoString(Calendar.current.date(byAdding: .year, value: -2, to: now) ?? now)
        var cleanStmt: OpaquePointer?
        let cleanSql = "DELETE FROM budget_previsions WHERE status = 'PENDING' AND expected_date < ?;"
        if sqlite3_prepare_v2(db, cleanSql, -1, &cleanStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cleanStmt, 1, twoYearsAgoStr, -1, SQLITE_TRANSIENT)
            sqlite3_step(cleanStmt)
            sqlite3_finalize(cleanStmt)
        }

        // Determiner la plage de generation
        let cal = Calendar.current
        // Remonte jusqu'a 6 mois en arriere pour couvrir l'historique visible
        let lookback = cal.date(byAdding: .month, value: -6, to: now) ?? now
        let genStart = max(pattern.startDate, lookback)
        let genEnd: Date = {
            let future = cal.date(byAdding: .month, value: monthsAhead, to: now) ?? now
            if let end = pattern.endDate { return min(end, future) }
            return future
        }()
        guard genStart <= genEnd else { return }

        // Recuperer les dates deja couvertes par MATCHED/SKIPPED pour eviter les doublons
        var coveredDates = Set<String>()
        var qStmt: OpaquePointer?
        let querySql = """
            SELECT expected_date FROM budget_previsions
            WHERE recurring_pattern_id = ? AND status != 'PENDING';
            """
        if sqlite3_prepare_v2(db, querySql, -1, &qStmt, nil) == SQLITE_OK {
            sqlite3_bind_int(qStmt, 1, Int32(pattern.id))
            while sqlite3_step(qStmt) == SQLITE_ROW {
                if let d = columnText(qStmt, 0) { coveredDates.insert(d) }
            }
            sqlite3_finalize(qStmt)
        }

        // Generer et inserer les nouvelles echeances PENDING
        let dates = RecurringDetector.generateOccurrences(for: pattern, from: genStart, to: genEnd)
        for date in dates {
            let key = isoString(date)
            guard !coveredDates.contains(key) else { continue }
            let prevision = BudgetPrevision(
                id: 0, recurringPatternId: pattern.id, amount: pattern.amountAvg,
                expectedDate: date, status: .pending, actualTransactionId: nil, notes: nil
            )
            insertPrevision(prevision)
        }
    }

    // MARK: - Row Mappers

    private func rowToPattern(_ stmt: OpaquePointer?) -> RecurringPattern? {
        guard let stmt else { return nil }
        let id        = Int(sqlite3_column_int(stmt, 0))
        let name      = columnText(stmt, 1) ?? ""
        let amtAvg    = sqlite3_column_double(stmt, 2)
        let amtTol    = sqlite3_column_double(stmt, 3)
        let catId     = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
        let payeeId   = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let freqRaw   = columnText(stmt, 6) ?? "MONTHLY"
        let anchorDay = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
        let isActive  = sqlite3_column_int(stmt, 8) != 0
        let isManual  = sqlite3_column_int(stmt, 9) != 0
        let createdAt = parseDate(columnText(stmt, 10)) ?? Date()
        let lastDetected = parseDate(columnText(stmt, 11))
        let freq = RecurrenceFrequency(rawValue: freqRaw) ?? .monthly
        // start_date: fallback to createdAt if column missing or empty (pre-v16 rows)
        let startDate = parseDate(columnText(stmt, 12)) ?? createdAt
        let endDate   = parseDate(columnText(stmt, 13))
        return RecurringPattern(
            id: id, name: name, amountAvg: amtAvg, amountTolerance: amtTol,
            categoryId: catId, payeeId: payeeId, frequency: freq, anchorDay: anchorDay,
            isActive: isActive, isManual: isManual, createdAt: createdAt, lastDetectedAt: lastDetected,
            startDate: startDate, endDate: endDate
        )
    }

    private func rowToEnvelope(_ stmt: OpaquePointer?) -> BudgetEnvelope? {
        guard let stmt else { return nil }
        let id       = Int(sqlite3_column_int(stmt, 0))
        let name     = columnText(stmt, 1) ?? ""
        let catId    = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2))
        let amount   = sqlite3_column_double(stmt, 3)
        let periodRaw = columnText(stmt, 4) ?? "MONTHLY"
        let startDate = parseDate(columnText(stmt, 5)) ?? Date()
        let isActive = sqlite3_column_int(stmt, 6) != 0
        let period = BudgetPeriod(rawValue: periodRaw) ?? .monthly
        return BudgetEnvelope(id: id, name: name, categoryId: catId, amount: amount,
                              period: period, startDate: startDate, isActive: isActive)
    }

    private func rowToPrevision(_ stmt: OpaquePointer?) -> BudgetPrevision? {
        guard let stmt else { return nil }
        let id         = Int(sqlite3_column_int(stmt, 0))
        let patternId  = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1))
        let amount     = sqlite3_column_double(stmt, 2)
        let date       = parseDate(columnText(stmt, 3)) ?? Date()
        let statusRaw  = columnText(stmt, 4) ?? "PENDING"
        let txId       = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let notes      = columnText(stmt, 6)
        let status     = PrevisionStatus(rawValue: statusRaw) ?? .pending
        return BudgetPrevision(id: id, recurringPatternId: patternId, amount: amount,
                               expectedDate: date, status: status,
                               actualTransactionId: txId, notes: notes)
    }

    // MARK: - SQLite Helpers

    private func openDB() -> OpaquePointer? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            store.databaseURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard result == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: str)
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int?) {
        if let v = value {
            sqlite3_bind_int(stmt, col, Int32(v))
        } else {
            sqlite3_bind_null(stmt, col)
        }
    }
}
