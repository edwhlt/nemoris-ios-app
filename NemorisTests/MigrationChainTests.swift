import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// The schema's migration chain.
///
/// This is the only code in the app whose defect is IRREVERSIBLE for
/// the user: a failed migration applies to their real database, and no
/// later update can reconstitute what it destroyed. Until now
/// nothing verified it.
@Suite("Chaîne de migrations")
struct MigrationChainTests {

    /// An empty database in a temp directory, with no migration applied.
    private func baseVierge() throws -> (URL, URL) {
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nemoris-migrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let url = dossier.appendingPathComponent("finance.sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (dossier, url)
    }

    private func version(_ url: URL) -> Int {
        SQLiteStore(databaseURL: url).read { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        } ?? 0
    }

    private func tables(_ url: URL) -> Set<String> {
        SQLiteStore(databaseURL: url).read { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';",
                                     -1, &stmt, nil) == SQLITE_OK else { return Set<String>() }
            defer { sqlite3_finalize(stmt) }
            var noms = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { noms.insert(String(cString: c)) }
            }
            return noms
        } ?? []
    }

    // MARK: - Full application

    @Test("Une base vierge reçoit toute la chaîne sans erreur")
    func chaineComplete() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }

        #expect(DatabaseManager.migrate(at: url) == nil, "aucune migration ne doit échouer")
        #expect(version(url) > 0)
    }

    @Test("Rejouer les migrations sur une base à jour ne fait rien")
    func rejeuInoffensif() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)
        let apresPremier = version(url)
        let tablesAvant = tables(url)

        // Every app launch replays this path: it must be a no-op.
        #expect(DatabaseManager.migrate(at: url) == nil)

        #expect(version(url) == apresPremier)
        #expect(tables(url) == tablesAvant, "aucune table créée ni perdue au second passage")
    }

    @Test("La version du schéma atteint celle de la dernière migration")
    func versionFinale() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // If a migration is added without bumping the version, devices
        // already up to date will never receive it.
        let attendue = DatabaseManager.migrations.map(\.version).max() ?? 0
        #expect(version(url) == attendue, "obtenu : \(version(url)), attendu : \(attendue)")
    }

    // MARK: - Chain consistency

    @Test("Les numéros de version sont uniques et strictement croissants")
    func numerotationCoherente() {
        let versions = DatabaseManager.migrations.map(\.version)

        // Two migrations at the same number: the second would never
        // apply on a device that already went through the first.
        #expect(Set(versions).count == versions.count, "numéros en double : \(versions)")
        #expect(versions == versions.sorted(),
                "la chaîne doit être ordonnée : \(versions)")
        #expect(versions.first == 1, "la chaîne part de 1")
    }

    @Test("Aucune migration n'est vide")
    func migrationsNonVides() {
        for migration in DatabaseManager.migrations {
            #expect(!migration.statements.isEmpty,
                    "la migration v\(migration.version) ne fait rien")
        }
    }

    // MARK: - The resulting schema

    @Test("Les tables du cœur métier existent après migration")
    func tablesEssentielles() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        let presentes = tables(url)
        for table in ["transactions", "payees", "categories", "accounts", "tags",
                      "transaction_tags", "reimbursements",
                      "transaction_metadata_keys", "transaction_metadata_values"] {
            #expect(presentes.contains(table), "table manquante : \(table)")
        }
    }

    @Test("Les tables héritées des premières versions ont bien été retirées")
    func tablesHeriteesSupprimees() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        let presentes = tables(url)
        // These tables were renamed then dropped; seeing them reappear
        // would signal a migration reinserted out of order.
        for obsolete in ["tiers", "comptes", "category", "mdp", "tiers_patterns"] {
            #expect(!presentes.contains(obsolete), "table héritée toujours là : \(obsolete)")
        }
    }

    @Test("Toutes les tables synchronisées existent réellement")
    func tablesSynchroniseesPresentes() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // A table declared as synced but missing from the schema would fail
        // sync on the first send, on the user's device.
        let presentes = tables(url)
        for table in SyncSchema.syncedTables {
            #expect(presentes.contains(table), "table synchronisée absente : \(table)")
        }
    }

    @Test("L'infrastructure de synchronisation est en place")
    func infrastructureDeSynchronisation() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        let presentes = tables(url)
        for table in ["sync_meta", "sync_pending", "sync_tombstones",
                      "sync_record_meta", "sync_unresolved_refs", "sync_deferred_rows"] {
            #expect(presentes.contains(table), "table d'infrastructure absente : \(table)")
        }
    }

    // MARK: - Reprise partielle

    /// Builds a database at the schema of a GIVEN version, applying only the
    /// migrations up to it.
    ///
    /// ⚠️ Rolling `user_version` back on an already-up-to-date database does NOT
    /// simulate a lagging device: it produces an impossible state (a recent
    /// schema, an old marker) where a replayed migration references a table a
    /// later migration has replaced. It really needs to stop midway.
    private func base(auSchemaDe cible: Int) throws -> (URL, URL) {
        let (dossier, url) = try baseVierge()
        _ = SQLiteStore(databaseURL: url).write { db in
            for migration in DatabaseManager.migrations where migration.version <= cible {
                for statement in migration.statements {
                    sqlite3_exec(db, statement, nil, nil, nil)
                }
            }
            sqlite3_exec(db, "PRAGMA user_version = \(cible);", nil, nil, nil)
        }
        return (dossier, url)
    }

    @Test("La mise à jour aboutit depuis n'importe quelle version publiée")
    func miseAJourDepuisChaqueVersion() throws {
        let versions = DatabaseManager.migrations.map(\.version)
        let tete = try #require(versions.max())

        // Every version may have been installed by a user: the chain
        // must lead from any of them to the head, with no manual step.
        for depart in versions {
            let (dossier, url) = try base(auSchemaDe: depart)
            defer { try? FileManager.default.removeItem(at: dossier) }

            let erreurs = DatabaseManager.migrate(at: url)
            #expect(erreurs == nil, "mise à jour depuis v\(depart) : \(erreurs ?? "")")
            #expect(version(url) == tete, "v\(depart) s'arrête à v\(version(url))")
        }
    }

    @Test("Une mise à jour depuis une ancienne version produit le même schéma qu'une base neuve")
    func schemaIdentiqueApresMiseAJour() throws {
        let (dossierNeuf, urlNeuf) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossierNeuf) }
        #expect(DatabaseManager.migrate(at: urlNeuf) == nil)

        let (dossierAncien, urlAncien) = try base(auSchemaDe: 30)
        defer { try? FileManager.default.removeItem(at: dossierAncien) }
        #expect(DatabaseManager.migrate(at: urlAncien) == nil)

        // A long-time user and a new one must end up with exactly
        // the same schema: otherwise a query works for one and not for
        // the other, and the defect never shows up in development.
        #expect(tables(urlAncien) == tables(urlNeuf),
                "écart : \(tables(urlAncien).symmetricDifference(tables(urlNeuf)).sorted())")
    }

    // MARK: - Schema drift detection

    @Test("Un commentaire SQL différent dans une table déjà migrée n'est pas une dérive")
    func commentaireSeulNestPasUneDerive() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // Reproduces a database migrated BEFORE a plain comment-translation
        // pass (FR → EN, or the reverse): the table was already created
        // once, `CREATE TABLE IF NOT EXISTS` never touches it again — its
        // `sql` column in sqlite_master keeps the text, comments
        // included, from the day it was actually created.
        _ = SQLiteStore(databaseURL: url).write { db in
            sqlite3_exec(db, "DROP TABLE transaction_metadata_keys;", nil, nil, nil)
            sqlite3_exec(db, """
                CREATE TABLE transaction_metadata_keys (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    name       TEXT NOT NULL,
                    icon       TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    -- Rôle fonctionnel optionnel, texte totalement différent
                    -- de celui du fichier source actuel — seul ce commentaire
                    -- change, pas une colonne.
                    role       TEXT,
                    created_at TEXT NOT NULL,
                    uuid       TEXT,
                    updated_at TEXT
                );
                """, nil, nil, nil)
        }

        let resultat = DatabaseManager.detectSchemaDrift(at: url)
        #expect(resultat == .clean, "un commentaire ne doit jamais déclencher une dérive : \(resultat)")
    }

    @Test("Une vraie colonne manquante est bien détectée comme une dérive")
    func colonneManquanteEstDetectee() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // A counter-check for the previous test: a real structural mismatch (here,
        // the `role` column has disappeared) must still be detected despite
        // the comment cleanup.
        _ = SQLiteStore(databaseURL: url).write { db in
            sqlite3_exec(db, "DROP TABLE transaction_metadata_keys;", nil, nil, nil)
            sqlite3_exec(db, """
                CREATE TABLE transaction_metadata_keys (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    name       TEXT NOT NULL,
                    icon       TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    uuid       TEXT,
                    updated_at TEXT
                );
                """, nil, nil, nil)
        }

        guard case .drifted(_, _, let changed) = DatabaseManager.detectSchemaDrift(at: url) else {
            Issue.record("une colonne manquante aurait dû être signalée comme une dérive")
            return
        }
        #expect(changed.contains("transaction_metadata_keys"))
    }
}
