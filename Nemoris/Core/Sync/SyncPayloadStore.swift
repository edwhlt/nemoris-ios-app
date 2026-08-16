import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite access layer for the sync engine.
///
/// Bridges local rows (int PK/FK) and the payloads that travel over the wire
/// (uuid everywhere). JSON payload format (encrypted on the CloudKit side
/// via `encryptedValues`, see `CloudSyncEngine`):
///
/// ```json
/// {
///   "u": "<row uuid>",
///   "t": "<updated_at ISO8601>",             // LWW conflict resolution
///   "v": { "name": "Carrefour", ... },       // scalar columns
///   "r": { "payee_id": "<uuid>", ... },      // FKs serialized as uuid
///   "g": ["<tag uuid>", ...]                 // transactions only: tag links
/// }
/// ```
///
/// The CloudKit schema therefore never changes when a SQLite column is
/// added: columns unknown to a device that isn't yet up to date are ignored
/// on apply (intersected against PRAGMA table_info).
struct SyncPayloadStore: Sendable {

    /// SQLite database path. Injectable for tests — the argument-less init,
    /// which points at the app's database via DatabaseManager, lives in
    /// SyncLive.swift so this file stays free of any app-target dependency.
    let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Table configuration

    /// Application order for remote changes (referenced tables first) —
    /// single source of truth: SyncSchema.syncedTables.
    static let tableOrder: [String] = SyncSchema.syncedTables

    /// Synced FKs: column → target table. Any column absent from here is
    /// serialized as-is in "v". FKs go out as uuid in "r", never as an int id.
    static let foreignKeys: [String: [String: String]] = [
        "transactions": [
            "account_id": "accounts",
            "payee_id": "payees",
            "category_id": "categories",
            "payment_type_id": "payment_types",
        ],
        "payees": [
            "category_id": "categories",
            "linked_account_id": "accounts",
            "group_id": "payee_groups",
        ],
        "categories": [
            "parent_id": "categories",
        ],
        // — Transaction metadata
        // Both FKs are NOT NULL: an orphaned value would be meaningless. A
        // record arriving before its transaction or its key is therefore set
        // aside and replayed by `sync_deferred_rows`, instead of failing the
        // INSERT and being lost — CloudKit never redelivers a fetched record
        // that wasn't applied.
        "transaction_metadata_values": [
            "transaction_id": "transactions",
            "key_id": "transaction_metadata_keys",
        ],
        // — Budget
        "recurring_patterns": [
            "category_id": "categories",
            "payee_id": "payees",
        ],
        "budget_envelopes": [
            "category_id": "categories",
        ],
        "budget_previsions": [
            "recurring_pattern_id": "recurring_patterns",
            "actual_transaction_id": "transactions",
        ],
        // — Investments
        "investment_positions": [
            "account_id": "investment_accounts",
        ],
        "investment_orders": [
            "position_id": "investment_positions",
        ],
        // — Net worth
        "patrimoine_loans": [
            "linked_real_estate_id": "patrimoine_real_estate",
        ],
        "patrimoine_assets": [
            "linked_account_id": "accounts",
            "linked_investment_account_id": "investment_accounts",
        ],
        // — Tricount
        "tricount_entries": [
            "group_id": "tricount_groups",
            "user_category_id": "categories",
            "linked_transaction_id": "transactions",
        ],
        "tricount_shares": [
            "entry_id": "tricount_entries",
        ],
        // — Unified reimbursements
        "reimbursements": [
            "transaction_id": "transactions",
            "tricount_entry_id": "tricount_entries",
            "payee_id": "payees",
        ],
    ]

    private static let nowSQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    // MARK: - Connection

    private func openDB(readonly: Bool = false) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        // The sync engine writes concurrently with UI reads (repositories).
        // Without busy_timeout, any lock collision is an immediate
        // SQLITE_BUSY — missing data on the sync side, or visible contention
        // on the UI side. A polite 3s wait comfortably covers the longest
        // batch transaction.
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    // MARK: - Meta KV

    func metaValue(_ key: String) -> String? {
        guard let db = openDB(readonly: true) else { return nil }
        defer { sqlite3_close(db) }
        return Self.metaValue(db, key)
    }

