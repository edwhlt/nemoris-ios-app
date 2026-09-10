import Foundation
import SQLite3

/// Encrypted CloudKit sync — SQLite instrumentation layer.
///
/// This component provides the dirty-tracking foundation required by
/// CKSyncEngine-based synchronization:
///
///   • `uuid`        : stable cross-device identity for each row (the INTEGER
///                     AUTOINCREMENT values remain local PKs and FKs — they
///                     NEVER leave the device).
///   • `updated_at`  : ISO8601 UTC timestamp of the last modification, used
///                     for last-writer-wins conflict resolution.
///   • `sync_pending`    : queue of locally modified rows to upload.
///   • `sync_tombstones` : deletions to propagate (a local DELETE isn't
///                     enough — the server must be told "this row no longer exists").
///   • `sync_meta`       : internal key/value store (suppress_triggers flag,
///                     and later the serialized CKSyncEngine state, tokens, etc.).
///
/// Tracking is done via SQLite TRIGGERS (not the repository layer): every
/// write is captured, including the SQL console and import batches. Triggers
/// are (re)installed on every boot by `installTriggers` — they are NOT part
/// of the migrations and can therefore evolve freely.
///
/// ⚠️ The remote-change applier must set `sync_meta['suppress_triggers'] = '1'`
/// before writing rows that came from the server, then reset it to '0' —
/// otherwise every downstream sync would mark those rows as dirty again,
/// creating an upload/download echo loop.
///
/// ⚠️ The `trg_sync_*_update` triggers assume `PRAGMA recursive_triggers` is
/// OFF (SQLite's default, never changed in the app): the `updated_at` UPDATE
/// inside the trigger body must not re-trigger itself.
enum SyncSchema {

    /// SQL expression for the current timestamp (ISO8601 UTC, ms precision).
    /// Format is lexicographically comparable: "2026-07-16T14:03:21.417Z".
    private static let nowSQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    /// Shared guard: triggers are inert while the remote-change applier has
    /// set the suppress_triggers flag.
    private static let guardSQL =
        "COALESCE((SELECT value FROM sync_meta WHERE key = 'suppress_triggers'), '0') <> '1'"

    /// Synced tables — ALL of them have `id INTEGER PRIMARY KEY AUTOINCREMENT`.
    /// Composite-PK link tables (`transaction_tags`, `tricount_entry_tags`)
    /// are handled separately via `tagLinks`: the links are embedded in the
    /// owning row's JSON payload (field "g"), and their triggers mark the
    /// owning row dirty.
    ///
    /// ⚠️ ORDER MATTERS: referenced tables before referencing tables — this
    /// is the order remote batches are applied in (minimizes unresolved
    /// FKs). `SyncPayloadStore.tableOrder` points at this list.
    ///
    /// Deliberately NEVER synced: `investment_live_sync` + Keychain
    /// credentials (by design), `currency_rates` (re-fetchable cache),
    /// `csv_mappings` / `import_sessions` (local device workflow state),
    /// `pending_apple_pay_entries` (per-device Shortcuts staging buffer — each
    /// device gets its own Apple Pay notifications, nothing to reconcile
    /// across devices), disk caches (out of the DB entirely).
    static let syncedTables: [String] = [
        // — Core ledger
        "accounts",
        "payment_types",
        "categories",
        "payee_groups",
        "tags",
        "payees",
        "transactions",
        // — Budget
        "recurring_patterns",
        "budget_envelopes",
        "budget_previsions",
        // — Investments
        "investment_accounts",
        "investment_positions",
        "investment_orders",
        // — Real estate / assets
        "patrimoine_real_estate",
        "patrimoine_loans",
        "patrimoine_assets",
        // — Goals
        "goals",
        // — Tricount (shared expenses)
        "tricount_groups",
        "tricount_entries",
        "tricount_shares",
        // — Unified reimbursements — replaces tricount_reimbursements
        "reimbursements",
        // — Free-form transaction metadata — replaces payment_type_id
        // ⚠️ Keys BEFORE values: the latter reference the former.
        "transaction_metadata_keys",
        "transaction_metadata_values",
        // — AI coach: ONLY the objectives the user authored. The analyses and
        // the recommendations they produce are DERIVED (regenerable from the
        // ledger at any time), so they stay local — same reasoning as
        // `import_sessions` / `csv_mappings`.
        "coach_profile",
    ]

    /// Tables added by migration v42 — NEVER MODIFY after ship (migration
    /// v42 iterates this exact list; adding a table means a new list + a new
    /// migration).
    static let secondaryTablesV42: [String] = [
        "recurring_patterns", "budget_envelopes", "budget_previsions",
        "investment_accounts", "investment_positions", "investment_orders",
        "patrimoine_real_estate", "patrimoine_loans", "patrimoine_assets",
        "goals",
        "tricount_groups", "tricount_entries", "tricount_shares", "tricount_reimbursements",
    ]

