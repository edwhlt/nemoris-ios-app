import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// AXE L — Couche L.1 : accès SQLite du moteur de sync.
///
/// Fait le pont entre les rows locales (int PK/FK) et les payloads qui
/// voyagent (uuid partout). Format du payload JSON (chiffré côté CloudKit
/// via `encryptedValues`, voir `CloudSyncEngine`) :
///
/// ```json
/// {
///   "u": "<uuid de la row>",
///   "t": "<updated_at ISO8601>",             // résolution de conflits LWW
///   "v": { "name": "Carrefour", ... },       // colonnes scalaires
///   "r": { "payee_id": "<uuid>", ... },      // FK sérialisées en uuid
///   "g": ["<uuid tag>", ...]                 // transactions uniquement : liens tags
/// }
/// ```
///
/// Le schéma CloudKit ne bouge donc jamais quand une colonne SQLite est
/// ajoutée : les colonnes inconnues d'un appareil pas encore à jour sont
/// ignorées à l'application (intersection avec PRAGMA table_info).
struct SyncPayloadStore: Sendable {

    /// Chemin de la base SQLite. Injectable pour les tests (harness standalone
    /// dans NemorisApp/Tests/) — l'init sans argument, qui pointe sur la base
    /// de l'app via DatabaseManager, vit dans SyncLive.swift pour que ce
    /// fichier reste compilable hors du target (aucune dépendance app).
    let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Configuration des tables

    /// Ordre d'application des changements distants (tables référencées
    /// d'abord) — source unique : SyncSchema.syncedTables.
    static let tableOrder: [String] = SyncSchema.syncedTables