    static func metaValue(_ db: OpaquePointer, _ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM sync_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    func setMeta(_ key: String, _ value: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        Self.setMeta(db, key, value)
    }

    static func setMeta(_ db: OpaquePointer, _ key: String, _ value: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteMeta(_ key: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sync_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Pending queue / tombstones

    struct PendingRow: Sendable {
        let table: String
        let uuid: String
        let queuedAt: String
    }

    func pendingRows(limit: Int = 400) -> [PendingRow] {
        guard let db = openDB(readonly: true) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT table_name, row_uuid, queued_at FROM sync_pending ORDER BY queued_at LIMIT ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        // -1 = unlimited on the SQLite side. Clamped to avoid an Int32
        // overflow (e.g. limit = Int.max passed to mean "push everything").
        sqlite3_bind_int(stmt, 1, limit >= Int(Int32.max) ? -1 : Int32(limit))
        var out: [PendingRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PendingRow(
                table: String(cString: sqlite3_column_text(stmt, 0)),
                uuid: String(cString: sqlite3_column_text(stmt, 1)),
                queuedAt: String(cString: sqlite3_column_text(stmt, 2))
            ))
        }
        return out
    }

    func tombstoneRows(limit: Int = 400) -> [PendingRow] {
        guard let db = openDB(readonly: true) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT table_name, row_uuid, deleted_at FROM sync_tombstones ORDER BY deleted_at LIMIT ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        // -1 = unlimited on the SQLite side. Clamped to avoid an Int32 overflow.
        sqlite3_bind_int(stmt, 1, limit >= Int(Int32.max) ? -1 : Int32(limit))
        var out: [PendingRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PendingRow(
                table: String(cString: sqlite3_column_text(stmt, 0)),
                uuid: String(cString: sqlite3_column_text(stmt, 1)),
                queuedAt: String(cString: sqlite3_column_text(stmt, 2))
            ))
        }
        return out
    }

    /// Removes a pending entry ONLY if it hasn't been re-queued since the
    /// batch was built (the user may have edited the row again during the
    /// upload — in that case the new version must go out too).
    func clearPending(table: String, uuid: String, queuedAtNotAfter: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sync_pending WHERE table_name = ? AND row_uuid = ? AND queued_at <= ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, queuedAtNotAfter, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func clearTombstone(table: String, uuid: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sync_tombstones WHERE table_name = ? AND row_uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Removes the factory categories / payment methods of a blank database
    /// (zero transactions) ahead of the initial CloudKit scan. Returns the
    /// number of rows removed. No-op if the user has already started entering data.
    func purgeVirginSeedReferenceData() -> Int {
        guard let db = openDB() else { return 0 }
        defer { sqlite3_close(db) }

        guard Self.scalarInt(db, "SELECT COUNT(*) FROM transactions;") == 0 else { return 0 }

        Self.setMeta(db, "suppress_triggers", "1")
        defer { Self.setMeta(db, "suppress_triggers", "0") }

        var purged = 0

        for name in SyncSchema.defaultSeedPaymentTypeNames {
            purged += Self.deleteSeedRowIfUnreferenced(
                db, table: "payment_types", name: name,
                referenceChecks: [
                    "SELECT COUNT(*) FROM transactions WHERE payment_type_id = ?;",
                ]
            )
        }

        let categoryRefChecks = Self.categoryReferenceChecks(db)

        // Subcategories first (parent_id FK), then root categories.
        for name in SyncSchema.defaultSeedCategoryNames {
            purged += Self.deleteSeedRowIfUnreferenced(
                db, table: "categories", name: name,
                referenceChecks: categoryRefChecks,
                requireParent: true
            )
        }
        for name in SyncSchema.defaultSeedCategoryNames {
            purged += Self.deleteSeedRowIfUnreferenced(
                db, table: "categories", name: name,
                referenceChecks: categoryRefChecks,
                requireParent: false
            )
        }

        return purged
    }

    // MARK: - Reference duplicate repair (one-shot at boot)

    /// Merges categories / payment_types duplicates created by early sync
    /// activations (before deterministic identity adoption existed): each
    /// device had uploaded its own factory seed, producing 2 uuid sets for
    /// the same entities, present everywhere.
    ///
    /// Merge rule (identical on every device → convergence):
    ///   - groups: payment_types by name (NOCASE); categories by
    ///     (name NOCASE, parent name NOCASE) — two "Other" entries under
    ///     different parents are NOT merged.
    ///   - keeper = the SMALLEST uuid in the group (same rule as identity adoption).
    ///   - all duplicate FKs are remapped to the keeper BEFORE the DELETE
    ///     (no dangling reference).
    ///   - runs with triggers ACTIVE: the DELETE creates a tombstone that
    ///     propagates the removal to the vault and other devices, and the
    ///     remapped rows go back into sync_pending.
    ///
    /// Called by DatabaseManager.migrateIfNeeded (gated by sync_meta
    /// 'ref_dedup_v1_done'). Returns the number of duplicates merged.
    static func dedupReferenceDuplicates(_ db: OpaquePointer) -> Int {
        var merged = 0
        merged += dedupTable(
            db, table: "categories", groupIncludesParent: true,
            referenceRemaps: [
                ("transactions", "category_id"),
                ("payees", "category_id"),
                ("recurring_patterns", "category_id"),
                ("budget_envelopes", "category_id"),
                ("tricount_entries", "user_category_id"),
                ("categories", "parent_id"),
            ]
        )
        merged += dedupTable(
            db, table: "payment_types", groupIncludesParent: false,
            referenceRemaps: [
                ("transactions", "payment_type_id"),
            ]
        )
        return merged
    }

    private static func dedupTable(_ db: OpaquePointer, table: String,
                                   groupIncludesParent: Bool,
                                   referenceRemaps: [(table: String, column: String)]) -> Int {
        // Load (id, uuid, group key).
        let sql = groupIncludesParent
            ? "SELECT c.id, c.uuid, lower(c.name) || '|' || COALESCE(lower((SELECT p.name FROM \(table) p WHERE p.id = c.parent_id)), '') FROM \(table) c WHERE c.uuid IS NOT NULL;"
            : "SELECT c.id, c.uuid, lower(c.name) FROM \(table) c WHERE c.uuid IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        var groups: [String: [(id: Int64, uuid: String)]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidC = sqlite3_column_text(stmt, 1),
                  let keyC = sqlite3_column_text(stmt, 2) else { continue }
            groups[String(cString: keyC), default: []]
                .append((sqlite3_column_int64(stmt, 0), String(cString: uuidC)))
        }
        sqlite3_finalize(stmt)

        var merged = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.uuid < $1.uuid }
            let keeper = sorted[0]
            for dupe in sorted.dropFirst() {
                for remap in referenceRemaps where SyncSchema.tableExists(db, remap.table) {
                    _ = execBind(db, "UPDATE \(remap.table) SET \(remap.column) = ? WHERE \(remap.column) = ?;",
                                 values: [keeper.id, dupe.id])
                }
                _ = execBind(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;",
                             values: [table, dupe.uuid])
                // DELETE with triggers active → automatic tombstone.
                _ = execBind(db, "DELETE FROM \(table) WHERE id = ?;", values: [dupe.id])
                merged += 1
                print("[SyncPayloadStore] Dedup \(table): \(dupe.uuid) merged into \(keeper.uuid)")
            }
        }
        return merged
    }

