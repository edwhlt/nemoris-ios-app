import Foundation
import SQLite3

/// AXE L — Sync CloudKit chiffrée (Couche L.0 : instrumentation SQLite).
///
/// Ce composant fournit le socle de dirty-tracking nécessaire à la future
/// synchronisation CKSyncEngine :
///
///   • `uuid`        : identité stable multi-appareils de chaque row (les INTEGER
///                     AUTOINCREMENT restent les PK locales et les FK — ils ne
///                     sortent JAMAIS de l'appareil).
///   • `updated_at`  : horodatage ISO8601 UTC de la dernière modification,
///                     utilisé pour la résolution de conflits last-writer-wins.
///   • `sync_pending`    : file des rows modifiées localement à uploader.
///   • `sync_tombstones` : suppressions à propager (le DELETE local ne suffit
///                     pas — il faut dire au serveur "cette row n'existe plus").
///   • `sync_meta`       : clé/valeur interne (flag suppress_triggers, et plus
///                     tard le state sérialisé de CKSyncEngine, tokens, etc.).
///
/// Le tracking est fait par TRIGGERS SQLite (pas par la couche repository) :
/// toute écriture est capturée, y compris la console SQL et les batchs d'import.
/// Les triggers sont (ré)installés à chaque boot par `installTriggers` — ils ne
/// font PAS partie des migrations et peuvent donc évoluer librement.
///
/// ⚠️ Le futur applicateur de changements distants (Couche L.1) devra poser
/// `sync_meta['suppress_triggers'] = '1'` avant d'écrire les rows venues du
/// serveur, puis le remettre à '0' — sinon chaque sync descendante remarquerait
/// les rows comme dirty et créerait une boucle d'écho upload/download.
///
/// ⚠️ Les triggers `trg_sync_*_update` supposent `PRAGMA recursive_triggers`
/// à OFF (le défaut SQLite, jamais modifié dans l'app) : le UPDATE de
/// `updated_at` dans le corps du trigger ne doit pas se re-déclencher lui-même.
enum SyncSchema {

    /// Expression SQL de l'horodatage courant (ISO8601 UTC, précision ms).
    /// Format lexicographiquement comparable : "2026-07-16T14:03:21.417Z".
    private static let nowSQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    /// Garde commune : les triggers sont inertes quand l'applicateur de
    /// changements distants a posé le flag suppress_triggers.
    private static let guardSQL =
        "COALESCE((SELECT value FROM sync_meta WHERE key = 'suppress_triggers'), '0') <> '1'"

    /// Tables synchronisées — TOUTES ont `id INTEGER PRIMARY KEY AUTOINCREMENT`.
    /// Les tables de liens à PK composite (`transaction_tags`,
    /// `tricount_entry_tags`) sont traitées à part via `tagLinks` : les liens
    /// sont embarqués dans le payload JSON de la row propriétaire (champ "g"),
    /// leurs triggers marquent la row propriétaire dirty.
    ///
    /// ⚠️ L'ORDRE COMPTE : tables référencées avant tables référençantes —
    /// c'est l'ordre d'application des batchs distants (minimise les FK non
    /// résolues). `SyncPayloadStore.tableOrder` pointe sur cette liste.
    ///
    /// Volontairement JAMAIS synchronisées : `investment_live_sync` +
    /// credentials Keychain (par design), `currency_rates` (cache re-fetchable),
    /// `csv_mappings` / `import_sessions` (état de workflow local device),
    /// caches disque (hors DB depuis v35/v36).
    static let syncedTables: [String] = [
        // — Cœur ledger (v40)
        "accounts",
        "payment_types",
        "categories",
        "payee_groups",
        "tags",
        "payees",
        "transactions",
        // — Budget (v42)
        "recurring_patterns",
        "budget_envelopes",
        "budget_previsions",
        // — Investissements (v42)
        "investment_accounts",
        "investment_positions",
        "investment_orders",
        // — Patrimoine (v42)
        "patrimoine_real_estate",
        "patrimoine_loans",
        "patrimoine_assets",
        // — Objectifs (v42)
        "goals",
        // — Tricount (v42)
        "tricount_groups",
        "tricount_entries",
        "tricount_shares",
        // — Remboursement unifié (v44, AXE R) — remplace tricount_reimbursements
        "reimbursements",
    ]

    /// Tables ajoutées par la migration v42 (L.3) — NE JAMAIS MODIFIER après
    /// ship (la migration v42 itère cette liste ; ajouter une table = nouvelle
    /// liste + nouvelle migration).
    static let secondaryTablesV42: [String] = [
        "recurring_patterns", "budget_envelopes", "budget_previsions",
        "investment_accounts", "investment_positions", "investment_orders",
        "patrimoine_real_estate", "patrimoine_loans", "patrimoine_assets",
        "goals",
        "tricount_groups", "tricount_entries", "tricount_shares", "tricount_reimbursements",
    ]

    /// Tables de liens tags (PK composite) : pas de records CloudKit propres,
    /// liens embarqués dans le payload "g" de la row propriétaire.
    struct TagLink {
        let linkTable: String
        let ownerTable: String
        let ownerFK: String
    }

    static let tagLinks: [TagLink] = [
        TagLink(linkTable: "transaction_tags", ownerTable: "transactions", ownerFK: "transaction_id"),
        TagLink(linkTable: "tricount_entry_tags", ownerTable: "tricount_entries", ownerFK: "entry_id"),
    ]