    /// Tag link tables (composite PK): no CloudKit records of their own,
    /// links are embedded in the owning row's "g" payload field.
    struct TagLink {
        let linkTable: String
        let ownerTable: String
        let ownerFK: String
    }

    static let tagLinks: [TagLink] = [
        TagLink(linkTable: "transaction_tags", ownerTable: "transactions", ownerFK: "transaction_id"),
        TagLink(linkTable: "tricount_entry_tags", ownerTable: "tricount_entries", ownerFK: "entry_id"),
    ]

    // MARK: - Migration statements

    /// Statements that add the sync columns for a table.
    ///
    /// ⚠️ Migration v40 depends on this function's output for the 7 core
    /// tables: NEVER change its output for a given input (an existing
    /// migration must never be modified). For a change in strategy, write a
    /// new, separately versioned function.
    static func columnStatements(table t: String) -> [String] {
        [
            "ALTER TABLE \(t) ADD COLUMN uuid TEXT;",
            "ALTER TABLE \(t) ADD COLUMN updated_at TEXT;",
            "UPDATE \(t) SET uuid = lower(hex(randomblob(16))) WHERE uuid IS NULL;",
            "UPDATE \(t) SET updated_at = \(nowSQL) WHERE updated_at IS NULL;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_\(t)_uuid ON \(t)(uuid);",
        ]
    }

    /// CKSyncEngine state tables (created by migration v41 — DDL replicated
    /// here as an idempotent CREATE IF NOT EXISTS for the NemorisApp/Tests/
    /// harness, since the shipped migration must no longer be modified).
    static let engineStateStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_record_meta (
            table_name    TEXT NOT NULL,
            row_uuid      TEXT NOT NULL,
            system_fields BLOB NOT NULL,
            PRIMARY KEY (table_name, row_uuid)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_unresolved_refs (
            table_name   TEXT NOT NULL,
            row_uuid     TEXT NOT NULL,
            column_name  TEXT NOT NULL,
            target_table TEXT NOT NULL,
            target_uuid  TEXT NOT NULL,
            PRIMARY KEY (table_name, row_uuid, column_name)
        );
        """,
    ]

    /// Sync infrastructure tables (created by migration v40).
    static let infrastructureStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_pending (
            table_name TEXT NOT NULL,
            row_uuid   TEXT NOT NULL,
            queued_at  TEXT NOT NULL,
            PRIMARY KEY (table_name, row_uuid)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_tombstones (
            table_name TEXT NOT NULL,
            row_uuid   TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            PRIMARY KEY (table_name, row_uuid)
        );
        """,
    ]

    // MARK: - Triggers

