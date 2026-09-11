import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// CRUD pour les sessions d'import et les mappings CSV.
/// Le contenu d'une session est sérialisé en JSON dans `import_sessions.rows_json`.
struct ImportSessionRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    // MARK: - Sessions

    /// Renvoie le résumé léger des sessions, plus récente d'abord.
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

            // Pour calculer pendingRows, on doit décoder rows_json. C'est dommage pour la "lite"
            // mais c'est le seul moyen sans table séparée. Le coût reste raisonnable car on a
            // 1 seule session active en pratique.
            let jsonRaw = String(cString: sqlite3_column_text(stmt, 7))
            let destination = ImportDestination(
                rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .transactions
            // Une session d'investissements n'a pas d'état par ligne : tout ce
            // qu'elle contient reste à relire, donc tout est « en attente ».
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

    /// Récupère LA session active (il ne devrait y en avoir qu'une), sinon nil.
    func fetchActiveSummary() -> ImportSessionSummary? {
        fetchSummaries(status: .active).first
    }

    /// Charge intégralement une session (incluant toutes les rows) par id.
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

        // ⚠️ Le contenu de `rows_json` dépend de la destination (migration v45).
        // Les sessions écrites avant cette migration n'ont pas de colonne
        // `destination` renseignée : le DEFAULT 'transactions' les fait tomber
        // dans la première branche, donc elles se relisent inchangées.
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

    /// Insère une nouvelle session (INSERT). Renvoie true si OK.
    @discardableResult
    func insertSession(_ session: ImportSession) -> Bool {
        upsertSession(session, isInsert: true)
    }

    /// SEUL fabricant de session d'import : insère, programme le rappel 12 h et
    /// renvoie le résumé prêt pour `AppState`. `nil` si l'insert a échoué.
    ///
    /// Centralisé parce que le parcours a maintenant DEUX producteurs de lignes
    /// (mapping de colonnes CSV et extraction de documents PDF/captures) : leur
    /// laisser dupliquer cette fin de course ferait diverger la notification de
    /// rappel ou le statut initial dès la première évolution de l'un des deux.
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

    /// Fabrique de session pour les INVESTISSEMENTS.
    ///
    /// Même fin de course que la version transactions (insert + rappel 12 h +
    /// résumé), avec un contenu différent. Elle existe parce que le résultat
    /// d'une analyse d'investissements ne vivait qu'en mémoire : relancer l'app
    /// le perdait, alors qu'une analyse de relevé se compte en dizaines de
    /// secondes — l'asymétrie était documentée et assumée, elle ne l'est plus.
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

    /// Met à jour le payload complet d'une session existante (UPDATE).
    /// Atomique : un seul UPDATE. Met aussi à jour `updated_at`.
    @discardableResult
    func saveSession(_ session: ImportSession) -> Bool {
        upsertSession(session, isInsert: false)
    }

    /// Supprime une session (ex : cancel).
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

        // Le contenu sérialisé dépend de la destination (cf. migration v45).
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

    /// Comptage par scan de string (évite un JSON.decode coûteux sur les grandes sessions).
    /// La sérialisation Codable utilise `"userAction":"pending"` comme représentation —
    /// si on change le format de l'enum, mettre à jour ce needle.
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

    // `nonisolated(unsafe)` justifié : ISO8601DateFormatter, JSONEncoder et JSONDecoder
    // sont thread-safe pour parser/encoder une fois configurés (Apple docs), mais ne sont
    // pas Sendable. On les configure une fois au démarrage, jamais mutés ensuite.
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