    // MARK: - Statements de migration

    /// Statements d'ajout des colonnes sync pour une table.
    ///
    /// ⚠️ La migration v40 dépend de la sortie de cette fonction pour les
    /// 7 tables cœur : ne JAMAIS en modifier la sortie pour un input donné
    /// (convention "ne jamais modifier une migration existante"). Pour un
    /// changement de stratégie, écrire une nouvelle fonction versionnée.
    static func columnStatements(table t: String) -> [String] {
        [
            "ALTER TABLE \(t) ADD COLUMN uuid TEXT;",
            "ALTER TABLE \(t) ADD COLUMN updated_at TEXT;",
            "UPDATE \(t) SET uuid = lower(hex(randomblob(16))) WHERE uuid IS NULL;",
            "UPDATE \(t) SET updated_at = \(nowSQL) WHERE updated_at IS NULL;",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_\(t)_uuid ON \(t)(uuid);",
        ]
    }

    /// Tables d'état CKSyncEngine (créées par la migration v41 — DDL répliqué
    /// ici en CREATE IF NOT EXISTS idempotent pour le harness de tests
    /// NemorisApp/Tests/, la migration shippée ne devant plus être modifiée).
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

    /// Tables d'infrastructure sync (créées par la migration v40).
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

    /// (Ré)installe tous les triggers de dirty-tracking. Appelé à la fin de
    /// `DatabaseManager.migrateIfNeeded()` — uniquement si user_version >= 40
    /// (les colonnes uuid/updated_at doivent exister).
    ///
    /// DROP + CREATE systématique : idempotent, et permet de faire évoluer le
    /// corps des triggers sans migration.
    /// v43 — file des payloads distants DIFFÉRÉS : records dont une FK
    /// NOT NULL n'est pas encore résoluble (cible pas arrivée — les batchs
    /// CloudKit n'ont aucun ordre garanti). Avant ce fix, l'INSERT violait la
    /// contrainte et le record était PERDU définitivement (un record fetché
    /// non appliqué n'est jamais re-livré). Cas réel : 683 investment_orders
    /// arrivés avant leurs investment_positions à la descente initiale Mac.
    /// ⚠️ Utilisée par la migration v43 : ne jamais en modifier la sortie.
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
        // Garde d'existence : un device dont la migration v42 a échoué (version
        // restée à 40/41) ne doit pas générer d'erreurs de triggers sur les
        // tables pas encore instrumentées ; même garde pour le harness de tests
        // qui ne crée qu'un sous-ensemble du schéma.
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

    /// Triggers standard pour une table à PK `id`.
    ///
    /// ⚠️ La mise en file dans `sync_pending` se fait par DELETE puis INSERT, et
    /// surtout PAS par `INSERT OR REPLACE`.
    ///
    /// SQLite documente que si l'instruction qui déclenche le trigger porte
    /// elle-même une clause `ON CONFLICT`, la politique de résolution de cette
    /// instruction externe REMPLACE celle écrite dans le corps du trigger. Un
    /// `INSERT OR REPLACE` y perd donc son `OR REPLACE` et échoue sur la
    /// contrainte d'unicité de `sync_pending`.
    ///
    /// Conséquence observée avant correctif : tout UPSERT sur une table
    /// synchronisée échouait dès la deuxième écriture sur la même ligne, une
    /// entrée `sync_pending` existant alors déjà. Concrètement, changer le
    /// créancier d'un remboursement ne faisait rien — sans message, le booléen
    /// de retour étant ignoré par les appelants.
    ///
    /// DELETE puis INSERT n'implique aucune résolution de conflit, donc rien
    /// que l'instruction externe puisse écraser.
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

    /// Tables de liens tags : pas de records CloudKit propres — un changement
    /// de lien bump le `updated_at` de la row propriétaire, ce qui déclenche
    /// son trigger update (queue + horodatage en un seul endroit).
    /// Lors d'un DELETE CASCADE (propriétaire supprimé), le UPDATE ne matche
    /// aucune row → no-op, la tombstone du propriétaire suffit.
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

    // MARK: - Données de référence par défaut (seed DatabaseManager)

    /// Noms des catégories insérées par `seedNewDatabase()`. Utilisés pour
    /// purger les doublons avant la première activation CloudKit sur un
    /// appareil neuf (Mac/iPhone) et pour la fusion par nom à la réception.
    static let defaultSeedCategoryNames: Set<String> = [
        "Alimentation", "Transport", "Logement", "Santé", "Loisirs & Culture",
        "Vêtements & Shopping", "Voyages", "Revenus", "Banque & Finance",
        "Supermarché", "Restaurant & Bar", "Carburant", "Transport en commun",
        "Loyer & Charges", "Internet & Téléphone", "Énergie", "Médecin",
        "Pharmacie", "Cinéma & Spectacles", "Sport", "Abonnements", "Salaire",
        "Remboursements reçus",
    ]

    /// Noms des moyens de paiement insérés par `seedNewDatabase()`.
    static let defaultSeedPaymentTypeNames: Set<String> = [
        "Carte bancaire", "Virement", "Prélèvement", "Espèces", "Chèque", "AUTRE",
    ]
}
