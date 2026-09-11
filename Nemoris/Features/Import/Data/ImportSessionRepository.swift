import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// CRUD for import sessions and CSV mappings.
/// A session's content is serialized as JSON in `import_sessions.rows_json`.
struct ImportSessionRepository {

    private let store: SQLiteStore

    /// The default value targets the app's own database: existing call sites
    /// need no change.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    // MARK: - Sessions

    /// Returns the lightweight summary of the sessions, most recent first.
    func fetchSummaries(status: ImportSessionStatus? = nil) -> [ImportSessionSummary] {
        guard store.databaseExists else { return [] }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let sql: String
        if status != nil {
            sql = "SELECT id, created_at, updated_at, status, source_file, account_id, total_rows, rows_json, destination FROM import_sessions WHERE status = ? ORDER BY updated_at DESC;"
        } else {
            sql = "SELECT id, created_at, updated_at, status, source_file, account_id, total_rows, rows_json, destination FROM import_sessions ORDER BY updated_at DESC;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let status {
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
        }

        var out: [ImportSessionSummary] = []
        let formatter = Self.isoFormatter
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idRaw = String(cString: sqlite3_column_text(stmt, 0))
            guard let id = UUID(uuidString: idRaw),
                  let createdAt = formatter.date(from: String(cString: sqlite3_column_text(stmt, 1))),
                  let updatedAt = formatter.date(from: String(cString: sqlite3_column_text(stmt, 2))),
                  let st = ImportSessionStatus(rawValue: String(cString: sqlite3_column_text(stmt, 3)))
            else { continue }

            let sourceFile = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let accountId = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 5))
            let total = Int(sqlite3_column_int(stmt, 6))

            // Computing pendingRows requires decoding rows_json. A pity for the "lite"
            // summary, but it's the only way without a separate table. The cost stays
            // reasonable since there is only 1 active session in practice.
            let jsonRaw = String(cString: sqlite3_column_text(stmt, 7))
            let destination = ImportDestination(
                rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .transactions
            // An investment session has no per-row state: everything it contains is
            // still to be reviewed, so everything is "pending".
            let pending = destination == .transactions
                ? Self.countPending(jsonRaw: jsonRaw)
                : total

            out.append(ImportSessionSummary(
                id: id, createdAt: createdAt, updatedAt: updatedAt, status: st,
                sourceFile: sourceFile, accountId: accountId,
                totalRows: total, pendingRows: pending, destination: destination
            ))
        }
        return out
    }

    /// Fetches THE active session (there should only be one), otherwise nil.
    func fetchActiveSummary() -> ImportSessionSummary? {
        fetchSummaries(status: .active).first
    }

    /// Loads a session fully (including every row) by id.
    func fetchSession(id: UUID) -> ImportSession? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "SELECT id, created_at, updated_at, status, source_file, account_id, rows_json, destination FROM import_sessions WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let formatter = Self.isoFormatter
        let idRaw = String(cString: sqlite3_column_text(stmt, 0))
        guard let uuid = UUID(uuidString: idRaw),
              let createdAt = formatter.date(from: String(cString: sqlite3_column_text(stmt, 1))),
              let updatedAt = formatter.date(from: String(cString: sqlite3_column_text(stmt, 2))),
              let st = ImportSessionStatus(rawValue: String(cString: sqlite3_column_text(stmt, 3)))
        else { return nil }

        let sourceFile = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let accountId = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let jsonRaw = String(cString: sqlite3_column_text(stmt, 6))
        let destination = ImportDestination(
            rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .transactions

        // The content of `rows_json` depends on the destination. Sessions without a
        // `destination` value fall back to the DEFAULT 'transactions', so they land
        // in the first branch and read back unchanged.
        switch destination {
        case .transactions:
            let rows = (try? Self.jsonDecoder.decode([ImportSessionRow].self,
                                                     from: Data(jsonRaw.utf8))) ?? []
            return ImportSession(
                id: uuid, createdAt: createdAt, updatedAt: updatedAt, status: st,
                sourceFile: sourceFile, accountId: accountId,
                destination: .transactions, rows: rows)
        case .investments:
            let batch = try? Self.jsonDecoder.decode(ImportBatchResult.self,
                                                     from: Data(jsonRaw.utf8))
            return ImportSession(
                id: uuid, createdAt: createdAt, updatedAt: updatedAt, status: st,
                sourceFile: sourceFile, accountId: accountId,
                destination: .investments, batch: batch)
        }
    }

    /// Inserts a new session (INSERT). Returns true on success.
    @discardableResult
    func insertSession(_ session: ImportSession) -> Bool {
        upsertSession(session, isInsert: true)
    }

    /// The ONLY import session factory: inserts, schedules the 12 h reminder and
    /// returns the summary ready for `AppState`. `nil` if the insert failed.
    ///
    /// Centralized because the flow has TWO row producers (CSV column mapping
    /// and PDF/capture document extraction): letting them duplicate this final
    /// stretch would make the reminder notification or the initial status
    /// diverge as soon as one of them evolves.
    func createSession(rows: [ImportSessionRow],
                       accountId: Int,
                       sourceFile: String?) -> ImportSessionSummary? {
        guard !rows.isEmpty else { return nil }
        let session = ImportSession(
            id: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            status: .active,
            sourceFile: sourceFile,
            accountId: accountId,
            rows: rows
        )
        guard insertSession(session) else { return nil }

        Task { await ImportNotificationService.scheduleReminder(forSessionId: session.id,
                                                               pendingRows: rows.count) }
        return ImportSessionSummary(
            id: session.id,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            status: .active,
            sourceFile: session.sourceFile,
            accountId: session.accountId,
            totalRows: session.rows.count,
            pendingRows: session.rows.count
        )
    }

    /// Session factory for INVESTMENTS.
    ///
    /// Same final stretch as the transaction version (insert + 12 h reminder +
    /// summary), with different content. It persists an investment analysis so
    /// relaunching the app doesn't lose it — a statement analysis takes tens of
    /// seconds.
    func createSession(batch: ImportBatchResult,
                       accountId: Int,
                       sourceFile: String?) -> ImportSessionSummary? {
        guard !batch.elements.isEmpty else { return nil }
        let session = ImportSession(
            id: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            status: .active,
            sourceFile: sourceFile,
            accountId: accountId,
            destination: .investments,
            batch: batch
        )
        guard insertSession(session) else { return nil }

        Task { await ImportNotificationService.scheduleReminder(forSessionId: session.id,
                                                               pendingRows: batch.elements.count) }
        return ImportSessionSummary(
            id: session.id,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            status: .active,
            sourceFile: session.sourceFile,
            accountId: session.accountId,
            totalRows: batch.elements.count,
            pendingRows: batch.elements.count,
            destination: .investments
        )
    }

    /// Updates the full payload of an existing session (UPDATE).
    /// Atomic: a single UPDATE. Also updates `updated_at`.
    @discardableResult
    func saveSession(_ session: ImportSession) -> Bool {
        upsertSession(session, isInsert: false)
    }

    /// Deletes a session (e.g. on cancel).
    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM import_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func upsertSession(_ session: ImportSession, isInsert: Bool) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // The serialized content depends on the destination.
        let payloadData: Data
        switch session.destination {
        case .transactions:
            payloadData = (try? Self.jsonEncoder.encode(session.rows)) ?? Data("[]".utf8)
        case .investments:
            payloadData = (try? Self.jsonEncoder.encode(session.batch ?? ImportBatchResult()))
                ?? Data("{}".utf8)
        }
        let rowsJSON = String(data: payloadData, encoding: .utf8) ?? "[]"
        let totalRows = session.totalRows
        let now = Self.isoFormatter.string(from: Date())
        let createdAt = Self.isoFormatter.string(from: session.createdAt)

        let sql: String
        if isInsert {
            sql = """
                INSERT INTO import_sessions
                (id, created_at, updated_at, status, source_file, account_id, total_rows, rows_json, destination)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
        } else {
            sql = """
                UPDATE import_sessions
                SET updated_at = ?, status = ?, source_file = ?, account_id = ?,
                    total_rows = ?, rows_json = ?, destination = ?
                WHERE id = ?;
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        if isInsert {
            sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, createdAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, now, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, session.status.rawValue, -1, SQLITE_TRANSIENT)
            bindOptText(stmt: stmt, idx: 5, value: session.sourceFile)
            bindOptInt(stmt: stmt, idx: 6, value: session.accountId)
            sqlite3_bind_int(stmt, 7, Int32(totalRows))
            sqlite3_bind_text(stmt, 8, rowsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, session.destination.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_text(stmt, 1, now, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, session.status.rawValue, -1, SQLITE_TRANSIENT)
            bindOptText(stmt: stmt, idx: 3, value: session.sourceFile)
            bindOptInt(stmt: stmt, idx: 4, value: session.accountId)
            sqlite3_bind_int(stmt, 5, Int32(totalRows))
            sqlite3_bind_text(stmt, 6, rowsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, session.destination.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, session.id.uuidString, -1, SQLITE_TRANSIENT)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - CSV mappings

    func findMapping(headerSignature: String) -> ColumnMapping? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            SELECT date_column_index, amount_column_index, label_column_index,
                   separator, date_format, amount_decimal
            FROM csv_mappings WHERE header_signature = ? LIMIT 1;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, headerSignature, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let dateIdx = Int(sqlite3_column_int(stmt, 0))
        let amountIdx = Int(sqlite3_column_int(stmt, 1))
        let labelIdx = Int(sqlite3_column_int(stmt, 2))
        let sep = String(cString: sqlite3_column_text(stmt, 3))
        let df = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let dec = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? "," : String(cString: sqlite3_column_text(stmt, 5))

        return ColumnMapping(
            headerSignature: headerSignature,
            dateColumnIndex: dateIdx,
            amountColumnIndex: amountIdx,
            labelColumnIndex: labelIdx,
            separator: sep,
            dateFormat: df,
            amountDecimal: dec
        )
    }

    @discardableResult
    func saveMapping(_ m: ColumnMapping) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
            INSERT INTO csv_mappings (header_signature, date_column_index, amount_column_index,
                                      label_column_index, separator, date_format, amount_decimal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(header_signature) DO UPDATE SET
                date_column_index   = excluded.date_column_index,
                amount_column_index = excluded.amount_column_index,
                label_column_index  = excluded.label_column_index,
                separator           = excluded.separator,
                date_format         = excluded.date_format,
                amount_decimal      = excluded.amount_decimal;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, m.headerSignature, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(m.dateColumnIndex))
        sqlite3_bind_int(stmt, 3, Int32(m.amountColumnIndex))
        sqlite3_bind_int(stmt, 4, Int32(m.labelColumnIndex))
        sqlite3_bind_text(stmt, 5, m.separator, -1, SQLITE_TRANSIENT)
        bindOptText(stmt: stmt, idx: 6, value: m.dateFormat)
        sqlite3_bind_text(stmt, 7, m.amountDecimal, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, Self.isoFormatter.string(from: Date()), -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Helpers

    private func bindOptText(stmt: OpaquePointer, idx: Int32, value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
    private func bindOptInt(stmt: OpaquePointer, idx: Int32, value: Int?) {
        if let value { sqlite3_bind_int(stmt, idx, Int32(value)) } else { sqlite3_bind_null(stmt, idx) }
    }

    /// Counting by scanning the string (avoids a costly JSON decode on large
    /// sessions). Codable serialization represents it as `"userAction":"pending"`
    /// — if the enum's format changes, update this needle.
    private static func countPending(jsonRaw: String) -> Int {
        let needle = "\"userAction\":\"pending\""
        var count = 0
        var idx = jsonRaw.startIndex
        while let range = jsonRaw.range(of: needle, range: idx..<jsonRaw.endIndex) {
            count += 1
            idx = range.upperBound
        }
        return count
    }

    // `nonisolated(unsafe)` justified: ISO8601DateFormatter, JSONEncoder and
    // JSONDecoder are thread-safe for parsing/encoding once configured (Apple
    // docs), but aren't Sendable. They're configured once at startup and never
    // mutated afterwards.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
