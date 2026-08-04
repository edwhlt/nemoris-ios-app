import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// Vérifie la chaîne de migrations elle-même.
///
/// Ces tests couvrent un angle mort : les migrations n'étaient jusqu'ici
/// validées que par leur exécution sur l'appareil de l'utilisateur. Une
/// migration fautive y est irréversible.
@Suite("Schéma et migrations")
struct SchemaTests {

    @Test("Une base vierge migre jusqu'à la version courante")
    func vierge() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        #expect(db.schemaVersion >= 44,
                "migrations appliquées jusqu'à v\(db.schemaVersion)")
    }

    @Test("Les tables du cœur métier sont créées")
    func tablesCoeur() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let attendues: Set<String> = [
            "accounts", "payees", "payee_groups", "categories", "payment_types",
            "transactions", "tags", "transaction_tags", "reimbursements",
        ]
        #expect(attendues.isSubset(of: db.tables),
                "manquantes : \(attendues.subtracting(db.tables).sorted())")
    }

    @Test("Les tables héritées sont bien supprimées")
    func tablesLegacy() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        // Supprimées par les migrations v26 et v27. Leur réapparition
        // signalerait une migration réintroduite par erreur.
        let interdites: Set<String> = [
            "tiers", "comptes", "category", "mdp", "tiers_patterns",
            "budget_prevision_overrides", "budget_prevision_rules",
            "tricount_reimbursements",
        ]
        #expect(interdites.isDisjoint(with: db.tables),
                "encore présentes : \(interdites.intersection(db.tables).sorted())")
    }

    @Test("Rejouer les migrations sur une base déjà à jour ne change rien")
    func idempotence() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let versionAvant = db.schemaVersion
        let tablesAvant = db.tables

        let erreurs = DatabaseManager.migrate(at: db.url)

        #expect(erreurs == nil, "second passage en erreur : \(erreurs ?? "")")
        #expect(db.schemaVersion == versionAvant)
        #expect(db.tables == tablesAvant)
    }

    @Test("Chaque table synchronisée porte uuid et updated_at")
    func colonnesDeSync() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        for table in SyncSchema.syncedTables where db.tables.contains(table) {
            let colonnes = db.store.read { handle -> Set<String> in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
                    return []
                }
                defer { sqlite3_finalize(stmt) }
                var noms = Set<String>()
                while sqlite3_step(stmt) == SQLITE_ROW {
                    noms.insert(string(from: stmt, index: 1))
                }
                return noms
            } ?? []

            #expect(colonnes.contains("uuid"), "\(table) sans colonne uuid")
            #expect(colonnes.contains("updated_at"), "\(table) sans colonne updated_at")
        }
    }

    @Test("Les tables d'infrastructure de synchronisation existent")
    func tablesDeSync() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let attendues: Set<String> = [
            "sync_meta", "sync_pending", "sync_tombstones",
            "sync_record_meta", "sync_unresolved_refs", "sync_deferred_rows",
        ]
        #expect(attendues.isSubset(of: db.tables),
                "manquantes : \(attendues.subtracting(db.tables).sorted())")
    }
}
