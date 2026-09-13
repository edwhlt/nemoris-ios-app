import Foundation
import SQLite3

enum DatabaseLinkError: LocalizedError {
    case invalidSourceFile
    case notReadable(String)
    case createFailed

    var errorDescription: String? {
        switch self {
        case .invalidSourceFile:
            return "Le fichier sélectionné n'est pas un fichier .sqlite valide."
        case .notReadable(let reason):
            return "Fichier inaccessible : \(reason)"
        case .createFailed:
            return "Impossible de créer la base de données."
        }
    }
}

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private let fallbackFileName = "finance.sqlite"

    private init() {
        migrateIfNeeded()
    }

    // MARK: - Public API

    func hasDatabase() -> Bool {
        FileManager.default.fileExists(atPath: fallbackURL().path)
    }

    /// Kept for compatibility with existing repository callers.
    func hasDatabaseCopy() -> Bool { hasDatabase() }

    func sqliteURL() -> URL {
        fallbackURL()
    }

    /// Number of transactions in the database (0 if the database is absent,
    /// the table is missing, or on error). Used by `BackupService`'s
    /// auto-backup guard to avoid snapshotting an empty database — otherwise
    /// a near-empty backup would occupy a slot in the rotation of 30 and
    /// push a real snapshot out.
    func transactionCount() -> Int {
        guard hasDatabase() else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transactions;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Imports an external SQLite file by copying it into the app sandbox, then runs migrations.
    func linkExternalFile(from pickerURL: URL) throws {
        guard pickerURL.pathExtension.lowercased() == "sqlite" else {
            throw DatabaseLinkError.invalidSourceFile
        }

        _ = pickerURL.startAccessingSecurityScopedResource()
        defer { pickerURL.stopAccessingSecurityScopedResource() }

        // Verify it's a valid SQLite file
        var testDB: OpaquePointer?
        let openResult = sqlite3_open_v2(pickerURL.path, &testDB, SQLITE_OPEN_READONLY, nil)
        sqlite3_close(testDB)
        guard openResult == SQLITE_OK else {
            throw DatabaseLinkError.notReadable(String(cString: sqlite3_errstr(openResult)))
        }

        // Copy into the app sandbox (overwrite any existing copy)
        let dest = fallbackURL()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: pickerURL, to: dest)
        // `copyItem` preserves the SOURCE's permission bits — if the picked
        // file happened to be read-only (common for files synced down from
        // some cloud providers), the live database would come out read-only
        // and every write would silently fail from here on.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)

        migrateIfNeeded()
    }

    /// Creates a brand-new empty SQLite database at the fallback path, runs all migrations, and optionally seeds default data.
    /// Pass `seedDefaults: false` when this device will join an existing
    /// iCloud vault (avoids duplicate categories / payment types before the
    /// first sync).
    func createNewDatabase(seedDefaults: Bool = true) throws {
        let url = fallbackURL()
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw DatabaseLinkError.createFailed
        }
        sqlite3_close(db)
        migrateIfNeeded()
        if seedDefaults {
            seedNewDatabase()
        }
    }

    /// Inserts the default reference data into a blank database.
    /// Uses INSERT OR IGNORE to avoid overwriting existing data.
    func seedNewDatabase() {
        guard hasDatabase() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let seeds: [String] = [
            // Parent categories
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (1,  'Alimentation',          'cart.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (2,  'Transport',             'car.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (3,  'Logement',              'house.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (4,  'Santé',                 'heart.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (5,  'Loisirs & Culture',     'gamecontroller.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (6,  'Vêtements & Shopping',  'bag.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (7,  'Voyages',               'airplane');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (8,  'Revenus',               'banknote.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (9,  'Banque & Finance',      'building.columns.fill');",
            // Subcategories
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (10, 'Supermarché',          1, 'cart.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (11, 'Restaurant & Bar',     1, 'fork.knife');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (12, 'Carburant',            2, 'fuelpump.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (13, 'Transport en commun',  2, 'tram.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (14, 'Loyer & Charges',      3, 'key.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (15, 'Internet & Téléphone', 3, 'wifi');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (16, 'Énergie',              3, 'bolt.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (17, 'Médecin',              4, 'stethoscope');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (18, 'Pharmacie',            4, 'pills.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (19, 'Cinéma & Spectacles',  5, 'film.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (20, 'Sport',                5, 'figure.run');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (21, 'Abonnements',          5, 'repeat');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (22, 'Salaire',              8, 'banknote.fill');",
            "INSERT OR IGNORE INTO categories (id, name, parent_id, icon) VALUES (23, 'Remboursements reçus', 8, 'arrow.uturn.left.circle.fill');",
            // Payment methods are NOT seeded here.
            //
            // "Payment method" is no longer a first-class concept: it became
            // one free-form metadata key among others. A NEW database
            // therefore has no trace of it — the user creates whichever keys
            // they need ("Payment method", "Project", "Work / Personal"…),
            // or none at all.
            //
            // Only EXISTING databases keep the "Payment method" key, recreated
            // identically by the migration from their own data. The
            // `payment_types` table is still created (deprecated, not
            // dropped), simply left empty.
        ]

        for sql in seeds {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - Migrations
    //
    // Each migration is identified by a version number (1, 2, 3…). SQLite
    // stores the current version in PRAGMA user_version. migrateIfNeeded()
    // only applies migrations whose number is > user_version, in order,
    // atomically (BEGIN/COMMIT per migration).
    //
    // To add a migration: append an entry to the end of `migrations` and
    // increment the number. Never modify an existing migration.

    @discardableResult
    func migrateIfNeeded() -> String? {
        guard hasDatabase() else { return "Aucune base de données" }
        return Self.migrate(at: sqliteURL())
    }

    /// Applies the migration chain to an arbitrary database.
    ///
    /// Static and parameterized by URL so tests can build a database with
    /// the current schema in a temporary directory, without touching the
    /// app's own database or instantiating the singleton. Returns `nil` on
    /// success, otherwise the concatenated errors.
    @discardableResult
    static func migrate(at url: URL) -> String? {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let db else {
            let msg = "Impossible d'ouvrir la base en écriture : \(String(cString: sqlite3_errstr(openResult)))"
            sqlite3_close(db)
            return msg
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let currentVersion = Self.userVersion(db)
        var errors: [String] = []

        for migration in Self.migrations where migration.version > currentVersion {
            var stmtErrors: [String] = []

            func exec(_ sql: String, tolerateDuplicateColumn: Bool = false) {
                var errmsg: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
                if rc != SQLITE_OK, let msg = errmsg {
                    let errStr = String(cString: msg)
                    sqlite3_free(errmsg)
                    let upper = sql.uppercased()
                    // ALTER TABLE ADD COLUMN: ignore if the column already exists.
                    if tolerateDuplicateColumn && errStr.localizedCaseInsensitiveContains("duplicate column name") {
                        return
                    }
                    // ALTER TABLE RENAME COLUMN: ignore if the source column
                    // no longer exists (migration already partially applied)
                    // or the destination already exists.
                    if upper.contains("RENAME COLUMN") &&
                        (errStr.localizedCaseInsensitiveContains("no such column") ||
                         errStr.localizedCaseInsensitiveContains("duplicate column name")) {
                        return
                    }
                    // ALTER TABLE RENAME TO: ignore if the destination table
                    // already exists (already renamed by a prior partial run).
                    if upper.contains("RENAME TO") &&
                        errStr.localizedCaseInsensitiveContains("already exists") {
                        return
                    }
                    stmtErrors.append(errStr)
                }
            }

            exec("BEGIN;")
            migration.statements.forEach { exec($0, tolerateDuplicateColumn: $0.uppercased().hasPrefix("ALTER TABLE")) }

            if stmtErrors.isEmpty {
                exec("PRAGMA user_version = \(migration.version);")
                exec("COMMIT;")
            } else {
                exec("ROLLBACK;")
                errors.append("Migration v\(migration.version) : \(stmtErrors.joined(separator: " | "))")
                break   // stop at the first migration that fails
            }
        }

        // CloudKit sync: (re)install the dirty-tracking triggers. Kept
        // outside the migration chain so they can evolve freely (idempotent
        // DROP + CREATE). Requires the uuid/updated_at columns (migration v40).
        if Self.userVersion(db) >= 40 {
            SyncSchema.installTriggers(db)
        }

        // One-shot repair: merges categories/payment_types duplicates
        // created by early sync activations, before deterministic identity
        // adoption existed. Runs AFTER installTriggers and OUTSIDE the
        // suppress window: the DELETEs become tombstones, so the merge
        // propagates to other devices.
        if Self.userVersion(db) >= 42, SyncPayloadStore.metaValue(db, "ref_dedup_v1_done") != "1" {
            let merged = SyncPayloadStore.dedupReferenceDuplicates(db)
            SyncPayloadStore.setMeta(db, "ref_dedup_v1_done", "1")
            if merged > 0 {
                print("[DatabaseManager] Merged reference duplicates: \(merged)")
            }
        }

        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    // MARK: - Schema drift detection

    /// Result of comparing a candidate database's TABLE structure against a
    /// pristine, migrations-only reference. Row DATA is never inspected —
    /// only `CREATE TABLE` text.
    enum SchemaDriftResult: Equatable {
        case clean
        case drifted(missingTables: [String], extraTables: [String], changedTables: [String])
        /// The comparison itself couldn't run (unreadable file, migration
        /// failure…) — treated as non-blocking by callers, since refusing a
        /// restore over an inconclusive check would be worse than the risk
        /// it's meant to catch.
        case inconclusive(reason: String)
    }

    /// Migrates the database at `url` in place, then compares its resulting
    /// table structure against a freshly-built reference database (pure
    /// migration chain, no legacy data) at the SAME final version. A
    /// mismatch means some table was created/altered/dropped OUTSIDE the
    /// versioned migration chain — e.g. by hand via the SQL console — which
    /// the app has no guarantee of handling correctly.
    ///
    /// ⚠️ `url` is mutated (migrated) by this call — callers MUST pass a
    /// disposable scratch copy, never the live database or an original
    /// backup file.
    static func detectSchemaDrift(at url: URL) -> SchemaDriftResult {
        if let migrationError = migrate(at: url) {
            return .inconclusive(reason: migrationError)
        }
        guard let candidateSchema = schemaFingerprint(at: url) else {
            return .inconclusive(reason: "Lecture du schéma du fichier impossible.")
        }

        let refURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemoris-schema-ref-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: refURL) }
        guard createEmptyDatabase(at: refURL), migrate(at: refURL) == nil,
              let referenceSchema = schemaFingerprint(at: refURL)
        else {
            return .inconclusive(reason: "Construction du schéma de référence impossible.")
        }

        if candidateSchema == referenceSchema { return .clean }

        let missing = Set(referenceSchema.keys).subtracting(candidateSchema.keys).sorted()
        let extra   = Set(candidateSchema.keys).subtracting(referenceSchema.keys).sorted()
        let changed = referenceSchema.keys
            .filter { candidateSchema[$0] != nil && candidateSchema[$0] != referenceSchema[$0] }
            .sorted()
        return .drifted(missingTables: missing, extraTables: extra, changedTables: changed)
    }

    @discardableResult
    private static func createEmptyDatabase(at url: URL) -> Bool {
        var db: OpaquePointer?
        let ok = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        sqlite3_close(db)
        return ok
    }

    /// Table name → normalized `CREATE TABLE` text. Indexes/triggers are
    /// deliberately excluded: triggers are reinstalled fresh on every boot
    /// regardless of the migration chain (`SyncSchema.installTriggers`), and
    /// an index is a performance detail, not a structural risk — including
    /// either would produce false positives unrelated to "will the app work
    /// with this file".
    private static func schemaFingerprint(at url: URL) -> [String: String]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)
            let ddl = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            result[name] = normalizeDDL(ddl)
        }
        return result
    }

    /// Strips comments, then collapses whitespace/newlines and lowercases —
    /// SQLite echoes back `CREATE TABLE` text close to verbatim, comments
    /// included. Without stripping them first, a purely cosmetic edit to a
    /// comment INSIDE a migration's SQL string (e.g. a FR→EN wording pass)
    /// makes an unchanged table look "modified" — caught for real on
    /// `transaction_metadata_keys` (v46) right after such a pass: byte-for-
    /// byte identical columns/types/order, only the comment text differed.
    private static func normalizeDDL(_ sql: String) -> String {
        stripSQLComments(sql)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Removes `-- line` and `/* block */` SQL comments, respecting single-
    /// quoted string literals (so a `--`/`/*` inside a quoted default value
    /// is never mistaken for a comment start). Migration SQL is first-party
    /// and trusted, so this doesn't need to handle escaped quotes beyond
    /// SQL's own `''` doubling.
    private static func stripSQLComments(_ sql: String) -> String {
        var result = ""
        result.reserveCapacity(sql.count)
        let chars = Array(sql)
        var i = 0
        var inSingleQuote = false
        while i < chars.count {
            let c = chars[i]
            if inSingleQuote {
                result.append(c)
                if c == "'" { inSingleQuote = false }
                i += 1
                continue
            }
            if c == "'" {
                inSingleQuote = true
                result.append(c)
                i += 1
                continue
            }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                i += 2
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// Current schema version (0 = blank or pre-versioned database).
    var schemaVersion: Int {
        guard hasDatabase() else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return Self.userVersion(db)
    }

    // MARK: - Migration list

    /// Internal rather than private so tests can verify the chain's
    /// CONSISTENCY: unique and increasing version numbers, no empty
    /// migration. Two migrations sharing the same number never show up in
    /// development — the second one simply doesn't apply on a device that
    /// already passed the first, so the bug only surfaces for existing
    /// users. `DatabaseManager` being internal to the module, nothing is
    /// exposed beyond that.
    struct Migration {
        let version: Int
        let statements: [String]
    }

    static let migrations: [Migration] = [

        // v1 — base tables (compatible with existing JavaApp databases)
        Migration(version: 1, statements: [
            "CREATE TABLE IF NOT EXISTS comptes (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);",
            "CREATE TABLE IF NOT EXISTS category (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);",
            "CREATE TABLE IF NOT EXISTS tiers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, cm_name TEXT);",
            "CREATE TABLE IF NOT EXISTS mdp (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, cm_name TEXT);",
            """
            CREATE TABLE IF NOT EXISTS transactions (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                comptes_id   INTEGER REFERENCES comptes(id),
                tiers_id     INTEGER REFERENCES tiers(id),
                categorie_id INTEGER REFERENCES category(id),
                mdp_id       INTEGER REFERENCES mdp(id),
                information  TEXT,
                montant      REAL,
                date_op      TEXT
            );
            """,
        ]),

        // v2 — Tricount
        Migration(version: 2, statements: [
            """
            CREATE TABLE IF NOT EXISTS tricount_groups (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                tricount_key TEXT NOT NULL,
                title        TEXT NOT NULL,
                currency     TEXT DEFAULT 'EUR',
                my_name      TEXT NOT NULL,
                fetched_at   TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS tricount_entries (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                group_id          INTEGER NOT NULL REFERENCES tricount_groups(id) ON DELETE CASCADE,
                source_entry_uuid TEXT,
                source_updated_at TEXT,
                type_transaction  TEXT NOT NULL DEFAULT 'NORMAL',
                who_paid          TEXT NOT NULL,
                total             REAL NOT NULL,
                currency          TEXT NOT NULL DEFAULT 'EUR',
                local_total       REAL,
                local_currency    TEXT,
                description       TEXT DEFAULT '',
                date              TEXT NOT NULL,
                category          TEXT DEFAULT '',
                user_category_id  INTEGER,
                linked_transaction_id INTEGER REFERENCES transactions(id)
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tricount_entries_group_source_uuid ON tricount_entries(group_id, source_entry_uuid);",
            """
            CREATE TABLE IF NOT EXISTS tricount_shares (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id    INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                member_name TEXT NOT NULL,
                amount      REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS tricount_reimbursements (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                tiers_id INTEGER NOT NULL REFERENCES tiers(id),
                amount   REAL NOT NULL,
                currency TEXT NOT NULL DEFAULT 'EUR'
            );
            """,
            "ALTER TABLE transactions ADD COLUMN remboursement INTEGER REFERENCES tiers(id);",
            "ALTER TABLE tiers ADD COLUMN category_id INTEGER DEFAULT 40;",
        ]),

        // v3 — hierarchical categories
        Migration(version: 3, statements: [
            "ALTER TABLE category ADD COLUMN parent_id INTEGER REFERENCES category(id);",
            "CREATE INDEX IF NOT EXISTS idx_category_parent ON category(parent_id);",
        ]),

        // v4 — tags on transactions
        Migration(version: 4, statements: [
            """
            CREATE TABLE IF NOT EXISTS tags (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name);",
            """
            CREATE TABLE IF NOT EXISTS transaction_tags (
                transaction_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                tag_id         INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (transaction_id, tag_id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_transaction_tags_tx  ON transaction_tags(transaction_id);",
            "CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag ON transaction_tags(tag_id);",
        ]),

        // v5 — tags on Tricount entries
        Migration(version: 5, statements: [
            """
            CREATE TABLE IF NOT EXISTS tricount_entry_tags (
                entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (entry_id, tag_id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_tricount_entry_tags_entry ON tricount_entry_tags(entry_id);",
            "CREATE INDEX IF NOT EXISTS idx_tricount_entry_tags_tag   ON tricount_entry_tags(tag_id);",
        ]),

        // v6 — historical exchange rates
        Migration(version: 6, statements: [
            """
            CREATE TABLE IF NOT EXISTS currency_rates (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                from_currency TEXT NOT NULL,
                to_currency   TEXT NOT NULL DEFAULT 'EUR',
                date          TEXT NOT NULL,
                rate          REAL NOT NULL,
                UNIQUE(from_currency, to_currency, date) ON CONFLICT REPLACE
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_currency_rates_lookup ON currency_rates(from_currency, to_currency, date);",
        ]),

        // v7 — tag color
        Migration(version: 7, statements: [
            "ALTER TABLE tags ADD COLUMN color TEXT DEFAULT NULL;",
        ]),

        // v8 — de-duplicate tricount_reimbursements
        Migration(version: 8, statements: [
            """
            DELETE FROM tricount_reimbursements WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM tricount_reimbursements
                GROUP BY entry_id, tiers_id
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tricount_reimbursements_unique ON tricount_reimbursements(entry_id, tiers_id);",
        ]),

        // v9 — split the raw bank label from the user-editable description
        // For transactions imported from August 2025 onward, 'information'
        // held the raw label. Move it to the new 'libelle_brut' column and
        // free up 'information' for user notes.
        Migration(version: 9, statements: [
            "ALTER TABLE transactions ADD COLUMN libelle_brut TEXT DEFAULT NULL;",
            "UPDATE transactions SET libelle_brut = information, information = NULL WHERE date_op >= '2025-08-01';",
        ]),

        // v10 — account types and internal transfers
        // comptes.type: COURANT | EPARGNE | DIFFERE | AUTRE
        // tiers.linked_compte_id: points to the destination account of an
        //   internal transfer, so dashboard charts can exclude them
        Migration(version: 10, statements: [
            "ALTER TABLE comptes ADD COLUMN type TEXT NOT NULL DEFAULT 'COURANT';",
            "ALTER TABLE tiers ADD COLUMN linked_compte_id INTEGER REFERENCES comptes(id);",
        ]),

        // v11 — NULL category = "Uncategorized" (drops the dependency on id 40)
        // The JavaApp database may have categorie_id NOT NULL — rebuild the
        // table to drop that constraint before setting the values to NULL.
        Migration(version: 11, statements: [
            "UPDATE tiers SET category_id = NULL WHERE category_id = 40;",
            // Rebuild transactions without NOT NULL on categorie_id
            """
            CREATE TABLE IF NOT EXISTS transactions_v11 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                comptes_id   INTEGER REFERENCES comptes(id),
                tiers_id     INTEGER REFERENCES tiers(id),
                categorie_id INTEGER REFERENCES category(id),
                mdp_id       INTEGER REFERENCES mdp(id),
                information  TEXT,
                montant      REAL,
                date_op      TEXT,
                remboursement INTEGER REFERENCES tiers(id),
                libelle_brut  TEXT DEFAULT NULL
            );
            """,
            """
            INSERT INTO transactions_v11
                (id, comptes_id, tiers_id, categorie_id, mdp_id,
                 information, montant, date_op, remboursement, libelle_brut)
            SELECT id, comptes_id, tiers_id, categorie_id, mdp_id,
                   information, montant, date_op, remboursement, libelle_brut
            FROM transactions;
            """,
            "DROP TABLE transactions;",
            "ALTER TABLE transactions_v11 RENAME TO transactions;",
            "UPDATE transactions SET categorie_id = NULL WHERE categorie_id = 40;",
        ]),

        // v12 — English schema
        // Tables: comptes→accounts, category→categories, tiers→payees, mdp→payment_types
        // Columns: comptes_id→account_id, tiers_id→payee_id, categorie_id→category_id,
        //          mdp_id→payment_type_id, montant→amount, date_op→tx_date,
        //          remboursement→reimbursement_payee_id, cm_name→regex,
        //          linked_compte_id→linked_account_id
        Migration(version: 12, statements: [
            // Table renames
            "ALTER TABLE comptes RENAME TO accounts;",
            "ALTER TABLE category RENAME TO categories;",
            "ALTER TABLE tiers RENAME TO payees;",
            "ALTER TABLE mdp RENAME TO payment_types;",
            // Column renames in transactions
            "ALTER TABLE transactions RENAME COLUMN comptes_id TO account_id;",
            "ALTER TABLE transactions RENAME COLUMN tiers_id TO payee_id;",
            "ALTER TABLE transactions RENAME COLUMN categorie_id TO category_id;",
            "ALTER TABLE transactions RENAME COLUMN mdp_id TO payment_type_id;",
            "ALTER TABLE transactions RENAME COLUMN montant TO amount;",
            "ALTER TABLE transactions RENAME COLUMN date_op TO tx_date;",
            "ALTER TABLE transactions RENAME COLUMN remboursement TO reimbursement_payee_id;",
            // Column renames in payees (was tiers)
            "ALTER TABLE payees RENAME COLUMN cm_name TO regex;",
            "ALTER TABLE payees RENAME COLUMN linked_compte_id TO linked_account_id;",
            // Column renames in payment_types (was mdp)
            "ALTER TABLE payment_types RENAME COLUMN cm_name TO regex;",
            // Column rename in tricount_reimbursements
            "ALTER TABLE tricount_reimbursements RENAME COLUMN tiers_id TO payee_id;",
        ]),

        // v13 — Investments module (accounts + positions)
        Migration(version: 13, statements: [
            """
            CREATE TABLE IF NOT EXISTS investment_accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                broker TEXT NOT NULL DEFAULT '',
                currency TEXT NOT NULL DEFAULT 'EUR',
                account_type TEXT NOT NULL DEFAULT 'CTO',
                current_value REAL NOT NULL DEFAULT 0,
                invested_amount REAL NOT NULL DEFAULT 0,
                opened_at TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS investment_positions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL REFERENCES investment_accounts(id) ON DELETE CASCADE,
                asset_type TEXT NOT NULL DEFAULT 'STOCK',
                asset_name TEXT NOT NULL,
                ticker TEXT NOT NULL DEFAULT '',
                quantity REAL NOT NULL DEFAULT 0,
                average_buy_price REAL NOT NULL DEFAULT 0,
                current_value REAL NOT NULL DEFAULT 0,
                purchase_date TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_investment_positions_account ON investment_positions(account_id);"
        ]),

        // v14 — local cache of investment price history
        Migration(version: 14, statements: [
            """
            CREATE TABLE IF NOT EXISTS investment_price_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL,
                price_date TEXT NOT NULL,
                close_price REAL NOT NULL,
                source TEXT NOT NULL DEFAULT 'unknown',
                UNIQUE(identifier, price_date) ON CONFLICT REPLACE
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_investment_price_lookup ON investment_price_history(identifier, price_date);"
        ]),

        // v15 — Budget & Forecasts module
        // recurring_patterns : recurring expenses/income, detected or entered manually
        // budget_envelopes    : budget envelopes by category and period
        // budget_previsions   : forecast due dates (linked or not to an actual transaction)
        Migration(version: 15, statements: [
            """
            CREATE TABLE IF NOT EXISTS recurring_patterns (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                name             TEXT NOT NULL,
                amount_avg       REAL NOT NULL DEFAULT 0,
                amount_tolerance REAL NOT NULL DEFAULT 0.15,
                category_id      INTEGER REFERENCES categories(id),
                payee_id         INTEGER REFERENCES payees(id),
                frequency        TEXT NOT NULL DEFAULT 'MONTHLY',
                anchor_day       INTEGER,
                is_active        INTEGER NOT NULL DEFAULT 1,
                is_manual        INTEGER NOT NULL DEFAULT 0,
                created_at       TEXT NOT NULL,
                last_detected_at TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_recurring_frequency ON recurring_patterns(frequency, is_active);",
            """
            CREATE TABLE IF NOT EXISTS budget_envelopes (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT NOT NULL,
                category_id INTEGER REFERENCES categories(id),
                amount      REAL NOT NULL DEFAULT 0,
                period      TEXT NOT NULL DEFAULT 'MONTHLY',
                start_date  TEXT NOT NULL,
                is_active   INTEGER NOT NULL DEFAULT 1
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_budget_envelopes_category ON budget_envelopes(category_id, is_active);",
            """
            CREATE TABLE IF NOT EXISTS budget_previsions (
                id                     INTEGER PRIMARY KEY AUTOINCREMENT,
                recurring_pattern_id   INTEGER REFERENCES recurring_patterns(id) ON DELETE CASCADE,
                amount                 REAL NOT NULL,
                expected_date          TEXT NOT NULL,
                status                 TEXT NOT NULL DEFAULT 'PENDING',
                actual_transaction_id  INTEGER REFERENCES transactions(id) ON DELETE SET NULL,
                notes                  TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_budget_previsions_date   ON budget_previsions(expected_date, status);",
            "CREATE INDEX IF NOT EXISTS idx_budget_previsions_pattern ON budget_previsions(recurring_pattern_id);"
        ]),

        // v16 — start/end date for recurring patterns
        // start_date : date from which forecasts are generated
        // end_date   : optional end date (NULL = no end)
        Migration(version: 16, statements: [
            "ALTER TABLE recurring_patterns ADD COLUMN start_date TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE recurring_patterns ADD COLUMN end_date TEXT;",
            // Initialize start_date to created_at for existing patterns
            "UPDATE recurring_patterns SET start_date = created_at WHERE start_date = '';",
        ]),

        // v17 — repair the Tricount reimbursements FK
        // Databases migrated from the old schema may still have
        // tricount_reimbursements pointing at tiers(id). Rebuild the table
        // to point it at payees(id) instead.
        Migration(version: 17, statements: [
            """
            CREATE TABLE IF NOT EXISTS tricount_reimbursements_v17 (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                payee_id INTEGER NOT NULL REFERENCES payees(id),
                amount   REAL NOT NULL,
                currency TEXT NOT NULL DEFAULT 'EUR'
            );
            """,
            """
            INSERT INTO tricount_reimbursements_v17 (id, entry_id, payee_id, amount, currency)
            SELECT id, entry_id, payee_id, amount, currency
            FROM tricount_reimbursements;
            """,
            "DROP TABLE tricount_reimbursements;",
            "ALTER TABLE tricount_reimbursements_v17 RENAME TO tricount_reimbursements;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tricount_reimbursements_unique ON tricount_reimbursements(entry_id, payee_id);",
        ]),
        Migration(version: 18, statements: [
            "ALTER TABLE categories ADD COLUMN icon TEXT DEFAULT NULL;",
            // Default icons for existing built-in categories
            "UPDATE categories SET icon = 'cart.fill'                 WHERE id = 1;",
            "UPDATE categories SET icon = 'car.fill'                  WHERE id = 2;",
            "UPDATE categories SET icon = 'house.fill'                WHERE id = 3;",
            "UPDATE categories SET icon = 'heart.fill'                WHERE id = 4;",
            "UPDATE categories SET icon = 'gamecontroller.fill'       WHERE id = 5;",
            "UPDATE categories SET icon = 'bag.fill'                  WHERE id = 6;",
            "UPDATE categories SET icon = 'airplane'                  WHERE id = 7;",
            "UPDATE categories SET icon = 'banknote.fill'             WHERE id = 8;",
            "UPDATE categories SET icon = 'building.columns.fill'     WHERE id = 9;",
            "UPDATE categories SET icon = 'cart.fill'                 WHERE id = 10;",
            "UPDATE categories SET icon = 'fork.knife'                WHERE id = 11;",
            "UPDATE categories SET icon = 'fuelpump.fill'             WHERE id = 12;",
            "UPDATE categories SET icon = 'tram.fill'                 WHERE id = 13;",
            "UPDATE categories SET icon = 'key.fill'                  WHERE id = 14;",
            "UPDATE categories SET icon = 'wifi'                      WHERE id = 15;",
            "UPDATE categories SET icon = 'bolt.fill'                 WHERE id = 16;",
            "UPDATE categories SET icon = 'stethoscope'               WHERE id = 17;",
            "UPDATE categories SET icon = 'pills.fill'                WHERE id = 18;",
            "UPDATE categories SET icon = 'film.fill'                 WHERE id = 19;",
            "UPDATE categories SET icon = 'figure.run'                WHERE id = 20;",
            "UPDATE categories SET icon = 'repeat'                    WHERE id = 21;",
            "UPDATE categories SET icon = 'banknote.fill'             WHERE id = 22;",
            "UPDATE categories SET icon = 'arrow.uturn.left.circle.fill' WHERE id = 23;",
        ]),

        // v19 — Engine integration: extends payees with location/group/engine
        // link, adds payee_groups.
        // - city/country/address : instance location (one payee = one place)
        // - engine_merchant_id   : canonical NemorisEngine-side ID (e.g. "carrefour_market"); nullable
        // - group_id             : membership in a chain (e.g. "Carrefour Market" as a group)
        // - custom               : 1 = user-created with no engine link (a person, a freelancer…)
        // No column is required: an existing payee remains valid as-is.
        Migration(version: 19, statements: [
            "ALTER TABLE payees ADD COLUMN city               TEXT;",
            "ALTER TABLE payees ADD COLUMN country            TEXT;",
            "ALTER TABLE payees ADD COLUMN address            TEXT;",
            "ALTER TABLE payees ADD COLUMN engine_merchant_id TEXT;",
            "ALTER TABLE payees ADD COLUMN group_id           INTEGER;",
            "ALTER TABLE payees ADD COLUMN custom             INTEGER NOT NULL DEFAULT 0;",
            "CREATE INDEX IF NOT EXISTS idx_payees_engine_city ON payees(engine_merchant_id, city);",
            "CREATE INDEX IF NOT EXISTS idx_payees_group       ON payees(group_id);",
            """
            CREATE TABLE IF NOT EXISTS payee_groups (
                id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                display_name        TEXT NOT NULL,
                engine_merchant_id  TEXT,
                custom              INTEGER NOT NULL DEFAULT 0,
                created_at          INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_payee_groups_engine ON payee_groups(engine_merchant_id);",
        ]),

        // v20 — merchant logos.
        // domain TEXT on payees: web domain used to fetch the Google favicon.
        // Nullable; when empty, MerchantLogoService falls back to the engine
        // seed (merchants_domains.json) from engine_merchant_id, otherwise
        // shows the category's SF Symbol fallback.
        Migration(version: 20, statements: [
            "ALTER TABLE payees ADD COLUMN domain TEXT;",
        ]),

        // v21 — full payee editing.
        // note TEXT on payees: free-form note entered by the user (context, alias, etc.).
        Migration(version: 21, statements: [
            "ALTER TABLE payees ADD COLUMN note TEXT;",
        ]),

        // v22 — reworked import flow + persistent session.
        // - import_sessions : JSON snapshot of [ImportSessionRow] for resuming after quit.
        //   Only one 'active' session at a time (the UI must offer resume or
        //   cancel before starting a new one).
        // - csv_mappings : date/amount/label mapping indexed by header
        //   signature (concatenation of column names), reused automatically
        //   for subsequent imports of the same CSV format.
        Migration(version: 22, statements: [
            """
            CREATE TABLE IF NOT EXISTS import_sessions (
                id          TEXT PRIMARY KEY,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL,
                status      TEXT NOT NULL,
                source_file TEXT,
                account_id  INTEGER REFERENCES accounts(id),
                total_rows  INTEGER NOT NULL DEFAULT 0,
                rows_json   TEXT NOT NULL DEFAULT '[]'
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_import_sessions_status ON import_sessions(status, updated_at DESC);",
            """
            CREATE TABLE IF NOT EXISTS csv_mappings (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                header_signature     TEXT NOT NULL UNIQUE,
                date_column_index    INTEGER NOT NULL,
                amount_column_index  INTEGER NOT NULL,
                label_column_index   INTEGER NOT NULL,
                separator            TEXT NOT NULL DEFAULT ';',
                date_format          TEXT,
                amount_decimal       TEXT DEFAULT ',',
                created_at           TEXT NOT NULL
            );
            """,
        ]),

        // v23 — multi-source enrichment cache (Sirene + LLM + MapKit).
        // Key = engine_merchant_id when known, otherwise canonical_name (normalized label).
        // A single row per key: keeps the most confident resolution across all sources.
        Migration(version: 23, statements: [
            """
            CREATE TABLE IF NOT EXISTS enrichment_cache (
                cache_key          TEXT PRIMARY KEY,    -- engine_merchant_id ou canonical_name
                display_name       TEXT,
                domain             TEXT,
                category_id        INTEGER REFERENCES categories(id),
                address            TEXT,
                city               TEXT,
                country            TEXT,
                latitude           REAL,
                longitude          REAL,
                phone              TEXT,
                siret              TEXT,
                naf_code           TEXT,
                source             TEXT NOT NULL,       -- 'sirene' | 'llm' | 'mapkit' | 'merged' | 'manual'
                confidence         REAL NOT NULL DEFAULT 0,
                enriched_at        TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_enrichment_source ON enrichment_cache(source);"
        ]),

        // v24 — idempotent fix: ensures categories.icon exists.
        // Some databases had user_version >= 18 without the column (imported
        // from a JavaApp schema, or an app install predating v18). The ALTER
        // tolerates duplicates ("duplicate column name" is swallowed by
        // migrateIfNeeded), so it's safe for everyone. Icons are NOT
        // re-populated here, so as not to overwrite the user's custom choices.
        Migration(version: 24, statements: [
            "ALTER TABLE categories ADD COLUMN icon TEXT;",
        ]),

        // v25 — payee typing (merchant/contact/internal/organization).
        // tier_type : distinguishes a merchant from a P2P contact, to adapt
        //             the UI (avatar, relevant fields) and engine resolution.
        //             Backfill: everything defaults to 'merchant' (safe) —
        //             the user re-types contacts manually from PayeeDetailView.
        // contact_identifier : local CNContact ID (CNContactStore.unifiedContact)
        //             used to fetch the photo + name from the user's iOS
        //             address book. 100% local, permission requested lazily
        //             on the first link.
        Migration(version: 25, statements: [
            "ALTER TABLE payees ADD COLUMN tier_type TEXT NOT NULL DEFAULT 'merchant';",
            "ALTER TABLE payees ADD COLUMN contact_identifier TEXT;",
        ]),

        // v26 — cleanup of phantom budget tables.
        // budget_prevision_overrides and budget_prevision_rules were created
        // by an earlier experiment (or manually via the SQL console) and are
        // referenced NOWHERE in the current code (not BudgetRepository, not
        // any migration, not DatabaseSchemaView, not SimulatorSeeder). Safe
        // to drop via IF EXISTS — new databases simply never had them.
        Migration(version: 26, statements: [
            "DROP TABLE IF EXISTS budget_prevision_overrides;",
            "DROP TABLE IF EXISTS budget_prevision_rules;",
        ]),

        // v27 — cleanup of legacy tables.
        // Full audit: none of these tables are referenced in the current
        // code (not repositories, not migrations, not DatabaseSchemaView,
        // not the seed). The v1 tables are relics of the pre-rebrand app
        // (old French names, plus an `mdp` table for a password feature
        // that was never finished). Drop IF EXISTS → safe.
        //
        //   - tiers_patterns : an experiment never finished (like the v26 budget overrides)
        //   - mdp            : v1 "mots de passe" (passwords), never used
        //   - comptes        : superseded by `accounts` in a later migration
        //   - category       : (singular) superseded by `categories`
        //   - tiers          : (legacy) superseded by `payees`
        Migration(version: 27, statements: [
            "DROP TABLE IF EXISTS tiers_patterns;",
            "DROP TABLE IF EXISTS mdp;",
            "DROP TABLE IF EXISTS comptes;",
            "DROP TABLE IF EXISTS category;",
            "DROP TABLE IF EXISTS tiers;",
        ]),

        // v28 — multiple orders per position
        // Before: 1 investment_positions row = 1 implicit transaction (qty + cost basis).
        // Downside: no way to track a BUY + a SELL + a dividend, and no
        // chronological history of operations for the evolution chart.
        //
        // After: the position stays a "label" (ticker, asset_name) and its
        // qty/cost basis are DERIVED on the fly from the investment_orders
        // table. Cost basis method: weighted average of BUYs
        // (Σ qty×price + fees / Σ qty). FIFO for CTO tax purposes can be
        // computed separately in export mode if needed.
        //
        // Supported types: 'BUY', 'SELL', 'DIV' (dividend received). 'SPLIT' out of MVP scope.
        //
        // Backfill: for each existing position with quantity > 0, create
        // 1 retroactive BUY order with qty + average_buy_price + purchase_date.
        Migration(version: 28, statements: [
            """
            CREATE TABLE IF NOT EXISTS investment_orders (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                position_id INTEGER NOT NULL REFERENCES investment_positions(id) ON DELETE CASCADE,
                order_type  TEXT NOT NULL,                    -- 'BUY' | 'SELL' | 'DIV'
                quantity    REAL NOT NULL,
                unit_price  REAL NOT NULL,
                fees        REAL NOT NULL DEFAULT 0,
                executed_at TEXT NOT NULL,
                notes       TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_investment_orders_position ON investment_orders(position_id, executed_at);",
            // Backfill: 1 retroactive BUY per existing position (preserves history)
            """
            INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, fees, executed_at)
            SELECT id, 'BUY', quantity, average_buy_price, 0, purchase_date
            FROM investment_positions
            WHERE quantity > 0;
            """
        ]),

        // v29 — public live-sync APIs (opt-in)
        //
        // Lets the user link an investment account to a read-only external
        // source (Binance, EVM/BTC/SOL wallets) for automatic sync of
        // positions + transactions, with no Nemoris backend involved.
        //
        //   - provider_id : Swift provider ID (see InvestmentLiveSyncProvider.id)
        //   - display_name : user-defined label (e.g. "Personal Binance", "MetaMask main")
        //   - account_id : target investments account (a 1:1 mapping delivers
        //     synced positions into this account). NULL = orphaned (created
        //     without a linked account yet)
        //   - config_json : provider-specific metadata (e.g. {"chain":"polygon"}
        //     for EVM, {"address":"bc1q..."} for BTC, etc.). Stored as JSON
        //     for flexibility — no migration needed for each new field
        //   - last_sync_* : UI feedback on the last sync (status + error message)
        //   - show_tokens_without_price : user choice to show (1) or hide (0)
        //     tokens CoinGecko has no price for
        //
        // Security: credentials (API keys, secrets) are stored in the iOS
        // Keychain, NOT in the SQLite database. This table only holds
        // non-sensitive metadata.
        Migration(version: 29, statements: [
            """
            CREATE TABLE IF NOT EXISTS investment_live_sync (
                id                         INTEGER PRIMARY KEY AUTOINCREMENT,
                provider_id                TEXT NOT NULL,
                display_name               TEXT NOT NULL,
                account_id                 INTEGER REFERENCES investment_accounts(id) ON DELETE CASCADE,
                config_json                TEXT,
                enabled                    INTEGER NOT NULL DEFAULT 1,
                last_sync_at               TEXT,
                last_sync_status           TEXT,
                last_sync_message          TEXT,
                show_tokens_without_price  INTEGER NOT NULL DEFAULT 1,
                created_at                 TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_investment_live_sync_account ON investment_live_sync(account_id);",
            "CREATE INDEX IF NOT EXISTS idx_investment_live_sync_provider ON investment_live_sync(provider_id, enabled);"
        ]),

        // v30 — normalization: drop DERIVED columns.
        // - investment_positions.quantity, average_buy_price, purchase_date
        //   → strictly derived from investment_orders, computed on the fly
        //     via SQL at fetch time (JOIN + GROUP BY).
        // - investment_accounts.current_value, invested_amount
        //   → derived from positions (sum) and orders (sum of BUY costs),
        //     computed the same way at fetch time.
        //
        // SQLite ≥ 3.35 (iOS 14+) natively supports ALTER TABLE DROP COLUMN.
        // No risk of losing meaningful data: these values were either stale
        // caches (accounts) or already recomputed on every call to
        // recomputePositionFromOrders (positions).
        Migration(version: 30, statements: [
            "ALTER TABLE investment_positions DROP COLUMN quantity;",
            "ALTER TABLE investment_positions DROP COLUMN average_buy_price;",
            "ALTER TABLE investment_positions DROP COLUMN purchase_date;",
            "ALTER TABLE investment_accounts DROP COLUMN current_value;",
            "ALTER TABLE investment_accounts DROP COLUMN invested_amount;"
        ]),

        // v31 — adds the `isin` column on positions. The ISIN is the
        // universal identifier (12 chars, e.g. FR0000121329) that resolves
        // to the correct tradable symbol via OpenFIGI — the stored ticker is
        // often an asset name like "THALES" rather than the real symbol
        // "HO.PA", which Yahoo sync needs. `Position.ticker` stays, but
        // `isin` now takes priority for syncing.
        Migration(version: 31, statements: [
            "ALTER TABLE investment_positions ADD COLUMN isin TEXT;"
        ]),

        // v32 — de-duplicates investment_price_history.
        //
        // A plain INSERT with no ON CONFLICT lets every sync re-insert a
        // full year of daily prices for the same ticker, so duplicates grow
        // unbounded with each sync.
        //
        // 2 steps:
        //   1. DELETE the existing duplicates: keep the row with the
        //      MIN(rowid) for each (identifier, price_date).
        //   2. CREATE UNIQUE INDEX → makes future duplicates impossible,
        //      combined with INSERT OR REPLACE in the repository (atomic upsert).
        Migration(version: 32, statements: [
            """
            DELETE FROM investment_price_history
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM investment_price_history
                GROUP BY identifier, price_date
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_invest_price_unique ON investment_price_history(identifier, price_date);"
        ]),

        // v33 — de-duplicates orders synced from live sync
        //
        // `external_id` stores a stable external ID returned by the provider
        // (Binance tradeId, blockchain txHash, etc.), prefixed by provider:
        //   - "binance_<symbol>_<tradeId>"  for Binance
        //   - "evm_<chain>_<txHash>"        for EVM wallets (future)
        //   - "btc_<txid>"                  for BTC wallets (future)
        //   - "sol_<signature>"             for Solana wallets (future)
        //
        // Without this column, every manual sync would re-insert the same
        // historical trades as duplicates. The UNIQUE INDEX guarantees
        // atomic de-duplication via `INSERT OR IGNORE` in the repository.
        //
        // Orders entered manually by the user have `external_id = NULL` →
        // unaffected by the uniqueness constraint.
        Migration(version: 33, statements: [
            "ALTER TABLE investment_orders ADD COLUMN external_id TEXT;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_invest_orders_external_id ON investment_orders(external_id) WHERE external_id IS NOT NULL;"
        ]),

        // v34 — cash balance on the account.
        //
        // A PEA, a CTO, or even a wallet often holds idle cash (dividends
        // not reinvested, sale proceeds awaiting reallocation, recent
        // deposits). That liquidity is part of the account's total capital
        // but isn't modeled as a position (no asset, no price) — it's stored
        // as a direct column on the account instead.
        //
        // The account total shown to the user becomes:
        //   sum(positions.current_value) + cash_balance
        //
        // Edited manually by the user via the account form. LiveSync
        // accounts (Binance, wallets) could later surface their EUR/USDT
        // balance automatically as cashBalance.
        Migration(version: 34, statements: [
            "ALTER TABLE investment_accounts ADD COLUMN cash_balance REAL NOT NULL DEFAULT 0;"
        ]),

        // v35 — DROP TABLE investment_price_history.
        //
        // Price history isn't user data (prices are freely retrievable from
        // Yahoo/Stooq/CoinGecko), so it has no business cluttering the
        // user's SQLite database, which should represent ONLY what they
        // created or imported (positions, orders, transactions, etc.).
        //
        // The cache now lives in
        // `Library/Caches/nemoris/investment_price_history.json` (managed by
        // `PriceHistoryCache`), purgeable by iOS under storage pressure and
        // never included in iCloud/user backups.
        //
        // The user triggers a re-sync of their positions via the
        // dashboard's "Reload" button when needed.
        Migration(version: 35, statements: [
            "DROP TABLE IF EXISTS investment_price_history;"
        ]),

        // v36 — DROP TABLE enrichment_cache.
        //
        // Same reasoning as v35: this cache comes from external APIs
        // (Sirene, MapKit, Apple Foundation Models) — not user data, so it
        // doesn't belong in the user's SQLite database. Now cached on disk
        // at `Library/Caches/nemoris/enrichment_cache.json` via `JSONFileCache`.
        Migration(version: 36, statements: [
            "DROP TABLE IF EXISTS enrichment_cache;"
        ]),

        // v37 — Net Worth module.
        //
        // 3 independent tables model the user's total net worth:
        //
        //   • patrimoine_real_estate : real estate (100% manual entry,
        //     estimated gain = current_value - purchase_price).
        //
        //   • patrimoine_loans : loans & debts. The `loan_type` column
        //     selects the remaining-principal formula:
        //       - AMORT             : classic amortization (fixed installment)
        //       - IN_FINE           : principal repaid in one lump sum at maturity
        //       - DEFERRED_TOTAL    : full deferral, then amortization
        //       - DEFERRED_PARTIAL  : partial deferral (interest only), then amortization
        //       - REVOLVING         : revolving credit, manual value
        //     The calculation logic lives in LoanCalculator.swift (pure Swift, testable).
        //
        //   • patrimoine_assets : "Personal property & Cash" items (cash,
        //     savings accounts, PEA, etc.). Each asset is either
        //     **standalone** (manual_value) or **linked** to an existing
        //     account — exactly 1 of the 2 link columns can be set (enforced
        //     by partial UNIQUE INDEXes). Linking is soft (ON DELETE SET
        //     NULL): if the user deletes the linked bank/investment account,
        //     the asset automatically falls back to standalone with its last
        //     known value (last_known_value) — no destructive cascade.
        //
        // The partial UNIQUE INDEXes on linked_account_id and
        // linked_investment_account_id guarantee that an account can be
        // linked to at most 1 net-worth asset (prevents double-counting by
        // construction).
        Migration(version: 37, statements: [
            """
            CREATE TABLE IF NOT EXISTS patrimoine_real_estate (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                purchase_price REAL NOT NULL,
                purchase_date TEXT NOT NULL,
                current_value REAL NOT NULL,
                estimated_at TEXT,
                address TEXT,
                notes TEXT,
                created_at TEXT NOT NULL
            );
            """,

            """
            CREATE TABLE IF NOT EXISTS patrimoine_loans (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                loan_type TEXT NOT NULL,
                principal REAL NOT NULL,
                annual_rate REAL NOT NULL,
                duration_months INTEGER NOT NULL,
                deferral_months INTEGER NOT NULL DEFAULT 0,
                start_date TEXT NOT NULL,
                linked_real_estate_id INTEGER REFERENCES patrimoine_real_estate(id) ON DELETE SET NULL,
                notes TEXT,
                created_at TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_patrimoine_loans_real_estate ON patrimoine_loans(linked_real_estate_id);",

            """
            CREATE TABLE IF NOT EXISTS patrimoine_assets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                asset_kind TEXT NOT NULL,
                linked_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                linked_investment_account_id INTEGER REFERENCES investment_accounts(id) ON DELETE SET NULL,
                manual_value REAL NOT NULL DEFAULT 0,
                last_known_value REAL NOT NULL DEFAULT 0,
                notes TEXT,
                created_at TEXT NOT NULL
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_patrimoine_assets_account ON patrimoine_assets(linked_account_id) WHERE linked_account_id IS NOT NULL;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_patrimoine_assets_invest ON patrimoine_assets(linked_investment_account_id) WHERE linked_investment_account_id IS NOT NULL;"
        ]),

        // v38 — monthly insurance cost on loans.
        //
        // Borrower's insurance isn't bank interest — it does NOT change the
        // remaining principal or the amortization calculation. It's a
        // separate charge the user pays every month on top of the loan
        // installment (typically 0.20% to 0.50% of the initial principal per
        // year, smoothed).
        //
        // Stored as a direct monthly amount (not a %) to match what the user
        // sees on their contract. Shown in the form, in the loan row, and in
        // the totals (overall monthly cost = Σ monthlyPayment + Σ insuranceMonthly).
        Migration(version: 38, statements: [
            "ALTER TABLE patrimoine_loans ADD COLUMN insurance_monthly REAL NOT NULL DEFAULT 0;"
        ]),

        // v39 — financial goals.
        //
        // Simple table: a goal is a name + a type + a target amount + an
        // optional deadline. "Progress" is computed in memory by crossing it
        // with the PatrimoineSnapshot (see GoalsViewModel.progress(for:)).
        //
        // Supported types:
        //   • SAVINGS     : reach €X in savings (totalAssetsValue)
        //   • NETWORTH    : reach €X in net worth (assets + real estate − debts)
        //   • DEBT_PAYOFF : pay off €X of debt (target = 0 = 100%)
        //   • CUSTOM      : manual goal (the user updates "current" by
        //                   editing the goal — no automatic calculation)
        //
        // Deliberately no FK to patrimoine_assets or patrimoine_loans — a
        // global goal like "Reach €50k in savings" covers most cases. A
        // `linked_asset_id INTEGER REFERENCES patrimoine_assets(id)
        // ON DELETE SET NULL` column could be added later if per-asset
        // targeting is needed.
        Migration(version: 39, statements: [
            """
            CREATE TABLE IF NOT EXISTS goals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                target_amount REAL NOT NULL,
                deadline_date TEXT,
                custom_current_amount REAL NOT NULL DEFAULT 0,
                notes TEXT,
                created_at TEXT NOT NULL
            );
            """
        ]),

        // v40 — CloudKit sync instrumentation.
        //
        // Foundation for dirty-tracking ahead of CKSyncEngine sync:
        //   • infra tables: sync_meta (internal KV store), sync_pending
        //     (upload queue), sync_tombstones (deletions to propagate)
        //   • on the 7 core ledger tables: `uuid` columns (multi-device
        //     identity, backfilled via randomblob) + `updated_at`
        //     (ISO8601 timestamp for LWW conflict resolution) + a UNIQUE
        //     index on uuid.
        //
        // The INTEGER PRIMARY KEYs stay the local PK/FKs — the uuid is the
        // identity that travels. The tracking triggers are NOT part of this
        // migration: they're (re)installed on every boot by
        // SyncSchema.installTriggers() at the end of migrateIfNeeded().
        //
        // Existing rows are NOT enqueued into sync_pending here: activating
        // sync later performs a full initial scan that fills the queue.
        //
        // Secondary tables (recurring_patterns, investment_*, patrimoine_*,
        // goals, tricount_*) are covered by a later migration.
        Migration(version: 40, statements:
            SyncSchema.infrastructureStatements
                + [
                    "transactions",
                    "payees",
                    "payee_groups",
                    "categories",
                    "accounts",
                    "payment_types",
                    "tags",
                ].flatMap { SyncSchema.columnStatements(table: $0) }
        ),

        // v41 — per-row CKSyncEngine state.
        //
        //   • sync_record_meta : archived CKRecord system fields
        //     (encodeSystemFields) — needed to re-upload a row without
        //     triggering a serverRecordChanged conflict on every save.
        //   • sync_unresolved_refs : remote FKs whose target row hasn't
        //     arrived yet (CloudKit batches carry no guaranteed order).
        //     Re-resolved after each applied batch. A column_name prefixed
        //     "__tag__" means a pending transaction_tags link, not a column.
        Migration(version: 41, statements: [
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
        ]),

        // v42 — extends sync to the Budget / Investments / Net Worth / Goals
        // / Tricount modules.
        //
        // Same uuid/updated_at columns + backfill + UNIQUE index as v40, on
        // the 14 tables listed in SyncSchema.secondaryTablesV42. Triggers
        // are installed as usual by installTriggers() at the end of
        // migrateIfNeeded().
        //
        // Conditional auto-enqueue: unlike v40, sync may already be active
        // on some devices by this point, and enable()'s initial scan won't
        // run again for them. Each table's last statement therefore enqueues
        // its rows into sync_pending, but ONLY if
        // sync_meta['sync_enabled'] = '1' (on a device without sync, the
        // subquery returns NULL → predicate false → no row is queued, and a
        // future activation performs its normal full scan).
        Migration(version: 42, statements:
            SyncSchema.secondaryTablesV42.flatMap { table in
                SyncSchema.columnStatements(table: table) + [
                    """
                    INSERT OR REPLACE INTO sync_pending (table_name, row_uuid, queued_at)
                    SELECT '\(table)', uuid, strftime('%Y-%m-%dT%H:%M:%fZ','now')
                    FROM \(table)
                    WHERE uuid IS NOT NULL
                      AND COALESCE((SELECT value FROM sync_meta WHERE key = 'sync_enabled'), '0') = '1';
                    """,
                ]
            }
        ),

        // v43 — queue for deferred remote records (a NOT NULL FK whose
        // target hasn't arrived yet). CloudKit batches carry no guaranteed
        // order, so a record referencing a not-yet-applied parent would
        // otherwise violate the NOT NULL constraint and be dropped —
        // CloudKit never redelivers a fetched record that wasn't applied.
        // The full payload is now stored in sync_deferred_rows and replayed
        // at the end of each batch once its targets exist (SyncPayloadStore).
        Migration(version: 43, statements: SyncSchema.deferredRowsDDL),

        // v44 — unified reimbursements for plain transactions + Tricount.
        // Replaces `transactions.reimbursement_payee_id` (a column on the
        // core table, NULL on EVERY transaction) and generalizes
        // `tricount_reimbursements` into a single `reimbursements` table,
        // attached via transaction_id XOR tricount_entry_id.
        //
        // The XOR CHECK isn't just an integrity constraint: it's what lets
        // sync_deferred_rows (v43) catch the case where a CloudKit batch
        // delivers a reimbursements row before its target transaction/entry.
        // Without it, the INSERT would succeed with both FKs NULL (a phantom
        // row that never gets repaired) instead of failing and being deferred.
        //
        // amount stays NULL on the transaction_id side (the amount is the
        // whole transaction's, no notion of a share); it's required in
        // practice on the tricount_entry_id side (personal share computed
        // from tricount_shares, independent of the entry's own amount).
        Migration(version: 44, statements: [
            """
            CREATE TABLE IF NOT EXISTS reimbursements (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                transaction_id    INTEGER REFERENCES transactions(id) ON DELETE CASCADE,
                tricount_entry_id INTEGER REFERENCES tricount_entries(id) ON DELETE CASCADE,
                payee_id          INTEGER NOT NULL REFERENCES payees(id),
                amount            REAL,
                currency          TEXT NOT NULL DEFAULT 'EUR',
                status            TEXT NOT NULL DEFAULT 'PENDING',
                uuid              TEXT,
                updated_at        TEXT,
                CHECK ((transaction_id IS NOT NULL) <> (tricount_entry_id IS NOT NULL))
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_reimbursements_transaction ON reimbursements(transaction_id) WHERE transaction_id IS NOT NULL;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_reimbursements_tricount ON reimbursements(tricount_entry_id, payee_id) WHERE tricount_entry_id IS NOT NULL;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_reimbursements_uuid ON reimbursements(uuid);",
            """
            INSERT INTO reimbursements (transaction_id, payee_id, amount, currency, status, uuid, updated_at)
            SELECT id, reimbursement_payee_id, NULL, 'EUR', 'PENDING',
                   lower(hex(randomblob(16))), strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM transactions WHERE reimbursement_payee_id IS NOT NULL;
            """,
            """
            INSERT INTO reimbursements (tricount_entry_id, payee_id, amount, currency, status, uuid, updated_at)
            SELECT entry_id, payee_id, amount, currency, 'PENDING',
                   lower(hex(randomblob(16))), strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM tricount_reimbursements;
            """,
            """
            INSERT OR REPLACE INTO sync_pending (table_name, row_uuid, queued_at)
            SELECT 'reimbursements', uuid, strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM reimbursements
            WHERE uuid IS NOT NULL
              AND COALESCE((SELECT value FROM sync_meta WHERE key = 'sync_enabled'), '0') = '1';
            """,
            "DROP TABLE tricount_reimbursements;",
            "ALTER TABLE transactions DROP COLUMN reimbursement_payee_id;",
        ]),

        // v45 — the import session covers BOTH destinations.
        //
        // The session cache (resume after closing the app, 12h reminder,
        // survives a restart) previously only existed for transactions. On
        // the investments side, an analysis result lived only in memory in
        // `DocumentImportCoordinator`: relaunching the app lost it, even
        // though analyzing a statement can take tens of seconds.
        //
        // `destination` discriminates the content of `rows_json`:
        //   • 'transactions'  → [ImportSessionRow]   (unchanged)
        //   • 'investments'   → ImportBatchResult
        //
        // DEFAULT 'transactions': already-persisted sessions read back
        // byte-for-byte, with no rewrite of their JSON. That's what lets a
        // user with an import in progress update the app without losing it.
        Migration(version: 45, statements: [
            "ALTER TABLE import_sessions ADD COLUMN destination TEXT NOT NULL DEFAULT 'transactions';",
        ]),

        // v46 — free-form transaction metadata.
        //
        // `transactions.payment_type_id` was the only free attribute a user
        // could set outside of payee/category/tags — and it imposed one
        // fixed meaning ("payment method") on everyone, including those who
        // wanted to track something else entirely (joint/personal account,
        // work/personal, project…).
        //
        // It becomes one metadata key among others, user-defined.
        //
        // FULL SWITCHOVER, not coexistence: the UI now reads only the
        // metadata. Keeping both alive in parallel would create two places
        // to edit the same information — the exact kind of divergence this
        // codebase avoids elsewhere.
        //
        // `payment_types` and `transactions.payment_type_id` are DEPRECATED,
        // not dropped: a column is only removed once nothing references it
        // anymore. The data stays intact, which keeps the migration reversible.
        //
        // The "Payment method" key is created ONLY if the database actually
        // has payment methods in use. A brand-new database has none — by
        // design: a new user never sees this concept, they create whichever
        // keys they need.
        Migration(version: 46, statements: [
            """
            CREATE TABLE IF NOT EXISTS transaction_metadata_keys (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                icon       TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                -- Optional functional role. The only known value is
                -- 'payment_method', which designates the key that import
                -- fills in automatically from what it infers from the raw
                -- label (card, transfer, direct debit…). Without it, the
                -- import's hint is simply ignored — no phantom key is
                -- created behind the user's back.
                role       TEXT,
                created_at TEXT NOT NULL,
                uuid       TEXT,
                updated_at TEXT
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmk_name ON transaction_metadata_keys(name COLLATE NOCASE);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmk_uuid ON transaction_metadata_keys(uuid);",
            // Only one key can hold a given role, otherwise the import
            // wouldn't know which one to fill.
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmk_role ON transaction_metadata_keys(role) WHERE role IS NOT NULL;",

            """
            CREATE TABLE IF NOT EXISTS transaction_metadata_values (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                transaction_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                key_id         INTEGER NOT NULL REFERENCES transaction_metadata_keys(id) ON DELETE CASCADE,
                value          TEXT NOT NULL,
                uuid           TEXT,
                updated_at     TEXT
            );
            """,
            // One value per key and per transaction. A transaction therefore
            // carries MULTIPLE metadata entries (unlike payment_type_id, 0..1).
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmv_pair ON transaction_metadata_values(transaction_id, key_id);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmv_uuid ON transaction_metadata_values(uuid);",
            "CREATE INDEX IF NOT EXISTS idx_tmv_key ON transaction_metadata_values(key_id);",

            // Conditional migration of existing data.
            """
            INSERT INTO transaction_metadata_keys (name, icon, sort_order, role, created_at, uuid, updated_at)
            SELECT 'Mode de paiement', 'creditcard', 0, 'payment_method',
                   strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                   lower(hex(randomblob(16))), strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE EXISTS (
                SELECT 1 FROM transactions t
                JOIN payment_types p ON p.id = t.payment_type_id
                WHERE t.payment_type_id IS NOT NULL
            );
            """,
            """
            INSERT INTO transaction_metadata_values (transaction_id, key_id, value, uuid, updated_at)
            SELECT t.id,
                   (SELECT id FROM transaction_metadata_keys WHERE role = 'payment_method'),
                   p.name,
                   lower(hex(randomblob(16))), strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM transactions t
            JOIN payment_types p ON p.id = t.payment_type_id
            WHERE t.payment_type_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM transaction_metadata_keys WHERE role = 'payment_method');
            """,
            // Enqueued for sync, as in v42/v44: only if sync is ALREADY
            // active on this device (`enable()`'s initial scan won't run
            // again for it).
            """
            INSERT OR REPLACE INTO sync_pending (table_name, row_uuid, queued_at)
            SELECT 'transaction_metadata_keys', uuid, strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM transaction_metadata_keys
            WHERE uuid IS NOT NULL
              AND COALESCE((SELECT value FROM sync_meta WHERE key = 'sync_enabled'), '0') = '1';
            """,
            """
            INSERT OR REPLACE INTO sync_pending (table_name, row_uuid, queued_at)
            SELECT 'transaction_metadata_values', uuid, strftime('%Y-%m-%dT%H:%M:%fZ','now')
            FROM transaction_metadata_values
            WHERE uuid IS NOT NULL
              AND COALESCE((SELECT value FROM sync_meta WHERE key = 'sync_enabled'), '0') = '1';
            """,
        ]),

        // v47 — AI financial coach (AXE AC).
        //
        // Three tables, and they do NOT share the same lifecycle — which is
        // why they are not one table:
        //
        //  • `coach_profile`   — the objectives the user WRITES. Authored
        //    prose, painful to retype ⇒ SYNCED (see SyncSchema.syncedTables).
        //  • `coach_analyses`  — one row per domain: the model's read of the
        //    user's situation + when it ran. DERIVED ⇒ never synced.
        //  • `coach_recommendations` — DERIVED, regenerable at any time from
        //    the ledger ⇒ never synced, same class as `import_sessions`.
        //
        // ⚠️ `coach_profile.slot` exists ONLY to give the singleton a UNIQUE
        // key. Without it, two devices each writing their objectives create
        // two rows with different uuids and nothing ever reconciles them.
        // With it, the sync's identity adoption (min(uuid) wins, cf.
        // `SyncPayloadStore.uniqueAdoptionKeys`) merges them deterministically.
        // No row is seeded here: an empty profile is the absence of a row, so
        // a fresh install has nothing to push.
        Migration(version: 47, statements: [
            """
            CREATE TABLE IF NOT EXISTS coach_profile (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                slot       TEXT NOT NULL DEFAULT 'default',
                objectives TEXT NOT NULL DEFAULT '',
                uuid       TEXT,
                updated_at TEXT
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_coach_profile_slot ON coach_profile(slot);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_coach_profile_uuid ON coach_profile(uuid);",

            """
            CREATE TABLE IF NOT EXISTS coach_analyses (
                domain          TEXT PRIMARY KEY,
                profile_summary TEXT,
                generated_at    TEXT,
                status          TEXT NOT NULL DEFAULT 'ok',
                message         TEXT,
                backend         TEXT
            );
            """,

            """
            CREATE TABLE IF NOT EXISTS coach_recommendations (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                domain        TEXT NOT NULL,
                -- Stable key ACROSS runs, supplied by the model (slugified
                -- from the title as a fallback). This is what lets a
                -- "dismissed" verdict survive a regeneration: same subject
                -- re-proposed next week keeps its status instead of coming
                -- back as new.
                ref           TEXT NOT NULL,
                title         TEXT NOT NULL,
                detail        TEXT NOT NULL,
                rationale     TEXT,
                category      TEXT,
                annual_impact REAL NOT NULL DEFAULT 0,
                effort        INTEGER NOT NULL DEFAULT 3,
                confidence    REAL NOT NULL DEFAULT 0.5,
                status        TEXT NOT NULL DEFAULT 'new',
                generated_at  TEXT NOT NULL
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_coach_reco_ref ON coach_recommendations(domain, ref);",
            "CREATE INDEX IF NOT EXISTS idx_coach_reco_domain ON coach_recommendations(domain, status);",
        ]),

        // v48 — trace of the model's raw response (AXE AC).
        //
        // Immediate usage feedback: "The model's response couldn't be
        // used" — an accurate message, but UNDIAGNOSABLE. Neither
        // the user nor the developer could see what the model had
        // actually returned, so there was no way to tell whether the model had
        // refused, answered off-topic, or been cut off mid-JSON.
        //
        // Same lesson as document import and its "See the text read
        // (N characters)" disclosure: a failed extraction is only actionable if
        // you can compare what the app received against what it did with it.
        Migration(version: 48, statements: [
            "ALTER TABLE coach_analyses ADD COLUMN raw_response TEXT;",
        ]),

        // v49 — Apple Pay staging (Shortcuts automation, silent
        // `openAppWhenRun = false` trigger). A LOCAL table, never
        // synced (see SyncSchema.swift): it's an ephemeral buffer,
        // not a registry meant to be shared across devices — each
        // device receives its own Apple Pay notifications.
        //
        // `matched_transaction_id` references `transactions`, but in the
        // REVERSE direction of what you'd usually do (a column on
        // `transactions` pointing to this table): `transactions` IS
        // synced, and a FK to a non-synced table would be serialized
        // there as a raw local integer, with no uuid translation —
        // silent corruption on a 2nd device. By keeping the link on
        // THIS table (unsynced), it never leaves the device.
        Migration(version: 49, statements: [
            """
            CREATE TABLE IF NOT EXISTS pending_apple_pay_entries (
                id                     INTEGER PRIMARY KEY AUTOINCREMENT,
                card                   TEXT,
                amount                 REAL NOT NULL,
                merchant               TEXT NOT NULL,
                status                 TEXT NOT NULL DEFAULT 'pending',
                matched_transaction_id INTEGER REFERENCES transactions(id) ON DELETE SET NULL,
                created_at             TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_apple_pay_status ON pending_apple_pay_entries(status, created_at);",
        ]),

        // v50 — one set of coach objectives PER DOMAIN.
        //
        // A single shared text made every analysis carry irrelevant baggage:
        // "spend less and diversify better" asks the spending coach to comment
        // on diversification (which it cannot see) and the portfolio coach to
        // comment on spending (which it cannot see either). Both then bend
        // their recommendations towards an objective the dossier in front of
        // them says nothing about — user report 2026-09-02.
        //
        // `slot` was already the singleton key, and it is what the sync adopts
        // on (`SyncPayloadStore.uniqueAdoptionKeys`), so the domain simply
        // BECOMES the slot. No new column, no new index, and the merge between
        // devices keeps working unchanged.
        //
        // ⚠️ `uuid`/`updated_at` are deliberately left to the sync TRIGGERS
        // (they are reinstalled at every boot, after migrations): filling them
        // here would bypass the change tracking these triggers exist for.
        Migration(version: 50, statements: [
            """
            INSERT INTO coach_profile (slot, objectives)
            SELECT 'transactions', objectives FROM coach_profile WHERE slot = 'default'
              AND NOT EXISTS (SELECT 1 FROM coach_profile WHERE slot = 'transactions');
            """,
            """
            INSERT INTO coach_profile (slot, objectives)
            SELECT 'investments', objectives FROM coach_profile WHERE slot = 'default'
              AND NOT EXISTS (SELECT 1 FROM coach_profile WHERE slot = 'investments');
            """,
            "DELETE FROM coach_profile WHERE slot = 'default';",
        ]),

        // v51 — "other" accounts: dissociation from aggregated calculations.
        //
        // User feedback: a need for an account (e.g. health/insurance
        // reimbursements) whose transactions remain viewable on its own screen but
        // NEVER enter automatic aggregates (categories, budget,
        // dashboard, AI coach, widget). Defaults to 0: no existing account is
        // affected by this migration.
        Migration(version: 51, statements: [
            "ALTER TABLE accounts ADD COLUMN excluded_from_aggregates INTEGER NOT NULL DEFAULT 0;",
        ]),
    ]

    // MARK: - Private helpers

    private static func userVersion(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func fallbackURL() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Marketing-screenshot automation (`-nemorisScreenshotMode`, see NemorisApp.init):
        // isolates the seeded demo database in its own folder so it can never read from or
        // write into a real user's `FinanceMobileIOS` — this matters most on native macOS,
        // which is unsandboxed and would otherwise resolve to the user's actual database.
        let folderName = CommandLine.arguments.contains("-nemorisScreenshotMode")
            ? "FinanceMobileIOS-Screenshots"
            : "FinanceMobileIOS"
        let appDir = supportDir.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(fallbackFileName)
    }
}