    private static func categoryReferenceChecks(_ db: OpaquePointer) -> [String] {
        var checks = [
            "SELECT COUNT(*) FROM transactions WHERE category_id = ?;",
            "SELECT COUNT(*) FROM payees WHERE category_id = ?;",
            "SELECT COUNT(*) FROM categories WHERE parent_id = ?;",
        ]
        if SyncSchema.tableExists(db, "recurring_patterns") {
            checks.append("SELECT COUNT(*) FROM recurring_patterns WHERE category_id = ?;")
        }
        if SyncSchema.tableExists(db, "budget_envelopes") {
            checks.append("SELECT COUNT(*) FROM budget_envelopes WHERE category_id = ?;")
        }
        if SyncSchema.tableExists(db, "tricount_entries") {
            checks.append("SELECT COUNT(*) FROM tricount_entries WHERE user_category_id = ?;")
        }
        return checks
    }

    /// Initial scan when sync is activated: puts ALL rows of every synced
    /// table into the upload queue.
    func enqueueAllRows() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        for table in Self.tableOrder {
            let sql = """
            INSERT OR REPLACE INTO sync_pending (table_name, row_uuid, queued_at)
            SELECT '\(table)', uuid, \(Self.nowSQL) FROM \(table) WHERE uuid IS NOT NULL;
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func pendingCount() -> Int {
        guard let db = openDB(readonly: true) else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT (SELECT COUNT(*) FROM sync_pending) + (SELECT COUNT(*) FROM sync_tombstones);", -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Deactivation: purges all local sync state (queue, tombstones, engine
    /// state, system fields). Does NOT touch business data or uuids.
    func clearAllSyncState() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        for sql in [
            "DELETE FROM sync_pending;",
            "DELETE FROM sync_tombstones;",
            "DELETE FROM sync_record_meta;",
            "DELETE FROM sync_unresolved_refs;",
            "DELETE FROM sync_deferred_rows;",
            "DELETE FROM sync_meta WHERE key IN ('ck_state', 'last_sync_at', 'last_sync_error');",
        ] {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - CKRecord system fields

    func recordSystemFields(table: String, uuid: String) -> Data? {
        guard let db = openDB(readonly: true) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT system_fields FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    func setRecordSystemFields(table: String, uuid: String, data: Data) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_record_meta (table_name, row_uuid, system_fields) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }

    func deleteRecordSystemFields(table: String, uuid: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Serialization: local row → JSON payload

    /// The row's JSON payload, or nil if the row no longer exists (deleted
    /// between queueing and upload).
    func payloadJSON(table: String, uuid: String) -> Data? {
        guard let db = openDB(readonly: true) else { return nil }
        defer { sqlite3_close(db) }

        let columns = Self.tableColumns(db, table: table)
        guard !columns.isEmpty else { return nil }
        let fkMap = Self.foreignKeys[table] ?? [:]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var values: [String: Any] = [:]
        var refs: [String: String] = [:]
        var localId: Int64 = 0
        var updatedAt = ""

        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            let type = sqlite3_column_type(stmt, i)
            if name == "id" { localId = sqlite3_column_int64(stmt, i); continue }
            if name == "uuid" { continue }
            if name == "updated_at" {
                if type != SQLITE_NULL { updatedAt = String(cString: sqlite3_column_text(stmt, i)) }
                continue
            }
            if type == SQLITE_NULL { continue }   // NULL = absent from the payload

            if let targetTable = fkMap[name] {
                // FK → target row's uuid. Target with no uuid (not possible
                // in practice past v40) or gone → FK omitted (NULL on the other end).
                let targetId = sqlite3_column_int64(stmt, i)
                if let targetUuid = Self.uuidForId(db, table: targetTable, id: targetId) {
                    refs[name] = targetUuid
                }
                continue
            }

            switch type {
            case SQLITE_INTEGER: values[name] = sqlite3_column_int64(stmt, i)
            case SQLITE_FLOAT: values[name] = sqlite3_column_double(stmt, i)
            case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(stmt, i))
            case SQLITE_BLOB:
                // No BLOB column exists in the synced tables — base64
                // encoding as a safeguard in case one ever does.
                if let blob = sqlite3_column_blob(stmt, i) {
                    values[name] = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, i))).base64EncodedString()
                }
            default: break
            }
        }

        var payload: [String: Any] = ["u": uuid, "t": updatedAt, "v": values]
        if !refs.isEmpty { payload["r"] = refs }

        // Tag links embedded in the owning row's payload (transactions and
        // tricount_entries).
        if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == table }) {
            let tagUuids = Self.tagUuids(db, link: link, ownerId: localId)
            if !tagUuids.isEmpty { payload["g"] = tagUuids }
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Apply: remote payload → local row

    enum ApplyResult: Sendable {
        case applied
        case skippedLocalNewer   // LWW: the local version wins, already in pending
        case failed
    }

    /// Tables carrying a business UNIQUE constraint (other than uuid). When
    /// two devices independently create "the same" entity (a 'vacation' tag
    /// on both, the same Binance trade imported twice), the uuids differ and
    /// the remote record's INSERT violates the constraint. Resolution:
    /// ADOPTION — the local row takes on the remote uuid (identities merge,
    /// local int FKs don't move), and the old uuid is tombstoned to clean up
    /// any duplicate already uploaded to the server.
    static let uniqueAdoptionKeys: [String: String] = [
        "tags": "name",                      // UNIQUE COLLATE NOCASE
        "investment_orders": "external_id",  // partial UNIQUE
        // Two devices each creating "Project" independently produce two
        // uuids for the SAME key, and the UNIQUE index on `name` makes the
        // apply fail. Identity adoption (min(uuid) wins) merges them instead
        // of leaving a permanently failing record.
        "transaction_metadata_keys": "name",  // UNIQUE COLLATE NOCASE
    ]

    /// Reference tables where a collision on `name` (COLLATE NOCASE) means
    /// "the same entity" — identities are merged before INSERT. Covers the
    /// local seed vs. remote data (categories, payment methods).
    private static let nameAdoptionTables: Set<String> = [
        "categories",
        "payment_types",
    ]

    /// Applies a remote record. The suppress_triggers flag MUST be set by
    /// the caller (batch-level, see CloudSyncEngine.applyBatch).
    func applyRemoteRecord(table: String, payloadData: Data) -> ApplyResult {
        guard Self.tableOrder.contains(table) else { return .failed }
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData),
              let payload = obj as? [String: Any],
              payload["u"] is String, payload["t"] is String else { return .failed }

        guard let db = openDB() else { return .failed }
        defer { sqlite3_close(db) }
        return Self.apply(db, table: table, payload: payload, allowAdoption: true)
    }

    private static func apply(_ db: OpaquePointer, table: String,
                              payload: [String: Any], allowAdoption: Bool) -> ApplyResult {
        guard let uuid = payload["u"] as? String,
              let remoteUpdatedAt = payload["t"] as? String else { return .failed }

        // LWW: if the local row is newer or equal, keep the local one (it's
        // in sync_pending and will go back out to the server).
        var localId: Int64?
        if let (id, localUpdatedAt) = localRow(db, table: table, uuid: uuid) {
            if localUpdatedAt >= remoteUpdatedAt { return .skippedLocalNewer }
            localId = id
        }

        let columns = tableColumns(db, table: table)
        let values = (payload["v"] as? [String: Any]) ?? [:]
        let refs = (payload["r"] as? [String: String]) ?? [:]
        let fkMap = foreignKeys[table] ?? [:]

        // Assemble columns → values to write (intersected with the local
        // schema: columns from a newer app version are ignored, local
        // columns absent from the payload become NULL).
        var assignments: [(column: String, value: Any?)] = []
        // True if at least one FK in the payload points at a target that
        // hasn't arrived yet. If the write then fails on a constraint (a
        // NOT NULL FK column, e.g. investment_orders.position_id), the
        // payload is DEFERRED instead of lost (see sync_deferred_rows).
        var hadMissingRef = false
        for column in columns where column != "id" && column != "uuid" && column != "updated_at" {
            if let targetTable = fkMap[column] {
                if let targetUuid = refs[column] {
                    if let targetId = idForUuid(db, table: targetTable, uuid: targetUuid) {
                        assignments.append((column, targetId))
                    } else {
                        // Target hasn't arrived yet → NULL + a pending ref.
                        assignments.append((column, nil))
                        hadMissingRef = true
                        storeUnresolvedRef(db, table: table, uuid: uuid, column: column,
                                           targetTable: targetTable, targetUuid: targetUuid)
                    }
                } else {
                    assignments.append((column, nil))
                }
            } else {
                assignments.append((column, values[column]))
            }
        }
        assignments.append(("updated_at", remoteUpdatedAt))

        if let localId {
            let setClause = assignments.map { "\($0.column) = ?" }.joined(separator: ", ")
            if !execBind(db, "UPDATE \(table) SET \(setClause) WHERE id = \(localId);",
                         values: assignments.map(\.value)) {
                // Likely cause: NULL on a NOT NULL FK whose target hasn't
                // arrived — keep the payload to replay it later.
                if hadMissingRef { storeDeferredRow(db, table: table, uuid: uuid, payload: payload) }
                return .failed
            }
        } else {
            // PROACTIVE merge by name (categories, payment_types — reference
            // tables WITHOUT a UNIQUE constraint): a local row with the same
            // name is the same entity. Without this check, two devices'
            // factory seeds would coexist as silent duplicates.
            //
            // Deterministic to avoid ping-pong: the SMALLEST uuid wins, on
            // EVERY device (otherwise each side adopts the other's uuid and
            // tombstones the one the other side just adopted → row loss).
            //   - remote < local → the local row adopts the remote uuid, re-applied.
            //   - local <= remote → the remote duplicate is NOT inserted; it
            //     will be tombstoned by the other device once it receives
            //     OUR record and adopts our uuid.
            if allowAdoption, nameAdoptionTables.contains(table),
               let name = values["name"] as? String,
               let local = findRow(db, table: table, column: "name", value: name, caseInsensitive: true) {
                if uuid < local.uuid,
                   adoptIdentity(db, table: table, localId: local.id, oldUuid: local.uuid, remoteUuid: uuid) {
                    return apply(db, table: table, payload: payload, allowAdoption: false)
                }
                return .skippedLocalNewer
            }

            let cols = ["uuid"] + assignments.map(\.column)
            let placeholders = cols.map { _ in "?" }.joined(separator: ", ")
            let rc = execBindRC(db, "INSERT INTO \(table) (\(cols.joined(separator: ", "))) VALUES (\(placeholders));",
                                values: [uuid] + assignments.map(\.value))
            if rc != SQLITE_DONE {
                // Business uniqueness violation (tags.name, external_id…) →
                // identity adoption, same deterministic min(uuid) rule.
                let isConstraint = (rc & 0xFF) == SQLITE_CONSTRAINT
                if isConstraint, allowAdoption,
                   let uniqueColumn = uniqueAdoptionKeys[table],
                   let uniqueValue = values[uniqueColumn],
                   let local = findRow(db, table: table, column: uniqueColumn, value: uniqueValue, caseInsensitive: false),
                   uuid < local.uuid,
                   adoptIdentity(db, table: table, localId: local.id, oldUuid: local.uuid, remoteUuid: uuid) {
                    // Re-apply: the adopted row now carries the remote uuid →
                    // standard UPDATE + LWW path.
                    return apply(db, table: table, payload: payload, allowAdoption: false)
                }
                // A NOT NULL FK whose target hasn't arrived yet (CloudKit
                // batches carry no guaranteed order): the payload is set
                // aside and replayed once the target arrives — otherwise the
                // record would be PERMANENTLY lost (no redelivery).
                if isConstraint, hadMissingRef {
                    storeDeferredRow(db, table: table, uuid: uuid, payload: payload)
                    return .failed
                }
                // Local uuid <= remote: the remote record is ignored — it
                // will be tombstoned by the device that owns it (no retry: a
                // fetched but unapplied record only comes back if it changes again).
                return .failed
            }
        }

        // Owning row's tag links: full replacement.
        if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == table }),
           let ownerId = idForUuid(db, table: table, uuid: uuid) {
            let tagUuids = (payload["g"] as? [String]) ?? []
            rebuildTagLinks(db, link: link, ownerId: ownerId, ownerUuid: uuid, tagUuids: tagUuids)
        }

        return .applied
    }

    /// Row (id, uuid) carrying `value` in `column`, or nil.
    private static func findRow(_ db: OpaquePointer, table: String, column: String,
                                value: Any, caseInsensitive: Bool) -> (id: Int64, uuid: String)? {
        var stmt: OpaquePointer?
        let collate = caseInsensitive ? " COLLATE NOCASE" : ""
        guard sqlite3_prepare_v2(db, "SELECT id, uuid FROM \(table) WHERE \(column) = ?\(collate);", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        switch value {
        case let v as String: sqlite3_bind_text(stmt, 1, v, -1, SQLITE_TRANSIENT)
        case let v as NSNumber: sqlite3_bind_int64(stmt, 1, v.int64Value)
        default: return nil
        }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let uuidC = sqlite3_column_text(stmt, 1) else { return nil }
        return (sqlite3_column_int64(stmt, 0), String(cString: uuidC))
    }

    /// Identity merge: the local row adopts the remote uuid. Local int
    /// PK/FKs don't change; the old uuid is tombstoned to remove any
    /// duplicate already on the server. The caller has ALREADY checked the
    /// deterministic rule (remoteUuid < oldUuid).
    private static func adoptIdentity(_ db: OpaquePointer, table: String,
                                      localId: Int64, oldUuid: String,
                                      remoteUuid: String) -> Bool {
        guard oldUuid != remoteUuid else { return false }
        guard execBind(db, "UPDATE \(table) SET uuid = ? WHERE id = \(localId);", values: [remoteUuid]) else { return false }
        // The old uuid must no longer be uploaded…
        _ = execBind(db, "DELETE FROM sync_pending WHERE table_name = ? AND row_uuid = ?;", values: [table, oldUuid])
        _ = execBind(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", values: [table, oldUuid])
        // …and its server record (if already pushed) must disappear.
        _ = execBind(db, "INSERT OR REPLACE INTO sync_tombstones (table_name, row_uuid, deleted_at) VALUES (?, ?, \(nowSQL));",
                     values: [table, oldUuid])
        print("[SyncPayloadStore] Adoption \(table): \(oldUuid) → \(remoteUuid)")
        return true
    }

    /// True if the row has a local modification not yet sent.
    func hasPendingChange(table: String, uuid: String) -> Bool {
        guard let db = openDB(readonly: true) else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sync_pending WHERE table_name = ? AND row_uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Remote deletion. Assumes suppress_triggers is set by the caller.
    ///
    /// Delete-vs-update rule: if the local row carries a PENDING modification
    /// (edited here, not sent yet), the remote deletion is IGNORED — an edit
    /// is never destroyed by another device's delete. Our pending save
    /// recreates the record server-side (.unknownItem → resurrection) and
    /// the device that deleted it picks the row back up on its next fetch.
    /// If the row is "clean" (already synced), the deletion applies: the
    /// delete is the most recent action.
    func applyRemoteDeletion(table: String, uuid: String) {
        guard Self.tableOrder.contains(table), let db = openDB() else { return }
        defer { sqlite3_close(db) }
        Self.deleteRemoteRow(db, table: table, uuid: uuid)
    }

    private static func deleteRemoteRow(_ db: OpaquePointer, table: String, uuid: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM sync_pending WHERE table_name = ? AND row_uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
            let pending = sqlite3_step(stmt) == SQLITE_ROW
            sqlite3_finalize(stmt)
            if pending {
                print("[SyncPayloadStore] Remote delete ignored (pending local edit): \(table)/\(uuid)")
                return
            }
        }

        // FKs aren't enforced on this connection (foreign_keys pragma OFF by
        // default): tag links are cleaned up manually before the DELETE.
        if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == table }),
           let ownerId = idForUuid(db, table: table, uuid: uuid) {
            sqlite3_exec(db, "DELETE FROM \(link.linkTable) WHERE \(link.ownerFK) = \(ownerId);", nil, nil, nil)
        }
        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE uuid = ?;", -1, &delStmt, nil) == SQLITE_OK, let delStmt else { return }
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_text(delStmt, 1, uuid, -1, SQLITE_TRANSIENT)
        sqlite3_step(delStmt)

        _ = execBind(db, "DELETE FROM sync_unresolved_refs WHERE table_name = ? AND row_uuid = ?;", values: [table, uuid])
        // A deferred row that receives its tombstone no longer needs replaying.
        _ = execBind(db, "DELETE FROM sync_deferred_rows WHERE table_name = ? AND row_uuid = ?;", values: [table, uuid])
    }

    // MARK: - Batch apply (perf)

    struct RemoteModification: Sendable {
        let table: String
        let uuid: String
        let payloadData: Data
        let systemFields: Data
    }

    struct RemoteDeletion: Sendable {
        let table: String
        let uuid: String
    }

    /// Applies an ENTIRE CloudKit batch in ONE connection + ONE transaction.
    ///
    /// Applying record-by-record instead would open a connection and a
    /// micro-transaction per row — on the initial download (~6000 records),
    /// thousands of rapid-fire lock/unlock cycles would starve UI reads (no
    /// busy_timeout on the repository side). Here: 1 short
    /// BEGIN IMMEDIATE … COMMIT per batch (~200 CloudKit records).
    ///
    /// The suppress_triggers flag is set/cleared INSIDE the transaction: the
    /// triggers (same connection) see it immediately, and it's never visible
    /// to other connections — there's no window where a concurrent app write
    /// goes untracked.
    func applyRemoteBatch(modifications: [RemoteModification], deletions: [RemoteDeletion]) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('suppress_triggers', '1');", values: [])

        // Referenced tables first (tableOrder): a batch containing accounts,
        // positions, and orders together applies in the right order — most
        // NOT NULL FKs resolve inline, without going through the deferred
        // queue (which covers the cross-batch case).
        let ordered = modifications.sorted {
            (Self.tableOrder.firstIndex(of: $0.table) ?? Int.max)
                < (Self.tableOrder.firstIndex(of: $1.table) ?? Int.max)
        }
        for mod in ordered {
            guard Self.tableOrder.contains(mod.table) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: mod.payloadData),
                  let payload = obj as? [String: Any],
                  payload["u"] is String, payload["t"] is String else { continue }

            switch Self.apply(db, table: mod.table, payload: payload, allowAdoption: true) {
            case .applied, .skippedLocalNewer:
                // Either way, keep the system fields: the next local save
                // must start from the current server version.
                _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_record_meta (table_name, row_uuid, system_fields) VALUES (?, ?, ?);",
                                  values: [mod.table, mod.uuid, mod.systemFields])
            case .failed:
                // If apply() just DEFERRED the record (a NOT NULL FK missing
                // its target), attach its system fields too: the replay must
                // also start from the current server version.
                _ = Self.execBind(db, "UPDATE sync_deferred_rows SET system_fields = ? WHERE table_name = ? AND row_uuid = ?;",
                                  values: [mod.systemFields, mod.table, mod.uuid])
                print("[SyncPayloadStore] Apply failed: \(mod.table)/\(mod.uuid)")
            }
        }

        for del in deletions {
            guard Self.tableOrder.contains(del.table) else { continue }
            Self.deleteRemoteRow(db, table: del.table, uuid: del.uuid)
            _ = Self.execBind(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", values: [del.table, del.uuid])
            _ = Self.execBind(db, "DELETE FROM sync_tombstones WHERE table_name = ? AND row_uuid = ?;", values: [del.table, del.uuid])
        }

        // FKs whose target just arrived in this batch.
        Self.resolveUnresolvedRefs(db)

        // DEFERRED records (NOT NULL FK) whose targets now exist: orders
        // that were waiting on their positions, positions waiting on their account…
        Self.applyDeferredRows(db)

        _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('suppress_triggers', '0');", values: [])
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Retries resolving pending FKs (targets that arrived in a later
    /// batch). Called after every applied batch, with suppress set.
    func resolveUnresolvedRefs() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        Self.resolveUnresolvedRefs(db)
    }

    private static func resolveUnresolvedRefs(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT table_name, row_uuid, column_name, target_table, target_uuid FROM sync_unresolved_refs;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        var pending: [(table: String, uuid: String, column: String, targetTable: String, targetUuid: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            pending.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2)),
                String(cString: sqlite3_column_text(stmt, 3)),
                String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        sqlite3_finalize(stmt)

        for ref in pending {
            guard let targetId = Self.idForUuid(db, table: ref.targetTable, uuid: ref.targetUuid) else { continue }
            if ref.column.hasPrefix("__tag__") {
                // Pending tag link — the link table depends on the owner.
                if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == ref.table }),
                   let ownerId = Self.idForUuid(db, table: ref.table, uuid: ref.uuid) {
                    sqlite3_exec(db, "INSERT OR IGNORE INTO \(link.linkTable) (\(link.ownerFK), tag_id) VALUES (\(ownerId), \(targetId));", nil, nil, nil)
                }
            } else {
                _ = Self.execBind(db, "UPDATE \(ref.table) SET \(ref.column) = ? WHERE uuid = ?;",
                                  values: [targetId, ref.uuid])
            }
            _ = Self.execBind(db, "DELETE FROM sync_unresolved_refs WHERE table_name = ? AND row_uuid = ? AND column_name = ?;",
                              values: [ref.table, ref.uuid, ref.column])
        }
    }

    // MARK: - Deferred records (NOT NULL FK awaiting its target)

    /// Sets aside a remote payload that was rejected because a NOT NULL FK
    /// isn't resolvable yet. `INSERT OR REPLACE`: deferring the same row
    /// again overwrites the entry (the most recent payload wins).
    private static func storeDeferredRow(_ db: OpaquePointer, table: String,
                                         uuid: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = execBind(db, """
            INSERT OR REPLACE INTO sync_deferred_rows (table_name, row_uuid, payload, queued_at)
            VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
            """, values: [table, uuid, data])
    }

    /// Replays deferred payloads. Loops until stable (applying one row can
    /// unblock others: account → position → order), capped at 5 passes for
    /// safety. A row still blocked is re-deferred by apply() and retried on
    /// the next batch.
    static func applyDeferredRows(_ db: OpaquePointer) {
        for _ in 0..<5 {
            var rows: [(table: String, uuid: String, payload: Data, systemFields: Data?)] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT table_name, row_uuid, payload, system_fields FROM sync_deferred_rows;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let table = String(cString: sqlite3_column_text(stmt, 0))
                let uuid = String(cString: sqlite3_column_text(stmt, 1))
                var payload = Data()
                if let bytes = sqlite3_column_blob(stmt, 2) {
                    payload = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
                }
                var sf: Data?
                if let bytes = sqlite3_column_blob(stmt, 3) {
                    sf = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3)))
                }
                rows.append((table, uuid, payload, sf))
            }
            sqlite3_finalize(stmt)
            if rows.isEmpty { return }

            // Referenced tables first, same as batches.
            rows.sort {
                (tableOrder.firstIndex(of: $0.table) ?? Int.max)
                    < (tableOrder.firstIndex(of: $1.table) ?? Int.max)
            }

            var progressed = false
            for row in rows {
                guard let obj = try? JSONSerialization.jsonObject(with: row.payload),
                      let payload = obj as? [String: Any] else {
                    _ = execBind(db, "DELETE FROM sync_deferred_rows WHERE table_name = ? AND row_uuid = ?;", values: [row.table, row.uuid])
                    continue
                }
                // Remove BEFORE re-applying: if the target is still missing,
                // apply() rewrites the entry; otherwise it stays cleared.
                _ = execBind(db, "DELETE FROM sync_deferred_rows WHERE table_name = ? AND row_uuid = ?;", values: [row.table, row.uuid])
                switch apply(db, table: row.table, payload: payload, allowAdoption: true) {
                case .applied, .skippedLocalNewer:
                    progressed = true
                    if let sf = row.systemFields {
                        _ = execBind(db, "INSERT OR REPLACE INTO sync_record_meta (table_name, row_uuid, system_fields) VALUES (?, ?, ?);",
                                     values: [row.table, row.uuid, sf])
                    }
                case .failed:
                    // Re-deferred by apply() if the FK is still missing:
                    // re-attach the system fields (storeDeferredRow doesn't
                    // know them).
                    if let sf = row.systemFields {
                        _ = execBind(db, "UPDATE sync_deferred_rows SET system_fields = ? WHERE table_name = ? AND row_uuid = ?;",
                                     values: [sf, row.table, row.uuid])
                    }
                }
            }
            if !progressed { return }
        }
    }

    /// Off-batch variant (tests, repairs): opens its own connection.
    func retryDeferredRows() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        Self.applyDeferredRows(db)
    }

    // MARK: - Private helpers

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Removes a seed row by name if it isn't referenced anywhere.
    @discardableResult
    private static func deleteSeedRowIfUnreferenced(
        _ db: OpaquePointer,
        table: String,
        name: String,
        referenceChecks: [String],
        requireParent: Bool? = nil
    ) -> Int {
        var findStmt: OpaquePointer?
        let parentClause: String
        switch requireParent {
        case true:  parentClause = " AND parent_id IS NOT NULL"
        case false: parentClause = " AND parent_id IS NULL"
        default:    parentClause = ""
        }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id FROM \(table) WHERE name = ? COLLATE NOCASE\(parentClause);",
            -1, &findStmt, nil
        ) == SQLITE_OK, let findStmt else { return 0 }
        defer { sqlite3_finalize(findStmt) }
        sqlite3_bind_text(findStmt, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(findStmt) == SQLITE_ROW else { return 0 }
        let rowId = sqlite3_column_int64(findStmt, 0)

        for checkSQL in referenceChecks {
            var checkStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK, let checkStmt else { return 0 }
            sqlite3_bind_int64(checkStmt, 1, rowId)
            let count = sqlite3_step(checkStmt) == SQLITE_ROW ? sqlite3_column_int(checkStmt, 0) : 0
            sqlite3_finalize(checkStmt)
            if count > 0 { return 0 }
        }

        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK, let delStmt else { return 0 }
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_int64(delStmt, 1, rowId)
        guard sqlite3_step(delStmt) == SQLITE_DONE else { return 0 }
        return 1
    }

    private static func tableColumns(_ db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 1)))
        }
        return out
    }

    private static func localRow(_ db: OpaquePointer, table: String, uuid: String) -> (id: Int64, updatedAt: String)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, COALESCE(updated_at, '') FROM \(table) WHERE uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0), String(cString: sqlite3_column_text(stmt, 1)))
    }

    private static func uuidForId(_ db: OpaquePointer, table: String, id: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT uuid FROM \(table) WHERE id = \(id);", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    private static func idForUuid(_ db: OpaquePointer, table: String, uuid: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM \(table) WHERE uuid = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func tagUuids(_ db: OpaquePointer, link: SyncSchema.TagLink, ownerId: Int64) -> [String] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT t.uuid FROM \(link.linkTable) lt
        JOIN tags t ON t.id = lt.tag_id
        WHERE lt.\(link.ownerFK) = \(ownerId) AND t.uuid IS NOT NULL;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    private static func rebuildTagLinks(_ db: OpaquePointer, link: SyncSchema.TagLink,
                                        ownerId: Int64, ownerUuid: String, tagUuids: [String]) {
        sqlite3_exec(db, "DELETE FROM \(link.linkTable) WHERE \(link.ownerFK) = \(ownerId);", nil, nil, nil)
        for tagUuid in tagUuids {
            if let tagId = idForUuid(db, table: "tags", uuid: tagUuid) {
                sqlite3_exec(db, "INSERT OR IGNORE INTO \(link.linkTable) (\(link.ownerFK), tag_id) VALUES (\(ownerId), \(tagId));", nil, nil, nil)
            } else {
                // Tag hasn't arrived yet → pending link (resolved post-batch).
                storeUnresolvedRef(db, table: link.ownerTable, uuid: ownerUuid,
                                   column: "__tag__\(tagUuid)", targetTable: "tags", targetUuid: tagUuid)
            }
        }
    }

    private static func storeUnresolvedRef(_ db: OpaquePointer, table: String, uuid: String,
                                           column: String, targetTable: String, targetUuid: String) {
        _ = execBind(db, "INSERT OR REPLACE INTO sync_unresolved_refs (table_name, row_uuid, column_name, target_table, target_uuid) VALUES (?, ?, ?, ?, ?);",
                     values: [table, uuid, column, targetTable, targetUuid])
    }

    /// Executes a statement with heterogeneous binds (String / Int64 / Double / nil).
    private static func execBind(_ db: OpaquePointer, _ sql: String, values: [Any?]) -> Bool {
        let rc = execBindRC(db, sql, values: values)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// Variant that exposes the raw SQLite result code — needed to
    /// discriminate a constraint violation (identity adoption) from a real
    /// error. `(rc & 0xFF) == SQLITE_CONSTRAINT` covers the extended codes
    /// (SQLITE_CONSTRAINT_UNIQUE = 2067, etc.).
    private static func execBindRC(_ db: OpaquePointer, _ sql: String, values: [Any?]) -> Int32 {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            print("[SyncPayloadStore] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return prep == SQLITE_OK ? SQLITE_ERROR : prep
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as NSNumber:
                // JSONSerialization produces NSNumber: discriminate int/double.
                if CFNumberIsFloatType(v) { sqlite3_bind_double(stmt, idx, v.doubleValue) }
                else { sqlite3_bind_int64(stmt, idx, v.int64Value) }
            case let v as Data:
                // BLOB (deferred payloads, CKRecord system fields). Without
                // this case, Data falls into `default:` and binds NULL silently.
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    _ = v.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(stmt, idx, bytes.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                    }
                }
            case nil: sqlite3_bind_null(stmt, idx)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW && (rc & 0xFF) != SQLITE_CONSTRAINT {
            print("[SyncPayloadStore] step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rc
    }
}