    /// (Re)installs all dirty-tracking triggers. Called at the end of
    /// `DatabaseManager.migrateIfNeeded()` — only if user_version >= 40 (the
    /// uuid/updated_at columns must exist).
    ///
    /// Systematic DROP + CREATE: idempotent, and lets the trigger bodies
    /// evolve without a migration.
    /// v43 — queue for DEFERRED remote payloads: records whose NOT NULL FK
    /// isn't resolvable yet (target hasn't arrived — CloudKit batches carry
    /// no ordering guarantee). Without this, the INSERT would violate the
    /// constraint and the record would be LOST for good (a fetched record
    /// that fails to apply is never re-delivered).
    /// ⚠️ Used by migration v43: never change its output.
    static let deferredRowsDDL: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_deferred_rows (
            table_name    TEXT NOT NULL,
            row_uuid      TEXT NOT NULL,
            payload       BLOB NOT NULL,
            system_fields BLOB,
            queued_at     TEXT NOT NULL,
            PRIMARY KEY (table_name, row_uuid)
        );
        """,
    ]

    static func installTriggers(_ db: OpaquePointer) {
        var statements: [String] = []
        // Existence guard: a device whose migration v42 failed (version
        // stuck at 40/41) must not generate trigger errors on tables that
        // aren't instrumented yet; the same guard also covers the test
        // harness, which only creates a subset of the schema.
        for t in syncedTables where tableExists(db, t) {
            statements += triggerStatements(table: t)
        }
        for link in tagLinks where tableExists(db, link.linkTable) && tableExists(db, link.ownerTable) {
            statements += tagLinkTriggerStatements(link)
        }

        for sql in statements {
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK, let msg = errmsg {
                print("[SyncSchema] Erreur trigger : \(String(cString: msg))")
                sqlite3_free(errmsg)
            }
        }
    }

    static func tableExists(_ db: OpaquePointer, _ table: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table)';", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Standard triggers for a table with PK `id`.
    ///
    /// ⚠️ Queuing into `sync_pending` is done via DELETE then INSERT, and
    /// specifically NOT via `INSERT OR REPLACE`.
    ///
    /// SQLite documents that when the statement that fires the trigger
    /// itself carries an `ON CONFLICT` clause, that outer statement's
    /// conflict-resolution policy REPLACES the one written in the trigger
    /// body. An `INSERT OR REPLACE` inside the trigger therefore loses its
    /// `OR REPLACE` and fails on `sync_pending`'s uniqueness constraint
    /// whenever the outer statement is a plain UPSERT.
    ///
    /// DELETE then INSERT implies no conflict resolution of its own, so
    /// there is nothing for the outer statement to override.
    private static func triggerStatements(table t: String) -> [String] {
        [
            "DROP TRIGGER IF EXISTS trg_sync_\(t)_insert;",
            """
            CREATE TRIGGER trg_sync_\(t)_insert AFTER INSERT ON \(t)
            WHEN \(guardSQL)
            BEGIN
                UPDATE \(t)
                   SET uuid       = COALESCE(uuid, lower(hex(randomblob(16)))),
                       updated_at = COALESCE(updated_at, \(nowSQL))
                 WHERE id = NEW.id;
                DELETE FROM sync_pending
                 WHERE table_name = '\(t)'
                   AND row_uuid = (SELECT uuid FROM \(t) WHERE id = NEW.id);
                INSERT INTO sync_pending (table_name, row_uuid, queued_at)
                SELECT '\(t)', uuid, \(nowSQL) FROM \(t) WHERE id = NEW.id;
            END;
            """,

            "DROP TRIGGER IF EXISTS trg_sync_\(t)_update;",
            """
            CREATE TRIGGER trg_sync_\(t)_update AFTER UPDATE ON \(t)
            WHEN \(guardSQL)
            BEGIN
                UPDATE \(t) SET updated_at = \(nowSQL) WHERE id = NEW.id;
                DELETE FROM sync_pending
                 WHERE table_name = '\(t)' AND row_uuid = NEW.uuid;
                INSERT INTO sync_pending (table_name, row_uuid, queued_at)
                SELECT '\(t)', NEW.uuid, \(nowSQL) WHERE NEW.uuid IS NOT NULL;
            END;
            """,

            "DROP TRIGGER IF EXISTS trg_sync_\(t)_delete;",
            """
            CREATE TRIGGER trg_sync_\(t)_delete AFTER DELETE ON \(t)
            WHEN \(guardSQL)
            BEGIN
                DELETE FROM sync_pending WHERE table_name = '\(t)' AND row_uuid = OLD.uuid;
                INSERT OR REPLACE INTO sync_tombstones (table_name, row_uuid, deleted_at)
                SELECT '\(t)', OLD.uuid, \(nowSQL) WHERE OLD.uuid IS NOT NULL;
            END;
            """,
        ]
    }

    /// Tag link tables: no CloudKit records of their own — a link change
    /// bumps the owning row's `updated_at`, which fires its own update
    /// trigger (queuing + timestamping in a single place).
    /// On a CASCADE DELETE (owner deleted), the UPDATE matches no row →
    /// no-op, the owner's tombstone is sufficient on its own.
    private static func tagLinkTriggerStatements(_ link: TagLink) -> [String] {
        [
            "DROP TRIGGER IF EXISTS trg_sync_\(link.linkTable)_insert;",
            """
            CREATE TRIGGER trg_sync_\(link.linkTable)_insert AFTER INSERT ON \(link.linkTable)
            WHEN \(guardSQL)
            BEGIN
                UPDATE \(link.ownerTable) SET updated_at = \(nowSQL) WHERE id = NEW.\(link.ownerFK);
            END;
            """,

            "DROP TRIGGER IF EXISTS trg_sync_\(link.linkTable)_delete;",
            """
            CREATE TRIGGER trg_sync_\(link.linkTable)_delete AFTER DELETE ON \(link.linkTable)
            WHEN \(guardSQL)
            BEGIN
                UPDATE \(link.ownerTable) SET updated_at = \(nowSQL) WHERE id = OLD.\(link.ownerFK);
            END;
            """,
        ]
    }

    // MARK: - Default reference data (DatabaseManager seed)

    /// Category names inserted by `seedNewDatabase()`. Used to purge
    /// duplicates before the first CloudKit activation on a fresh device
    /// (Mac/iPhone), and for name-based merging on receipt.
    static let defaultSeedCategoryNames: Set<String> = [
        "Alimentation", "Transport", "Logement", "Santé", "Loisirs & Culture",
        "Vêtements & Shopping", "Voyages", "Revenus", "Banque & Finance",
        "Supermarché", "Restaurant & Bar", "Carburant", "Transport en commun",
        "Loyer & Charges", "Internet & Téléphone", "Énergie", "Médecin",
        "Pharmacie", "Cinéma & Spectacles", "Sport", "Abonnements", "Salaire",
        "Remboursements reçus",
    ]

    /// Payment method names inserted by `seedNewDatabase()`.
    static let defaultSeedPaymentTypeNames: Set<String> = [
        "Carte bancaire", "Virement", "Prélèvement", "Espèces", "Chèque", "AUTRE",
    ]
}
