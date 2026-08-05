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

    /// Nombre de transactions dans la base (0 si base absente, table manquante ou
    /// erreur). Utilisé par le garde-fou d'auto-backup (`BackupService`) pour ne
    /// PAS snapshoter une base vide — sinon un backup quasi-vide occuperait un slot
    /// de la rotation des 30 et pousserait un vrai snapshot dehors.
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

        // Copy into app sandbox (overwrite any existing copy)
        let dest = fallbackURL()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: pickerURL, to: dest)

        migrateIfNeeded()
    }

    /// Creates a brand-new empty SQLite database at the fallback path, runs all migrations, and optionally seeds default data.
    /// Pass `seedDefaults: false` when l'appareil rejoindra un coffre iCloud existant
    /// (évite les catégories / modes de paiement en double avant la première sync).
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

    /// Insère les données de référence par défaut dans une base vierge.
    /// Utilise INSERT OR IGNORE pour ne pas écraser des données existantes.
    func seedNewDatabase() {
        guard hasDatabase() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let seeds: [String] = [
            // Catégories parentes (tables/colonnes désormais en anglais après migration v12)
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (1,  'Alimentation',          'cart.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (2,  'Transport',             'car.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (3,  'Logement',              'house.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (4,  'Santé',                 'heart.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (5,  'Loisirs & Culture',     'gamecontroller.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (6,  'Vêtements & Shopping',  'bag.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (7,  'Voyages',               'airplane');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (8,  'Revenus',               'banknote.fill');",
            "INSERT OR IGNORE INTO categories (id, name, icon) VALUES (9,  'Banque & Finance',      'building.columns.fill');",
            // Sous-catégories
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
            // ⚠️ Les moyens de paiement NE SONT PLUS SEMÉS (migration v46).
            //
            // « Mode de paiement » n'est plus un concept de premier ordre : il
            // est devenu une métadonnée libre parmi d'autres. Une base NEUVE
            // n'en a donc aucune trace — l'utilisateur crée les clés dont il a
            // l'usage (« Mode de paiement », « Projet », « Pro / Perso »…), ou
            // aucune.
            //
            // Seules les bases EXISTANTES gardent la clé « Mode de paiement »,
            // recréée à l'identique par la migration à partir de leurs données.
            // La table `payment_types` reste créée (dépréciée, pas supprimée —
            // doctrine AXE H), simplement vide.
        ]

        for sql in seeds {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - Migrations
    //
    // Chaque migration est identifiée par un numéro de version (1, 2, 3…).
    // SQLite stocke la version courante dans PRAGMA user_version.
    // migrateIfNeeded() n'applique que les migrations dont le numéro > user_version,
    // dans l'ordre, de façon atomique (BEGIN/COMMIT par migration).
    //
    // Pour ajouter une migration : ajouter une entrée à la fin de `migrations` et
    // incrémenter le numéro. Ne jamais modifier une migration existante.

    @discardableResult
    func migrateIfNeeded() -> String? {
        guard hasDatabase() else { return "Aucune base de données" }
        return Self.migrate(at: sqliteURL())
    }

    /// Applique la chaîne de migrations à une base arbitraire.
    ///
    /// Statique et paramétrée par l'URL pour que les tests puissent fabriquer
    /// une base au schéma courant dans un dossier temporaire, sans toucher
    /// celle de l'application ni instancier le singleton. Renvoie `nil` si tout
    /// s'est bien passé, sinon les erreurs concaténées.
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
                    // ALTER TABLE ADD COLUMN: ignore si la colonne existe déjà.
                    if tolerateDuplicateColumn && errStr.localizedCaseInsensitiveContains("duplicate column name") {
                        return
                    }
                    // ALTER TABLE RENAME COLUMN: ignore si la colonne source n'existe plus
                    // (migration déjà partiellement appliquée) ou si la destination existe déjà.
                    if upper.contains("RENAME COLUMN") &&
                        (errStr.localizedCaseInsensitiveContains("no such column") ||
                         errStr.localizedCaseInsensitiveContains("duplicate column name")) {
                        return
                    }
                    // ALTER TABLE RENAME TO: ignore si la table destination existe déjà
                    // (table déjà renommée lors d'un run partiel précédent).
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
                break   // stopper à la première migration en échec
            }
        }

        // AXE L (sync CloudKit) : (ré)installe les triggers de dirty-tracking.
        // Hors migrations pour pouvoir évoluer librement (DROP + CREATE idempotent).
        // Prérequis : colonnes uuid/updated_at présentes (migration v40).
        if Self.userVersion(db) >= 40 {
            SyncSchema.installTriggers(db)
        }

        // Réparation one-shot (2026-07-17) : fusionne les doublons de
        // categories/payment_types créés par les premières activations sync
        // (chaque appareil avait uploadé son seed usine avant que l'adoption
        // déterministe existe). Tourne APRÈS installTriggers et HORS suppress :
        // les DELETE tombstonent → la fusion se propage aux autres appareils.
        if Self.userVersion(db) >= 42, SyncPayloadStore.metaValue(db, "ref_dedup_v1_done") != "1" {
            let merged = SyncPayloadStore.dedupReferenceDuplicates(db)
            SyncPayloadStore.setMeta(db, "ref_dedup_v1_done", "1")
            if merged > 0 {
                print("[DatabaseManager] Doublons de référence fusionnés : \(merged)")
            }
        }

        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Version courante du schéma (0 = base vierge ou pré-versionnée).
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

    // MARK: - Liste des migrations

    private struct Migration {
        let version: Int
        let statements: [String]
    }

    private static let migrations: [Migration] = [

        // v1 — tables de base (compatible avec les bases JavaApp existantes)
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

        // v3 — catégories hiérarchiques
        Migration(version: 3, statements: [
            "ALTER TABLE category ADD COLUMN parent_id INTEGER REFERENCES category(id);",
            "CREATE INDEX IF NOT EXISTS idx_category_parent ON category(parent_id);",
        ]),

        // v4 — tags sur les transactions
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

        // v5 — tags sur les entrées Tricount
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

        // v6 — taux de change historiques
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

        // v7 — couleur des tags
        Migration(version: 7, statements: [
            "ALTER TABLE tags ADD COLUMN color TEXT DEFAULT NULL;",
        ]),

        // v8 — dédoublonnage tricount_reimbursements
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

        // v9 — séparation libellé brut bancaire / description utilisateur
        // Pour les transactions importées depuis août 2025, 'information' contenait le libellé brut.
        // On le déplace dans la nouvelle colonne 'libelle_brut' et on libère 'information' pour l'usage utilisateur.
        Migration(version: 9, statements: [
            "ALTER TABLE transactions ADD COLUMN libelle_brut TEXT DEFAULT NULL;",
            "UPDATE transactions SET libelle_brut = information, information = NULL WHERE date_op >= '2025-08-01';",
        ]),

        // v10 — types de comptes et transferts internes
        // comptes.type : COURANT | EPARGNE | DIFFERE | AUTRE
        // tiers.linked_compte_id : pointe vers le compte destination d'un virement interne
        //   → permet d'exclure les virements internes des graphiques du dashboard
        Migration(version: 10, statements: [
            "ALTER TABLE comptes ADD COLUMN type TEXT NOT NULL DEFAULT 'COURANT';",
            "ALTER TABLE tiers ADD COLUMN linked_compte_id INTEGER REFERENCES comptes(id);",
        ]),

        // v11 — catégorie NULL = "Non catégorisé" (supprime la dépendance à l'id 40)
        // La base JavaApp peut avoir categorie_id NOT NULL — on reconstruit la table
        // pour supprimer cette contrainte avant de passer les valeurs à NULL.
        Migration(version: 11, statements: [
            "UPDATE tiers SET category_id = NULL WHERE category_id = 40;",
            // Reconstruit transactions sans NOT NULL sur categorie_id
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

        // v12 — schéma de la base de données en anglais
        // Tables : comptes→accounts, category→categories, tiers→payees, mdp→payment_types
        // Colonnes : comptes_id→account_id, tiers_id→payee_id, categorie_id→category_id,
        //            mdp_id→payment_type_id, montant→amount, date_op→tx_date,
        //            remboursement→reimbursement_payee_id, cm_name→regex,
        //            linked_compte_id→linked_account_id
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

        // v13 — module Investissements (comptes + positions)
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

        // v14 — cache local de l'historique de prix des investissements
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

        // v15 — module Budget & Prévisions
        // recurring_patterns : dépenses/revenus récurrents détectés ou saisis manuellement
        // budget_envelopes    : enveloppes budgétaires par catégorie et période
        // budget_previsions   : échéances prévisionnelles (liées ou non à une transaction réelle)
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

        // v16 — date de début/fin pour les motifs récurrents
        // start_date : date à partir de laquelle les prévisions sont générées
        // end_date   : date de fin optionnelle (NULL = sans fin)
        Migration(version: 16, statements: [
            "ALTER TABLE recurring_patterns ADD COLUMN start_date TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE recurring_patterns ADD COLUMN end_date TEXT;",
            // Initialise start_date à created_at pour les motifs existants
            "UPDATE recurring_patterns SET start_date = created_at WHERE start_date = '';",
        ]),

        // v17 — réparation FK Tricount remboursements
        // Les bases migrées depuis l'ancien schéma peuvent encore avoir tricount_reimbursements
        // pointant vers tiers(id). On reconstruit la table pour la faire pointer vers payees(id).
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

        // v19 — Engine integration: étend payees avec lieu/groupe/lien moteur, ajoute payee_groups.
        // - city/country/address : localisation d'instance (un payee = un lieu)
        // - engine_merchant_id   : ID canonique côté NemorisEngine (ex "carrefour_market") ; nullable
        // - group_id             : appartenance à une chaîne (ex "Carrefour Market" en groupe)
        // - custom               : 1 = créé par l'utilisateur sans lien moteur (personne, freelance…)
        // Aucune colonne n'est obligatoire : un payee existant reste valide tel quel.
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

        // v20 — AXE A : logos de marchands.
        // domain TEXT sur payees : domaine web utilisé pour récupérer le favicon Google.
        // Nullable ; quand vide, MerchantLogoService retombe sur le seed engine
        // (merchants_domains.json) à partir de engine_merchant_id, sinon affiche le fallback
        // SF Symbol de la catégorie.
        Migration(version: 20, statements: [
            "ALTER TABLE payees ADD COLUMN domain TEXT;",
        ]),

        // v21 — AXE C : édition complète des payees.
        // note TEXT sur payees : note libre saisie par l'utilisateur (contexte, alias, etc.).
        Migration(version: 21, statements: [
            "ALTER TABLE payees ADD COLUMN note TEXT;",
        ]),

        // v22 — AXE D + E : import repensé + session persistante.
        // - import_sessions : sauvegarde JSON des [ImportSessionRow] pour reprise après quit.
        //   Une seule session 'active' à la fois (UI doit proposer reprise ou cancel avant new).
        // - csv_mappings : mapping date/montant/libellé indexé par signature du header
        //   (concaténation des noms de colonnes), réutilisé automatiquement pour les imports
        //   suivants du même format de CSV.
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

        // v23 — AXE B : cache d'enrichissement multi-sources (Sirene + LLM + MapKit).
        // Clé = engine_merchant_id quand connu, sinon canonical_name (libellé normalisé).
        // Un seul row par clé : on garde la résolution la plus confiante toutes sources confondues.
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

        // v24 — fix idempotent : s'assure que categories.icon existe.
        // Certains users avaient un user_version >= 18 sans la colonne (DB importée d'un
        // schéma JavaApp ou app installée avant v18). L'ALTER est tolérant aux doublons
        // ("duplicate column name" avalé par migrateIfNeeded), donc safe pour tous.
        // On ne re-peuple PAS les icônes pour ne pas écraser les choix custom du user.
        Migration(version: 24, statements: [
            "ALTER TABLE categories ADD COLUMN icon TEXT;",
        ]),

        // v25 — Typage des tiers (merchant/contact/internal/organization).
        // tier_type : permet de distinguer un commerçant d'un contact P2P pour adapter
        //             l'UI (avatar, champs pertinents) et la résolution moteur.
        //             Backfill : tous en 'merchant' (sécuritaire) — l'user re-type
        //             manuellement les contacts depuis PayeeDetailView.
        // contact_identifier : ID local CNContact (CNContactStore.unifiedContact)
        //             pour récupérer la photo + nom depuis le carnet iOS de l'user.
        //             100% local, demande permission lazy au premier lien.
        Migration(version: 25, statements: [
            "ALTER TABLE payees ADD COLUMN tier_type TEXT NOT NULL DEFAULT 'merchant';",
            "ALTER TABLE payees ADD COLUMN contact_identifier TEXT;",
        ]),

        // v26 — Cleanup des tables budget fantômes.
        // budget_prevision_overrides et budget_prevision_rules ont été créées lors d'une
        // expérimentation antérieure (ou manuellement via la console SQL) et ne sont
        // référencées NULLE PART dans le code actuel (ni BudgetRepository, ni migrations,
        // ni DatabaseSchemaView, ni SimulatorSeeder). Drop sécurisé via IF EXISTS pour
        // ne casser aucun appareil — les bases neuves ne les ont simplement jamais eues.
        Migration(version: 26, statements: [
            "DROP TABLE IF EXISTS budget_prevision_overrides;",
            "DROP TABLE IF EXISTS budget_prevision_rules;",
        ]),

        // v27 — Cleanup des tables legacy (AXE H).
        // Audit complet : aucune de ces tables n'est référencée dans le code actuel
        // (ni repositories, ni migrations, ni DatabaseSchemaView, ni seed). Les tables
        // v1 sont des reliques de l'app pré-rebrand (anciens noms français + table mdp
        // pour une feature mots de passe jamais finie). Drop IF EXISTS → safe.
        //
        //   - tiers_patterns : expérimentation jamais finalisée (comme budget overrides v26)
        //   - mdp            : "mots de passe" v1, jamais utilisée
        //   - comptes        : remplacée par `accounts` lors des migrations ultérieures
        //   - category       : (singulier) remplacée par `categories`
        //   - tiers          : (legacy) remplacée par `payees`
        Migration(version: 27, statements: [
            "DROP TABLE IF EXISTS tiers_patterns;",
            "DROP TABLE IF EXISTS mdp;",
            "DROP TABLE IF EXISTS comptes;",
            "DROP TABLE IF EXISTS category;",
            "DROP TABLE IF EXISTS tiers;",
        ]),

        // v28 — AXE K : multi-ordres par position
        // Avant : 1 ligne investment_positions = 1 transaction implicite (qty + PRU).
        // Inconvénient : impossible de suivre un BUY + un SELL + un dividende, ni
        // d'avoir un historique chronologique des opérations pour le chart évolution.
        //
        // Après : la position reste un "label" (ticker, asset_name) + la qty/PRU
        // sont DÉRIVÉS à la volée depuis la table investment_orders. Méthode PRU :
        // moyenne pondérée des BUY (Σ qty×price + fees / Σ qty). FIFO pour fiscalité
        // CTO calculable séparément en mode export si besoin.
        //
        // Types supportés : 'BUY', 'SELL', 'DIV' (dividende reçu). 'SPLIT' hors scope MVP.
        //
        // Backfill : pour chaque position existante avec quantity > 0, on crée
        // 1 ordre BUY rétroactif avec qty + average_buy_price + purchase_date.
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
            // Backfill : 1 BUY rétroactif par position existante (préserve l'historique)
            """
            INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, fees, executed_at)
            SELECT id, 'BUY', quantity, average_buy_price, 0, purchase_date
            FROM investment_positions
            WHERE quantity > 0;
            """
        ]),

        // v29 — AXE I Couche 0 : live sync APIs publiques (opt-in)
        //
        // Permet à l'user de lier un compte d'investissement à une source externe
        // read-only (Binance, wallets EVM/BTC/SOL) pour syncro automatique des
        // positions + transactions, sans backend Nemoris.
        //
        //   - provider_id : ID du provider Swift (cf. InvestmentLiveSyncProvider.id)
        //   - display_name : libellé user-defined (ex: "Binance perso", "MetaMask main")
        //   - account_id : compte investments cible (mapping 1:1 livre les positions
        //     synchronisées dans ce compte). NULL = orphelin (créé sans compte lié encore)
        //   - config_json : metadata spécifiques au provider (ex: {"chain":"polygon"}
        //     pour EVM, {"address":"bc1q..."} pour BTC, etc.). Stocké en JSON pour
        //     flexibilité — pas besoin d'ajouter une migration à chaque nouveau champ
        //   - last_sync_* : feedback UI sur la dernière sync (status + message d'erreur)
        //   - show_tokens_without_price : choix user d'afficher (1) ou masquer (0) les
        //     tokens dont CoinGecko n'a pas de prix
        //
        // Sécurité : les credentials (API keys, secrets) sont stockés en Keychain iOS,
        // PAS en base SQLite. La table ne contient que des métadonnées non-sensibles.
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

        // v30 — Normalisation : suppression des colonnes DÉRIVÉES.
        // - investment_positions.quantity, average_buy_price, purchase_date
        //   → strictement dérivées des investment_orders (AXE K), calculées
        //     à la volée via SQL au moment du fetch (JOIN + GROUP BY).
        // - investment_accounts.current_value, invested_amount
        //   → dérivées des positions (sum) et des ordres (sum BUY costs),
        //     calculées de la même façon au fetch.
        //
        // SQLite ≥ 3.35 (iOS 14+) supporte ALTER TABLE DROP COLUMN nativement.
        // Pas de risque de perte de données utiles : ces valeurs étaient
        // soit caches stales (accounts), soit déjà recalculées à chaque
        // recomputePositionFromOrders (positions).
        Migration(version: 30, statements: [
            "ALTER TABLE investment_positions DROP COLUMN quantity;",
            "ALTER TABLE investment_positions DROP COLUMN average_buy_price;",
            "ALTER TABLE investment_positions DROP COLUMN purchase_date;",
            "ALTER TABLE investment_accounts DROP COLUMN current_value;",
            "ALTER TABLE investment_accounts DROP COLUMN invested_amount;"
        ]),

        // v31 — Ajout de la colonne `isin` sur les positions. L'ISIN est
        // l'identifiant universel (12 chars, ex FR0000121329) qui permet de
        // résoudre vers le bon symbole tradable via OpenFIGI. Sans cette
        // colonne, la sync Yahoo échoue souvent (le ticker stocké est souvent
        // un nom d'actif comme "THALES" au lieu du vrai symbole "HO.PA").
        // Position.ticker reste, mais désormais isin a priorité pour la sync.
        Migration(version: 31, statements: [
            "ALTER TABLE investment_positions ADD COLUMN isin TEXT;"
        ]),

        // v32 — Déduplication de investment_price_history.
        //
        // BUG critique avant cette migration : `savePriceHistory` faisait un
        // simple INSERT sans ON CONFLICT, donc chaque Sync Now ré-insérait
        // 365 lignes (1 an de cours quotidiens) pour le même ticker. Après
        // N syncs : N × 365 doublons. Pour 50 positions + 12 syncs / an, on
        // arrivait à ~220 000 lignes redondantes en 1 an.
        //
        // 2 étapes :
        //   1. DELETE les doublons existants : on garde la ligne avec le
        //      MIN(rowid) pour chaque (identifier, price_date).
        //   2. CREATE UNIQUE INDEX → impossible d'en ajouter à l'avenir,
        //      combiné avec INSERT OR REPLACE dans le repo (upsert atomique).
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

        // v33 — AXE I Couche 1.5 : dédup des ordres synchronisés depuis le live sync
        //
        // `external_id` stocke un ID externe stable retourné par le provider (Binance
        // tradeId, txHash blockchain, etc.) préfixé par le provider :
        //   - "binance_<symbol>_<tradeId>"  pour Binance
        //   - "evm_<chain>_<txHash>"        pour wallets EVM (futur)
        //   - "btc_<txid>"                  pour wallets BTC (futur)
        //   - "sol_<signature>"             pour wallets Solana (futur)
        //
        // Sans cette colonne, chaque `Synchroniser maintenant` ré-insérait les mêmes
        // trades historiques en doublon. L'INDEX UNIQUE garantit la dédup atomique
        // via `INSERT OR IGNORE` côté repo.
        //
        // Les ordres saisis manuellement par l'user ont `external_id = NULL` →
        // pas affectés par la contrainte d'unicité.
        Migration(version: 33, statements: [
            "ALTER TABLE investment_orders ADD COLUMN external_id TEXT;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_invest_orders_external_id ON investment_orders(external_id) WHERE external_id IS NOT NULL;"
        ]),

        // v34 — Trésorerie disponible sur le compte.
        //
        // Pour un PEA, CTO, ou même un wallet : il y a souvent du cash en
        // attente (dividendes pas réinvestis, ventes en attente de réemploi,
        // dépôts récents). Cette liquidité fait partie du capital total du
        // compte mais n'est pas modélisée comme une position (pas d'asset,
        // pas de cours). On la stocke comme une colonne directe sur l'account.
        //
        // Le total compte affiché à l'user devient :
        //   sum(positions.current_value) + cash_balance
        //
        // Édité manuellement par l'user via le form compte. Pour les comptes
        // LiveSync (Binance, wallets), on pourra plus tard remonter le solde
        // EUR/USDT automatiquement comme cashBalance.
        Migration(version: 34, statements: [
            "ALTER TABLE investment_accounts ADD COLUMN cash_balance REAL NOT NULL DEFAULT 0;"
        ]),

        // v35 — DROP TABLE investment_price_history.
        //
        // L'historique des cours n'est pas data utilisateur (prix récupérables
        // gratuitement via Yahoo/Stooq/CoinGecko) — il n'a donc pas à polluer
        // la base SQLite de l'user, qui doit représenter UNIQUEMENT ce qu'il
        // a créé ou importé (positions, ordres, transactions, etc.).
        //
        // Le cache est désormais dans `Library/Caches/nemoris/investment_price_history.json`
        // (gestion via `PriceHistoryCache`), purgeable par iOS si manque d'espace
        // et jamais inclus dans iCloud/backup user.
        //
        // L'utilisateur déclenchera un re-sync de ses positions via le bouton
        // "Recharger" du dashboard Investments si nécessaire.
        Migration(version: 35, statements: [
            "DROP TABLE IF EXISTS investment_price_history;"
        ]),

        // v36 — DROP TABLE enrichment_cache.
        //
        // Même logique que v35 : ce cache vient d'APIs externes (Sirene, MapKit,
        // Apple Foundation Models) — pas data utilisateur, donc pas dans la
        // base SQLite user. Cache disque maintenant dans
        // `Library/Caches/nemoris/enrichment_cache.json` via `JSONFileCache`.
        Migration(version: 36, statements: [
            "DROP TABLE IF EXISTS enrichment_cache;"
        ]),

        // v37 — Module Patrimoine (Net Worth Tracker).
        //
        // 3 tables indépendantes pour modéliser le patrimoine total de l'user :
        //
        //   • patrimoine_real_estate : biens immobiliers (saisie 100% manuelle,
        //     plus-value estimée = current_value - purchase_price).
        //
        //   • patrimoine_loans : prêts & dettes. La colonne `loan_type` discrimine
        //     la formule de calcul du capital restant dû :
        //       - AMORT             : amortissement classique (mensualité fixe)
        //       - IN_FINE           : capital remboursé en bloc à l'échéance
        //       - DEFERRED_TOTAL    : différé total puis amortissement
        //       - DEFERRED_PARTIAL  : différé partiel (intérêts seuls) puis amort
        //       - REVOLVING         : crédit renouvelable, valeur manuelle
        //     La logique de calcul vit dans LoanCalculator.swift (Swift pur, testable).
        //
        //   • patrimoine_assets : éléments "Mobilier & Liquidités" (cash, livrets,
        //     PEA, etc.). Chaque asset est soit **standalone** (manual_value), soit
        //     **linké** à un compte existant — exactement 1 des 2 colonnes de link
        //     peut être renseignée (forcé par UNIQUE INDEX partiels).
        //     Linking soft (ON DELETE SET NULL) → si l'user supprime son compte
        //     bancaire/investment, l'asset bascule auto en standalone avec la
        //     dernière valeur connue (last_known_value), pas de cascade destructrice.
        //
        // Les UNIQUE INDEX partiels sur linked_account_id et linked_investment_account_id
        // garantissent qu'un compte ne peut être lié qu'à 1 seul asset Patrimoine
        // (évite la double-comptabilisation par construction).
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

        // v38 — Coût d'assurance mensuelle sur les prêts.
        //
        // L'assurance emprunteur n'est pas un intérêt bancaire — elle ne modifie
        // PAS le capital restant dû ni le calcul d'amortissement. C'est une charge
        // séparée que l'user supporte tous les mois en plus de la mensualité du
        // prêt (typiquement 0.20% à 0.50% du capital initial par an, lissée).
        //
        // Stockée en montant mensuel direct (pas en %) pour matcher ce que l'user
        // voit sur son contrat. Affichée dans le form + dans la row du prêt + dans
        // les totaux (coût mensuel global = Σ monthlyPayment + Σ insuranceMonthly).
        Migration(version: 38, statements: [
            "ALTER TABLE patrimoine_loans ADD COLUMN insurance_monthly REAL NOT NULL DEFAULT 0;"
        ]),

        // v39 — Objectifs financiers (Goals).
        //
        // Table simple : un goal = un nom + un type + un montant cible + une
        // deadline optionnelle. Le "progress" est calculé en mémoire en croisant
        // avec le PatrimoineSnapshot (cf. GoalsViewModel.progress(for:)).
        //
        // Types supportés :
        //   • SAVINGS     : atteindre X € d'épargne (totalAssetsValue)
        //   • NETWORTH    : atteindre X € de patrimoine net (assets + immo − dettes)
        //   • DEBT_PAYOFF : rembourser X € de dette (target = 0 = 100%)
        //   • CUSTOM      : objectif manuel (l'user met à jour le "current" en
        //                   éditant le goal — pas de calcul auto)
        //
        // Volontairement pas de FK vers patrimoine_assets ou patrimoine_loans
        // au MVP — un goal global "Atteindre 50k€ d'épargne" suffit dans 90%
        // des cas. Si besoin de ciblage par asset précis plus tard, on ajoutera
        // une colonne `linked_asset_id INTEGER REFERENCES patrimoine_assets(id)
        // ON DELETE SET NULL`.
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

        // v40 — AXE L Couche L.0 : instrumentation sync CloudKit.
        //
        // Socle du dirty-tracking pour la future synchronisation CKSyncEngine :
        //   • tables d'infra : sync_meta (KV interne), sync_pending (queue
        //     d'upload), sync_tombstones (suppressions à propager)
        //   • sur les 7 tables cœur du ledger : colonnes `uuid` (identité
        //     multi-appareils, backfillée via randomblob) + `updated_at`
        //     (horodatage ISO8601 pour la résolution de conflits LWW)
        //     + index UNIQUE sur uuid.
        //
        // Les INTEGER PRIMARY KEY restent les PK/FK locales — le uuid est
        // l'identité qui voyage. Les triggers de tracking ne sont PAS dans
        // cette migration : ils sont (ré)installés à chaque boot par
        // SyncSchema.installTriggers() en fin de migrateIfNeeded().
        //
        // Les rows existantes ne sont PAS mises en sync_pending : lors de
        // l'activation de la sync (Couche L.1), un scan complet initial
        // remplira la queue.
        //
        // Tables secondaires (recurring_patterns, investment_*, patrimoine_*,
        // goals, tricount_*) → Couche L.3, migration future.
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

        // v41 — AXE L Couche L.1 : état CKSyncEngine par row.
        //
        //   • sync_record_meta : system fields du CKRecord archivés
        //     (encodeSystemFields) — nécessaires pour ré-uploader une row sans
        //     provoquer un conflit serverRecordChanged à chaque save.
        //   • sync_unresolved_refs : FK distantes dont la row cible n'est pas
        //     encore arrivée (les batchs CloudKit n'ont pas d'ordre garanti).
        //     Re-résolues après chaque batch appliqué. column_name préfixé
        //     "__tag__" = lien transaction_tags en attente (pas une colonne).
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

        // v42 — AXE L Couche L.3 : extension de la sync aux modules
        // Budget / Investissements / Patrimoine / Objectifs / Tricount.
        //
        // Mêmes colonnes uuid/updated_at + backfill + index UNIQUE que v40,
        // sur les 14 tables listées dans SyncSchema.secondaryTablesV42.
        // Les triggers sont installés comme d'habitude par installTriggers()
        // en fin de migrateIfNeeded().
        //
        // Auto-enqueue conditionnel : contrairement à v40 (sync pas encore
        // activable), des appareils ont ICI la sync déjà active — le scan
        // initial de enable() ne repassera pas. Le dernier statement par table
        // met donc ses rows en sync_pending, MAIS seulement si
        // sync_meta['sync_enabled'] = '1' (sur un appareil sans sync, la
        // sous-requête rend NULL → prédicat faux → aucune row queueée,
        // l'activation future fera son scan complet normalement).
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

        // v43 — AXE L : file des records distants différés (FK NOT NULL dont
        // la cible n'est pas encore arrivée). Avant ce fix, l'INSERT violait
        // la contrainte NOT NULL et le record était PERDU définitivement
        // (CloudKit ne re-livre pas un record fetché non appliqué). Cas réel :
        // à la descente initiale sur le Mac, les investment_orders arrivés
        // avant leurs investment_positions (et des positions avant leur
        // compte) ont tous été rejetés → module Investissements vide.
        // Le payload complet est désormais stocké dans sync_deferred_rows et
        // rejoué en fin de batch dès que les cibles existent (SyncPayloadStore).
        Migration(version: 43, statements: SyncSchema.deferredRowsDDL),

        // v44 — AXE R : remboursement unifié transaction simple + Tricount.
        // Remplace `transactions.reimbursement_payee_id` (colonne posée sur la
        // table cœur, présente NULL sur CHAQUE transaction) et généralise
        // `tricount_reimbursements` en une seule table `reimbursements`,
        // rattachée via transaction_id XOR tricount_entry_id.
        //
        // Le CHECK XOR n'est pas qu'une contrainte d'intégrité : c'est ce qui
        // permet à sync_deferred_rows (v43) de rattraper le cas où un batch
        // CloudKit livre une ligne reimbursements avant sa transaction/entrée
        // cible — sans lui, l'INSERT réussirait avec les 2 FK à NULL (ligne
        // fantôme jamais réparée) au lieu d'échouer et d'être différée.
        //
        // amount reste NULL côté transaction_id (montant = celui de la
        // transaction entière, pas de notion de part) ; requis en pratique
        // côté tricount_entry_id (part personnelle calculée depuis
        // tricount_shares, indépendante du montant de l'entrée).
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

        // v45 — SMART-IMPORT : la session d'import couvre les DEUX destinations.
        //
        // Le cache de session (reprise après fermeture, rappel 12 h, survie au
        // redémarrage) n'existait que pour les transactions. Côté
        // investissements, un résultat d'analyse vivait uniquement en mémoire
        // dans `DocumentImportCoordinator` : relancer l'app le perdait, alors
        // qu'une analyse de relevé se compte en dizaines de secondes.
        //
        // `destination` discrimine le contenu de `rows_json` :
        //   • 'transactions'  → [ImportSessionRow]   (inchangé)
        //   • 'investments'   → ImportBatchResult
        //
        // ⚠️ DEFAULT 'transactions' : les sessions déjà persistées se relisent
        // à l'octet près, sans réécriture de leur JSON. C'est ce qui permet à
        // un utilisateur ayant un import en cours de mettre à jour l'app sans
        // le perdre.
        Migration(version: 45, statements: [
            "ALTER TABLE import_sessions ADD COLUMN destination TEXT NOT NULL DEFAULT 'transactions';",
        ]),

        // v46 — SMART-IMPORT §3 : métadonnées de transaction LIBRES.
        //
        // `transactions.payment_type_id` était le seul attribut libre qu'un
        // utilisateur pouvait poser hors tiers/catégorie/tags — et il imposait
        // une sémantique (« mode de paiement ») à tout le monde, y compris à qui
        // voulait suivre autre chose (compte joint/perso, pro/perso, projet…).
        //
        // Il devient une métadonnée parmi d'autres, définies par l'utilisateur.
        //
        // ⚠️ BASCULE COMPLÈTE, pas coexistence : l'UI ne lit plus que les
        // métadonnées. Faire vivre les deux en parallèle donnerait deux endroits
        // où éditer la même information — le motif de divergence que ce dépôt
        // combat partout ailleurs (cf. AXE Q, les quatre calculs d'enveloppes).
        //
        // ⚠️ `payment_types` et `transactions.payment_type_id` sont DÉPRÉCIÉS,
        // pas supprimés : doctrine AXE H (on ne retire une colonne qu'une fois
        // confirmé que plus rien ne la référence). Les données y restent
        // intactes, ce qui rend la migration réversible.
        //
        // ⚠️ La clé « Mode de paiement » n'est créée QUE si la base contient
        // vraiment des modes de paiement utilisés. Une base neuve n'en a aucun —
        // c'est voulu : le nouvel utilisateur ne verra jamais ce concept, il
        // crée les clés dont il a l'usage.
        Migration(version: 46, statements: [
            """
            CREATE TABLE IF NOT EXISTS transaction_metadata_keys (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                icon       TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                -- Rôle fonctionnel optionnel. Seule valeur connue :
                -- 'payment_method', qui désigne la clé que l'import remplit
                -- automatiquement depuis ce qu'il déduit du libellé (CB,
                -- VIREMENT, PRELEVEMENT…). Sans elle, l'indice d'import est
                -- simplement ignoré — pas de clé fantôme créée dans le dos de
                -- l'utilisateur.
                role       TEXT,
                created_at TEXT NOT NULL,
                uuid       TEXT,
                updated_at TEXT
            );
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmk_name ON transaction_metadata_keys(name COLLATE NOCASE);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmk_uuid ON transaction_metadata_keys(uuid);",
            // Une seule clé peut porter un rôle donné, sinon l'import ne saurait
            // pas laquelle remplir.
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
            // Une valeur par clé et par transaction. Une transaction porte donc
            // PLUSIEURS métadonnées (contrairement à payment_type_id, 0..1).
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmv_pair ON transaction_metadata_values(transaction_id, key_id);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tmv_uuid ON transaction_metadata_values(uuid);",
            "CREATE INDEX IF NOT EXISTS idx_tmv_key ON transaction_metadata_values(key_id);",

            // Reprise des données existantes — conditionnelle.
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
            // Mise en file de sync, comme v42/v44 : uniquement si la sync est
            // DÉJÀ active sur cet appareil (le scan initial d'`enable()` ne
            // repassera pas dessus).
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
    ]

    // MARK: - Helpers privés

    private static func userVersion(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func fallbackURL() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("FinanceMobileIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(fallbackFileName)
    }
}