    /// FK synchronisées : colonne → table cible. Toute colonne absente d'ici
    /// est sérialisée telle quelle dans "v". Les FK sortent en uuid dans "r",
    /// jamais en int id.
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
        // — Métadonnées de transaction (v46)
        // ⚠️ Les DEUX FK sont NOT NULL : une valeur orpheline n'aurait aucun
        // sens. Un record arrivé avant sa transaction ou sa clé est donc mis de
        // côté puis rejoué par `sync_deferred_rows` (v43), au lieu d'échouer
        // à l'INSERT et d'être perdu — CloudKit ne re-livre pas un record
        // fetché non appliqué.
        "transaction_metadata_values": [
            "transaction_id": "transactions",
            "key_id": "transaction_metadata_keys",
        ],
        // — Budget (L.3)
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
        // — Investissements (L.3)
        "investment_positions": [
            "account_id": "investment_accounts",
        ],
        "investment_orders": [
            "position_id": "investment_positions",
        ],
        // — Patrimoine (L.3)
        "patrimoine_loans": [
            "linked_real_estate_id": "patrimoine_real_estate",
        ],
        "patrimoine_assets": [
            "linked_account_id": "accounts",
            "linked_investment_account_id": "investment_accounts",
        ],
        // — Tricount (L.3)
        "tricount_entries": [
            "group_id": "tricount_groups",
            "user_category_id": "categories",
            "linked_transaction_id": "transactions",
        ],
        "tricount_shares": [
            "entry_id": "tricount_entries",
        ],
        // — Remboursement unifié (L.3+, AXE R)
        "reimbursements": [
            "transaction_id": "transactions",
            "tricount_entry_id": "tricount_entries",
            "payee_id": "payees",
        ],
    ]

    private static let nowSQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    // MARK: - Connexion

    private func openDB(readonly: Bool = false) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        // Le moteur de sync écrit en concurrence avec les lectures UI (repos).
        // Sans busy_timeout, toute collision de verrou = SQLITE_BUSY immédiat
        // → données manquantes côté sync ou contention visible côté UI. 3s
        // d'attente polie couvrent largement la plus longue transaction batch.
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

    // MARK: - Queue pending / tombstones

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
        // -1 = illimité côté SQLite. Clamp pour éviter tout overflow Int32
        // (ex: limit = Int.max passé pour "tout pousser").
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
        // -1 = illimité côté SQLite. Clamp pour éviter tout overflow Int32.
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

    /// Retire une entrée pending SEULEMENT si elle n'a pas été re-queueée
    /// depuis la construction du batch (l'user a pu rééditer la row pendant
    /// l'upload — dans ce cas la nouvelle version doit repartir).
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

    /// Retire les catégories / modes de paiement « usine » d'une base vierge
    /// (zéro transaction) avant le scan initial CloudKit. Retourne le nombre
    /// de rows supprimées. No-op si l'user a déjà commencé à saisir.
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

        // Sous-catégories d'abord (FK parent_id), puis catégories racines.
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

    // MARK: - Réparation des doublons de référence (one-shot au boot)

    /// Fusionne les doublons de categories / payment_types créés par les
    /// premières activations sync (avant l'adoption déterministe) : chaque
    /// appareil avait uploadé son seed usine → 2 jeux d'uuids pour les mêmes
    /// entités, présents partout.
    ///
    /// Règle de fusion (identique sur tous les appareils → convergence) :
    ///   - groupes : payment_types par nom (NOCASE) ; categories par
    ///     (nom NOCASE, nom du parent NOCASE) — deux "Autre" sous des parents
    ///     différents ne sont PAS fusionnés.
    ///   - keeper = le PLUS PETIT uuid du groupe (même règle que l'adoption).
    ///   - toutes les FK des doublons sont remappées vers le keeper AVANT le
    ///     DELETE (aucune perte de rattachement).
    ///   - exécuté avec les triggers ACTIFS : le DELETE crée la tombstone qui
    ///     propage la suppression au coffre et aux autres appareils, les rows
    ///     remappées repartent en sync_pending.
    ///
    /// Appelé par DatabaseManager.migrateIfNeeded (gate sync_meta
    /// 'ref_dedup_v1_done'). Retourne le nombre de doublons fusionnés.
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
        // Charge (id, uuid, clé de groupe).
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
                // DELETE sous triggers actifs → tombstone automatique.
                _ = execBind(db, "DELETE FROM \(table) WHERE id = ?;", values: [dupe.id])
                merged += 1
                print("[SyncPayloadStore] Dédup \(table) : \(dupe.uuid) fusionné dans \(keeper.uuid)")
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

    /// Scan initial à l'activation de la sync : met TOUTES les rows des tables
    /// synchronisées dans la queue d'upload.
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

    /// Désactivation : purge tout l'état sync local (queue, tombstones, state
    /// moteur, system fields). Ne touche PAS aux données métier ni aux uuid.
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

    // MARK: - System fields CKRecord

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

    // MARK: - Sérialisation : row locale → payload JSON

    /// Payload JSON de la row, ou nil si la row n'existe plus (supprimée
    /// entre le queue et l'upload).
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
            if type == SQLITE_NULL { continue }   // NULL = absent du payload

            if let targetTable = fkMap[name] {
                // FK → uuid de la row cible. Cible sans uuid (impossible en
                // pratique après v40) ou disparue → FK omise (NULL en face).
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
                // Aucune colonne BLOB dans les tables synchronisées — encodage
                // base64 par sécurité si ça arrive un jour.
                if let blob = sqlite3_column_blob(stmt, i) {
                    values[name] = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, i))).base64EncodedString()
                }
            default: break
            }
        }

        var payload: [String: Any] = ["u": uuid, "t": updatedAt, "v": values]
        if !refs.isEmpty { payload["r"] = refs }

        // Liens tags embarqués dans le payload de la row propriétaire
        // (transactions et tricount_entries).
        if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == table }) {
            let tagUuids = Self.tagUuids(db, link: link, ownerId: localId)
            if !tagUuids.isEmpty { payload["g"] = tagUuids }
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Application : payload distant → row locale

    enum ApplyResult: Sendable {
        case applied
        case skippedLocalNewer   // LWW : la version locale gagne, elle est déjà en pending
        case failed
    }

    /// Tables portant une contrainte UNIQUE métier (hors uuid). Quand deux
    /// appareils créent indépendamment "la même" entité (tag 'vacances' des
    /// deux côtés, même trade Binance importé 2×), les uuids diffèrent et
    /// l'INSERT du record distant viole la contrainte. Résolution : ADOPTION —
    /// la row locale prend l'uuid distant (identités fusionnées, les FK int
    /// locales ne bougent pas), et l'ancien uuid part en tombstone pour
    /// nettoyer l'éventuel doublon déjà uploadé côté serveur.
    static let uniqueAdoptionKeys: [String: String] = [
        "tags": "name",                      // UNIQUE COLLATE NOCASE
        "investment_orders": "external_id",  // UNIQUE partiel (L.3)
        // ⚠️ Deux appareils qui créent « Projet » chacun de leur côté
        // produisent deux uuids pour la MÊME clé, et l'index UNIQUE sur `name`
        // fait échouer l'apply. L'adoption d'identité (min(uuid) gagne) les
        // fusionne au lieu de laisser un record en échec permanent.
        "transaction_metadata_keys": "name",  // UNIQUE COLLATE NOCASE (v46)
    ]

    /// Tables de référence où une collision par `name` (COLLATE NOCASE)
    /// signifie « la même entité » — fusion d'identités avant INSERT.
    /// Couvre le seed local vs données distantes (catégories, moyens de paiement).
    private static let nameAdoptionTables: Set<String> = [
        "categories",
        "payment_types",
    ]

    /// Applique un record distant. LE FLAG suppress_triggers DOIT ÊTRE POSÉ
    /// par l'appelant (batch-level, cf. CloudSyncEngine.applyBatch).
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

        // LWW : si la row locale est plus récente ou égale, on garde la locale
        // (elle est en sync_pending et repartira vers le serveur).
        var localId: Int64?
        if let (id, localUpdatedAt) = localRow(db, table: table, uuid: uuid) {
            if localUpdatedAt >= remoteUpdatedAt { return .skippedLocalNewer }
            localId = id
        }

        let columns = tableColumns(db, table: table)
        let values = (payload["v"] as? [String: Any]) ?? [:]
        let refs = (payload["r"] as? [String: String]) ?? [:]
        let fkMap = foreignKeys[table] ?? [:]

        // Assemble colonnes → valeurs à écrire (intersection avec le schéma
        // local : les colonnes d'une version plus récente de l'app sont
        // ignorées, les colonnes locales absentes du payload → NULL).
        var assignments: [(column: String, value: Any?)] = []
        // Vrai si au moins une FK du payload pointe une cible pas encore
        // arrivée. Si l'écriture échoue ensuite sur une contrainte (colonne
        // FK NOT NULL, ex : investment_orders.position_id), le payload est
        // DIFFÉRÉ au lieu d'être perdu (cf. sync_deferred_rows).
        var hadMissingRef = false
        for column in columns where column != "id" && column != "uuid" && column != "updated_at" {
            if let targetTable = fkMap[column] {
                if let targetUuid = refs[column] {
                    if let targetId = idForUuid(db, table: targetTable, uuid: targetUuid) {
                        assignments.append((column, targetId))
                    } else {
                        // Cible pas encore arrivée → NULL + ref en attente.
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
                // Échec probable : NULL sur une FK NOT NULL dont la cible
                // n'est pas arrivée → on garde le payload pour le rejouer.
                if hadMissingRef { storeDeferredRow(db, table: table, uuid: uuid, payload: payload) }
                return .failed
            }
        } else {
            // Fusion PROACTIVE par nom (categories, payment_types — tables de
            // référence SANS contrainte UNIQUE) : une row locale homonyme =
            // même entité. Sans ce check, le seed usine de deux appareils
            // coexisterait en DOUBLONS silencieux.
            //
            // ⚠️ Déterminisme anti ping-pong : le PLUS PETIT uuid gagne, sur
            // TOUS les appareils (sinon chaque côté adopte l'uuid de l'autre
            // et tombstone celui que l'autre vient d'adopter → perte de row).
            //   - remote < local → le local adopte l'uuid distant, ré-apply.
            //   - local <= remote → on n'insère PAS le doublon distant ; il
            //     sera tombstoné par l'appareil d'en face quand il recevra
            //     NOTRE record et adoptera notre uuid.
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
                // Violation d'unicité métier (tags.name, external_id…) →
                // adoption d'identité, même règle déterministe min(uuid).
                let isConstraint = (rc & 0xFF) == SQLITE_CONSTRAINT
                if isConstraint, allowAdoption,
                   let uniqueColumn = uniqueAdoptionKeys[table],
                   let uniqueValue = values[uniqueColumn],
                   let local = findRow(db, table: table, column: uniqueColumn, value: uniqueValue, caseInsensitive: false),
                   uuid < local.uuid,
                   adoptIdentity(db, table: table, localId: local.id, oldUuid: local.uuid, remoteUuid: uuid) {
                    // Ré-application : la row adoptée porte maintenant
                    // l'uuid distant → chemin UPDATE + LWW standard.
                    return apply(db, table: table, payload: payload, allowAdoption: false)
                }
                // FK NOT NULL dont la cible n'est pas encore descendue (les
                // batchs CloudKit n'ont pas d'ordre garanti) : le payload est
                // mis de côté et rejoué quand la cible arrive — sinon le
                // record serait PERDU définitivement (pas de re-livraison).
                if isConstraint, hadMissingRef {
                    storeDeferredRow(db, table: table, uuid: uuid, payload: payload)
                    return .failed
                }
                // Local uuid <= distant : record distant ignoré — il sera
                // tombstoné par l'appareil qui le porte (pas de retry : un
                // record fetché non appliqué ne revient que s'il re-change).
                return .failed
            }
        }

        // Liens tags de la row propriétaire : remplacement intégral.
        if let link = SyncSchema.tagLinks.first(where: { $0.ownerTable == table }),
           let ownerId = idForUuid(db, table: table, uuid: uuid) {
            let tagUuids = (payload["g"] as? [String]) ?? []
            rebuildTagLinks(db, link: link, ownerId: ownerId, ownerUuid: uuid, tagUuids: tagUuids)
        }

        return .applied
    }

    /// Row (id, uuid) portant `value` dans `column`, ou nil.
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

    /// Fusion d'identités : la row locale adopte l'uuid distant. Les PK/FK
    /// int locales ne changent pas ; l'ancien uuid est tombstoné pour
    /// supprimer le doublon éventuel côté serveur. L'appelant a DÉJÀ vérifié
    /// la règle déterministe (remoteUuid < oldUuid).
    private static func adoptIdentity(_ db: OpaquePointer, table: String,
                                      localId: Int64, oldUuid: String,
                                      remoteUuid: String) -> Bool {
        guard oldUuid != remoteUuid else { return false }
        guard execBind(db, "UPDATE \(table) SET uuid = ? WHERE id = \(localId);", values: [remoteUuid]) else { return false }
        // L'ancien uuid ne doit plus être uploadé…
        _ = execBind(db, "DELETE FROM sync_pending WHERE table_name = ? AND row_uuid = ?;", values: [table, oldUuid])
        _ = execBind(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", values: [table, oldUuid])
        // …et son record serveur (s'il a déjà été poussé) doit disparaître.
        _ = execBind(db, "INSERT OR REPLACE INTO sync_tombstones (table_name, row_uuid, deleted_at) VALUES (?, ?, \(nowSQL));",
                     values: [table, oldUuid])
        print("[SyncPayloadStore] Adoption \(table) : \(oldUuid) → \(remoteUuid)")
        return true
    }

    /// True si la row a une modification locale pas encore envoyée.
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

    /// Suppression distante. Suppose suppress_triggers posé par l'appelant.
    ///
    /// Règle delete-vs-update (L.2) : si la row locale porte une modification
    /// PENDING (éditée ici, pas encore envoyée), la suppression distante est
    /// IGNORÉE — une édition n'est jamais détruite par le delete d'un autre
    /// appareil. Notre save pending recréera le record côté serveur
    /// (.unknownItem → resurrection) et l'appareil qui a supprimé récupérera
    /// la row au prochain fetch. Si la row est "propre" (déjà synchronisée),
    /// la suppression s'applique : le delete est l'action la plus récente.
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
                print("[SyncPayloadStore] Delete distant ignoré (édition locale pending) : \(table)/\(uuid)")
                return
            }
        }

        // FK non enforced sur cette connexion (pragma foreign_keys OFF par
        // défaut) : nettoyage manuel des liens tags avant le DELETE.
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
        // Une row différée qui reçoit sa tombstone n'a plus lieu d'être rejouée.
        _ = execBind(db, "DELETE FROM sync_deferred_rows WHERE table_name = ? AND row_uuid = ?;", values: [table, uuid])
    }

    // MARK: - Application par batch (perf)

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

    /// Applique un batch CloudKit ENTIER dans UNE connexion + UNE transaction.
    ///
    /// Raison d'être (fix freezes Mac) : la version par-record ouvrait une
    /// connexion et une micro-transaction par row — sur la descente initiale
    /// (~6000 records), des milliers de cycles verrou/déverrou en rafale qui
    /// affamaient les lectures UI (aucun busy_timeout côté repos). Ici :
    /// 1 BEGIN IMMEDIATE … COMMIT court par batch (~200 records CloudKit).
    ///
    /// Le flag suppress_triggers est posé/retiré DANS la transaction : les
    /// triggers (même connexion) le voient immédiatement, et il n'est jamais
    /// visible des autres connexions — la fenêtre "écriture app concurrente
    /// non trackée" de l'ancienne version disparaît.
    func applyRemoteBatch(modifications: [RemoteModification], deletions: [RemoteDeletion]) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('suppress_triggers', '1');", values: [])

        // Référencées d'abord (ordre de tableOrder) : un batch contenant à la
        // fois comptes, positions et ordres s'applique dans le bon sens — la
        // plupart des FK NOT NULL se résolvent inline, sans passer par la
        // file des différés (qui couvre le cas inter-batchs).
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
                // Dans les 2 cas on retient les system fields : la prochaine
                // save locale doit repartir de la version serveur courante.
                _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_record_meta (table_name, row_uuid, system_fields) VALUES (?, ?, ?);",
                                  values: [mod.table, mod.uuid, mod.systemFields])
            case .failed:
                // Si apply() vient de DIFFÉRER le record (FK NOT NULL dont la
                // cible manque), on attache ses system fields : le rejeu devra
                // repartir de la version serveur courante lui aussi.
                _ = Self.execBind(db, "UPDATE sync_deferred_rows SET system_fields = ? WHERE table_name = ? AND row_uuid = ?;",
                                  values: [mod.systemFields, mod.table, mod.uuid])
                print("[SyncPayloadStore] Application échouée : \(mod.table)/\(mod.uuid)")
            }
        }

        for del in deletions {
            guard Self.tableOrder.contains(del.table) else { continue }
            Self.deleteRemoteRow(db, table: del.table, uuid: del.uuid)
            _ = Self.execBind(db, "DELETE FROM sync_record_meta WHERE table_name = ? AND row_uuid = ?;", values: [del.table, del.uuid])
            _ = Self.execBind(db, "DELETE FROM sync_tombstones WHERE table_name = ? AND row_uuid = ?;", values: [del.table, del.uuid])
        }

        // Les FK dont la cible vient d'arriver dans ce batch.
        Self.resolveUnresolvedRefs(db)

        // Les records DIFFÉRÉS (FK NOT NULL) dont les cibles existent
        // désormais : ordres qui attendaient leurs positions, positions qui
        // attendaient leur compte…
        Self.applyDeferredRows(db)

        _ = Self.execBind(db, "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('suppress_triggers', '0');", values: [])
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Re-tente la résolution des FK en attente (cibles arrivées dans un batch
    /// ultérieur). Appelé après chaque batch appliqué, suppress posé.
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
                // Lien tag en attente — la table de lien dépend du propriétaire.
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

    // MARK: - Records différés (FK NOT NULL en attente de cible)

    /// Met de côté un payload distant refusé parce qu'une FK NOT NULL n'est
    /// pas encore résoluble. `INSERT OR REPLACE` : re-différer la même row
    /// écrase l'entrée (le payload le plus récent gagne).
    private static func storeDeferredRow(_ db: OpaquePointer, table: String,
                                         uuid: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = execBind(db, """
            INSERT OR REPLACE INTO sync_deferred_rows (table_name, row_uuid, payload, queued_at)
            VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
            """, values: [table, uuid, data])
    }

    /// Rejoue les payloads différés. Boucle jusqu'à stabilité (appliquer une
    /// row peut en débloquer d'autres : compte → position → ordre), cap de
    /// sécurité à 5 passes. Une row toujours bloquée est re-différée par
    /// apply() et retentera au prochain batch.
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

            // Référencées d'abord, comme les batchs.
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
                // Retirer AVANT le ré-apply : si la cible manque toujours,
                // apply() ré-écrit l'entrée ; sinon elle est soldée.
                _ = execBind(db, "DELETE FROM sync_deferred_rows WHERE table_name = ? AND row_uuid = ?;", values: [row.table, row.uuid])
                switch apply(db, table: row.table, payload: payload, allowAdoption: true) {
                case .applied, .skippedLocalNewer:
                    progressed = true
                    if let sf = row.systemFields {
                        _ = execBind(db, "INSERT OR REPLACE INTO sync_record_meta (table_name, row_uuid, system_fields) VALUES (?, ?, ?);",
                                     values: [row.table, row.uuid, sf])
                    }
                case .failed:
                    // Re-différée par apply() si FK toujours manquante :
                    // ré-attacher les system fields (storeDeferredRow ne les
                    // connaît pas).
                    if let sf = row.systemFields {
                        _ = execBind(db, "UPDATE sync_deferred_rows SET system_fields = ? WHERE table_name = ? AND row_uuid = ?;",
                                     values: [sf, row.table, row.uuid])
                    }
                }
            }
            if !progressed { return }
        }
    }

    /// Variante hors batch (tests, réparations) : ouvre sa propre connexion.
    func retryDeferredRows() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        Self.applyDeferredRows(db)
    }

    // MARK: - Helpers privés

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Supprime une row seed par nom si elle n'est référencée nulle part.
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
                // Tag pas encore arrivé → lien en attente (résolu post-batch).
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

    /// Exécute un statement avec binds hétérogènes (String / Int64 / Double / nil).
    private static func execBind(_ db: OpaquePointer, _ sql: String, values: [Any?]) -> Bool {
        let rc = execBindRC(db, sql, values: values)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// Variante qui expose le code résultat SQLite brut — nécessaire pour
    /// discriminer une violation de contrainte (adoption d'identité) d'une
    /// vraie erreur. `(rc & 0xFF) == SQLITE_CONSTRAINT` couvre les codes
    /// étendus (SQLITE_CONSTRAINT_UNIQUE = 2067, etc.).
    private static func execBindRC(_ db: OpaquePointer, _ sql: String, values: [Any?]) -> Int32 {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            print("[SyncPayloadStore] prepare KO : \(String(cString: sqlite3_errmsg(db)))")
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
                // JSONSerialization produit des NSNumber : discrimine int/double.
                if CFNumberIsFloatType(v) { sqlite3_bind_double(stmt, idx, v.doubleValue) }
                else { sqlite3_bind_int64(stmt, idx, v.int64Value) }
            case let v as Data:
                // BLOB (payloads différés, system fields CKRecord). Sans ce
                // case, Data tombait dans `default:` → bindé NULL en silence
                // (les system_fields du chemin batch n'étaient JAMAIS stockés).
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
            print("[SyncPayloadStore] step KO : \(String(cString: sqlite3_errmsg(db)))")
        }
        return rc
    }
}
