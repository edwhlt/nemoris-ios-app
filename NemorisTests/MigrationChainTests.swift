import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// Chaîne de migrations du schéma.
///
/// C'est le seul code de l'application dont un défaut est IRRÉVERSIBLE chez
/// l'utilisateur : une migration ratée s'applique à sa base réelle, et aucune
/// mise à jour ultérieure ne peut reconstituer ce qu'elle a détruit. Elle
/// n'était jusqu'ici vérifiée par rien.
@Suite("Chaîne de migrations")
struct MigrationChainTests {

    /// Base vide dans un dossier temporaire, sans aucune migration appliquée.
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

    // MARK: - Application complète

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

        // Chaque lancement de l'app rejoue ce chemin : il doit être un no-op.
        #expect(DatabaseManager.migrate(at: url) == nil)

        #expect(version(url) == apresPremier)
        #expect(tables(url) == tablesAvant, "aucune table créée ni perdue au second passage")
    }

    @Test("La version du schéma atteint celle de la dernière migration")
    func versionFinale() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // Si une migration s'ajoute sans que la version suive, les appareils
        // déjà à jour ne la recevront jamais.
        let attendue = DatabaseManager.migrations.map(\.version).max() ?? 0
        #expect(version(url) == attendue, "obtenu : \(version(url)), attendu : \(attendue)")
    }

    // MARK: - Cohérence de la chaîne

    @Test("Les numéros de version sont uniques et strictement croissants")
    func numerotationCoherente() {
        let versions = DatabaseManager.migrations.map(\.version)

        // Deux migrations au même numéro : la seconde ne s'appliquerait jamais
        // sur un appareil ayant déjà passé la première.
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

    // MARK: - Le schéma produit

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
        // Ces tables ont été renommées puis supprimées ; les voir réapparaître
        // signalerait une migration remise dans le désordre.
        for obsolete in ["tiers", "comptes", "category", "mdp", "tiers_patterns"] {
            #expect(!presentes.contains(obsolete), "table héritée toujours là : \(obsolete)")
        }
    }

    @Test("Toutes les tables synchronisées existent réellement")
    func tablesSynchroniseesPresentes() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // Une table déclarée synchronisée mais absente du schéma ferait échouer
        // la synchronisation au premier envoi, sur l'appareil de l'utilisateur.
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

    /// Fabrique une base au schéma d'une version DONNÉE, en n'appliquant que les
    /// migrations jusqu'à elle.
    ///
    /// ⚠️ Redescendre `user_version` sur une base déjà à jour ne simule PAS un
    /// appareil en retard : ça produit un état impossible (schéma récent,
    /// marqueur ancien) où une migration rejouée référence une table qu'une
    /// migration ultérieure a remplacée. Il faut vraiment s'arrêter en chemin.
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

        // Chaque version a pu être installée chez un utilisateur : la chaîne
        // doit mener de n'importe laquelle jusqu'à la tête, sans intervention.
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

        // Un utilisateur de longue date et un nouveau doivent avoir exactement
        // le même schéma : sinon une requête marche chez l'un et pas chez
        // l'autre, et le défaut ne se voit jamais en développement.
        #expect(tables(urlAncien) == tables(urlNeuf),
                "écart : \(tables(urlAncien).symmetricDifference(tables(urlNeuf)).sorted())")
    }

    // MARK: - Détection de dérive de schéma

    @Test("Un commentaire SQL différent dans une table déjà migrée n'est pas une dérive")
    func commentaireSeulNestPasUneDerive() throws {
        let (dossier, url) = try baseVierge()
        defer { try? FileManager.default.removeItem(at: dossier) }
        #expect(DatabaseManager.migrate(at: url) == nil)

        // Reproduit une base migrée AVANT un simple passage de traduction des
        // commentaires (FR → EN, ou l'inverse) : la table a déjà été créée
        // une fois, `CREATE TABLE IF NOT EXISTS` ne la retouche jamais — sa
        // colonne `sql` dans sqlite_master garde le texte, commentaire
        // compris, du jour où elle a été créée pour de vrai.
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

        // Contre-épreuve du test précédent : un vrai écart structurel (ici,
        // la colonne `role` a disparu) doit rester détecté malgré le
        // nettoyage des commentaires.
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
