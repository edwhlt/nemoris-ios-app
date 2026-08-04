import Foundation
import SQLite3

// Harness de tests SyncPayloadStore — compilé standalone via run_sync_tests.sh
// avec les fichiers RÉELS SyncSchema.swift + SyncPayloadStore.swift (aucune
// copie de logique). Couvre les régressions de la session L.1 (overflow
// limit .max) et les sémantiques de conflit L.2.

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@main
struct SyncStoreTests {

    static var failures = 0

    static func main() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemoris_sync_tests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Base "B" = appareil local qui reçoit les changements distants.
        let urlB = dir.appendingPathComponent("deviceB.sqlite")
        makeDevice(urlB)
        let storeB = SyncPayloadStore(databaseURL: urlB)

        // Base "A" = appareil source des payloads.
        let urlA = dir.appendingPathComponent("deviceA.sqlite")
        makeDevice(urlA)
        let storeA = SyncPayloadStore(databaseURL: urlA)

        t1_limitMax(storeB, urlB)
        t2_roundtripFKTags(storeA, urlA, storeB, urlB)
        t3_lww(storeB, urlB)
        t4_unresolvedRefs(storeB, urlB)
        t5_deletion(storeB, urlB)
        t6_deleteVsUpdate(storeB, urlB)
        t7_tagAdoption(storeB, urlB)
        t8_tricountTagLinks(storeA, urlA, storeB, urlB)
        t9_orderExternalIdAdoption(storeB, urlB)
        t10_purgeVirginSeed(storeB, urlB)
        t11_categoryNameAdoption(storeB, urlB)
        t12_dedupReferenceDuplicates(storeB, urlB)
        t13_deferredNotNullFK(storeA, urlA, storeB, urlB)
        t14_reimbursementXorDeferral(storeA, urlA, storeB, urlB)

        if failures == 0 {
            print("\n✅ SyncStoreTests : tous les tests passent")
            exit(0)
        } else {
            print("\n❌ SyncStoreTests : \(failures) échec(s)")
            exit(1)
        }
    }

    // MARK: - Setup

    /// Crée une base reproduisant les 7 tables cœur + infra sync + triggers,
    /// via les VRAIS statements de SyncSchema (mêmes DDL que la migration v40).
    static func makeDevice(_ url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { fatalError("open \(url)") }
        defer { sqlite3_close(db) }

        let schema = [
            "CREATE TABLE accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, type TEXT NOT NULL DEFAULT 'COURANT');",
            "CREATE TABLE payment_types (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, regex TEXT);",
            "CREATE TABLE categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, parent_id INTEGER REFERENCES categories(id), icon TEXT);",
            "CREATE TABLE payee_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, display_name TEXT NOT NULL, engine_merchant_id TEXT, custom INTEGER NOT NULL DEFAULT 0);",
            "CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE COLLATE NOCASE, color TEXT);",
            "CREATE TABLE payees (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, regex TEXT, category_id INTEGER, linked_account_id INTEGER REFERENCES accounts(id), group_id INTEGER, city TEXT, country TEXT);",
            """
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER REFERENCES accounts(id),
                payee_id INTEGER REFERENCES payees(id),
                category_id INTEGER REFERENCES categories(id),
                payment_type_id INTEGER REFERENCES payment_types(id),
                information TEXT, libelle_brut TEXT, amount REAL, tx_date TEXT
            );
            """,
            """
            CREATE TABLE transaction_tags (
                transaction_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (transaction_id, tag_id)
            );
            """,
            // — Sous-ensemble L.3 : tricount (tag-link généralisé) + investments (adoption external_id)
            "CREATE TABLE tricount_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, tricount_key TEXT NOT NULL, title TEXT NOT NULL, my_name TEXT NOT NULL DEFAULT '', fetched_at TEXT NOT NULL DEFAULT '');",
            "CREATE TABLE tricount_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES tricount_groups(id) ON DELETE CASCADE, who_paid TEXT NOT NULL DEFAULT '', total REAL NOT NULL DEFAULT 0, date TEXT NOT NULL DEFAULT '', user_category_id INTEGER, linked_transaction_id INTEGER REFERENCES transactions(id));",
            """
            CREATE TABLE tricount_entry_tags (
                entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (entry_id, tag_id)
            );
            """,
            // — Remboursement unifié (v44, AXE R) : XOR transaction_id/tricount_entry_id.
            """
            CREATE TABLE reimbursements (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                transaction_id INTEGER REFERENCES transactions(id) ON DELETE CASCADE,
                tricount_entry_id INTEGER REFERENCES tricount_entries(id) ON DELETE CASCADE,
                payee_id INTEGER NOT NULL REFERENCES payees(id),
                amount REAL, currency TEXT NOT NULL DEFAULT 'EUR', status TEXT NOT NULL DEFAULT 'PENDING',
                CHECK ((transaction_id IS NOT NULL) <> (tricount_entry_id IS NOT NULL))
            );
            """,
            "CREATE UNIQUE INDEX idx_reimbursements_transaction ON reimbursements(transaction_id) WHERE transaction_id IS NOT NULL;",
            "CREATE UNIQUE INDEX idx_reimbursements_tricount ON reimbursements(tricount_entry_id, payee_id) WHERE tricount_entry_id IS NOT NULL;",
            "CREATE TABLE investment_accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, opened_at TEXT NOT NULL DEFAULT '');",
            "CREATE TABLE investment_positions (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL REFERENCES investment_accounts(id) ON DELETE CASCADE, asset_name TEXT NOT NULL DEFAULT '', ticker TEXT NOT NULL DEFAULT '', quantity REAL NOT NULL DEFAULT 0, purchase_date TEXT NOT NULL DEFAULT '');",
            "CREATE TABLE investment_orders (id INTEGER PRIMARY KEY AUTOINCREMENT, position_id INTEGER NOT NULL REFERENCES investment_positions(id) ON DELETE CASCADE, order_type TEXT NOT NULL DEFAULT 'BUY', quantity REAL NOT NULL DEFAULT 0, unit_price REAL NOT NULL DEFAULT 0, executed_at TEXT NOT NULL DEFAULT '', external_id TEXT);",
            "CREATE UNIQUE INDEX idx_invest_orders_external_id ON investment_orders(external_id) WHERE external_id IS NOT NULL;",
        ]
        for sql in schema { exec(db, sql) }
        for sql in SyncSchema.infrastructureStatements { exec(db, sql) }
        for sql in SyncSchema.engineStateStatements { exec(db, sql) }
        for sql in SyncSchema.deferredRowsDDL { exec(db, sql) }
        for t in SyncSchema.syncedTables where tableExists(db, t) {
            for sql in SyncSchema.columnStatements(table: t) { exec(db, sql) }
        }
        SyncSchema.installTriggers(db)
    }

    static func tableExists(_ db: OpaquePointer, _ t: String) -> Bool {
        query(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(t)';") == "1"
    }

    // MARK: - Tests

    /// Fix "683 ordres perdus" : un record dont une FK NOT NULL pointe une
    /// cible pas encore descendue (batchs CloudKit sans ordre garanti) doit
    /// être DIFFÉRÉ puis rejoué quand la cible arrive — pas perdu. Cascade
    /// complète : l'ordre attend sa position, qui attend son compte.
    static func t13_deferredNotNullFK(_ storeA: SyncPayloadStore, _ urlA: URL,
                                      _ storeB: SyncPayloadStore, _ urlB: URL) {
        var accUuid = "", posUuid = "", ordUuid = ""
        withDB(urlA) { db in
            exec(db, "INSERT INTO investment_accounts (name) VALUES ('PEA-T13');")
            exec(db, "INSERT INTO investment_positions (account_id, asset_name, ticker) VALUES ((SELECT id FROM investment_accounts WHERE name='PEA-T13'), 'Thales', 'HO-T13');")
            exec(db, "INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, executed_at) VALUES ((SELECT id FROM investment_positions WHERE ticker='HO-T13'), 'BUY', 3, 140, '2026-01-15');")
            accUuid = query(db, "SELECT uuid FROM investment_accounts WHERE name='PEA-T13';")
            posUuid = query(db, "SELECT uuid FROM investment_positions WHERE ticker='HO-T13';")
            ordUuid = query(db, "SELECT uuid FROM investment_orders WHERE unit_price=140;")
        }
        guard let accP = storeA.payloadJSON(table: "investment_accounts", uuid: accUuid),
              let posP = storeA.payloadJSON(table: "investment_positions", uuid: posUuid),
              let ordP = storeA.payloadJSON(table: "investment_orders", uuid: ordUuid) else {
            check("T13 payloads générés", false, "payloadJSON nil"); return
        }

        // Batch 1 : l'ORDRE seul — sa position n'existe pas encore sur B.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "investment_orders", uuid: ordUuid, payloadData: ordP, systemFields: Data([9]))],
            deletions: [])
        withDB(urlB) { db in
            check("T13 ordre PAS inséré (FK NOT NULL absente)",
                  query(db, "SELECT COUNT(*) FROM investment_orders WHERE uuid='\(ordUuid)';") == "0", "")
            check("T13 ordre DIFFÉRÉ (pas perdu)",
                  query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(ordUuid)';") == "1", "")
            check("T13 system fields attachés au différé",
                  query(db, "SELECT length(system_fields) FROM sync_deferred_rows WHERE row_uuid='\(ordUuid)';") == "1", "")
        }

        // Batch 2 : position et compte VOLONTAIREMENT dans le désordre — le
        // tri interne (référencées d'abord) applique compte → position, puis
        // le rejeu de fin de batch débloque l'ordre différé.
        storeB.applyRemoteBatch(
            modifications: [
                .init(table: "investment_positions", uuid: posUuid, payloadData: posP, systemFields: Data([8])),
                .init(table: "investment_accounts", uuid: accUuid, payloadData: accP, systemFields: Data([7])),
            ],
            deletions: [])
        withDB(urlB) { db in
            let posId = query(db, "SELECT id FROM investment_positions WHERE uuid='\(posUuid)';")
            check("T13 position appliquée (compte trié avant)", posId != "<no row>", "posId=\(posId)")
            check("T13 ordre rejoué avec la bonne FK",
                  query(db, "SELECT position_id FROM investment_orders WHERE uuid='\(ordUuid)';") == posId, "")
            check("T13 file des différés soldée",
                  query(db, "SELECT COUNT(*) FROM sync_deferred_rows;") == "0", "")
            check("T13 system fields promus en record_meta",
                  query(db, "SELECT COUNT(*) FROM sync_record_meta WHERE row_uuid='\(ordUuid)';") == "1", "")
        }
    }

    /// v44 AXE R : le CHECK XOR (transaction_id / tricount_entry_id) n'est pas
    /// qu'une contrainte d'intégrité — il permet au mécanisme de report (v43)
    /// de rattraper une ligne `reimbursements` dont la transaction cible
    /// arrive APRÈS (batchs CloudKit sans ordre garanti). Sans lui, l'INSERT
    /// réussirait avec transaction_id ET tricount_entry_id à NULL (ligne
    /// fantôme jamais réparée) au lieu d'échouer et d'être différée.
    static func t14_reimbursementXorDeferral(_ storeA: SyncPayloadStore, _ urlA: URL,
                                             _ storeB: SyncPayloadStore, _ urlB: URL) {
        var payeeUuid = "", txUuid = "", reimbUuid = ""
        withDB(urlA) { db in
            exec(db, "INSERT INTO payees (name) VALUES ('Papa-T14');")
            exec(db, "INSERT INTO transactions (amount, information) VALUES (-80, 'Cadeau T14');")
            exec(db, "INSERT INTO reimbursements (transaction_id, payee_id) VALUES ((SELECT id FROM transactions WHERE information='Cadeau T14'), (SELECT id FROM payees WHERE name='Papa-T14'));")
            payeeUuid = query(db, "SELECT uuid FROM payees WHERE name='Papa-T14';")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE information='Cadeau T14';")
            reimbUuid = query(db, "SELECT uuid FROM reimbursements WHERE payee_id=(SELECT id FROM payees WHERE name='Papa-T14');")
        }
        guard let payeeP = storeA.payloadJSON(table: "payees", uuid: payeeUuid),
              let txP = storeA.payloadJSON(table: "transactions", uuid: txUuid),
              let reimbP = storeA.payloadJSON(table: "reimbursements", uuid: reimbUuid) else {
            check("T14 payloads générés", false, "payloadJSON nil"); return
        }

        // Précondition : le payee existe déjà côté B (FK payee_id résolue OK)
        // — seule la FK transaction_id doit poser problème.
        setSuppress(urlB, true)
        check("T14 apply payee (précondition)", storeB.applyRemoteRecord(table: "payees", payloadData: payeeP) == .applied, "")
        setSuppress(urlB, false)

        // Batch 1 : le remboursement seul — sa transaction n'existe pas encore sur B.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "reimbursements", uuid: reimbUuid, payloadData: reimbP, systemFields: Data([9]))],
            deletions: [])
        withDB(urlB) { db in
            check("T14 remboursement PAS inséré (CHECK XOR violé)",
                  query(db, "SELECT COUNT(*) FROM reimbursements WHERE uuid='\(reimbUuid)';") == "0", "")
            check("T14 remboursement DIFFÉRÉ (pas perdu)",
                  query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(reimbUuid)';") == "1", "")
        }

        // Batch 2 : la transaction arrive — le rejeu de fin de batch débloque
        // le remboursement différé.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "transactions", uuid: txUuid, payloadData: txP, systemFields: Data([8]))],
            deletions: [])
        withDB(urlB) { db in
            let txId = query(db, "SELECT id FROM transactions WHERE uuid='\(txUuid)';")
            check("T14 transaction appliquée", txId != "<no row>", "txId=\(txId)")
            check("T14 remboursement rejoué avec la bonne FK",
                  query(db, "SELECT transaction_id FROM reimbursements WHERE uuid='\(reimbUuid)';") == txId, "")
            check("T14 tricount_entry_id resté NULL (XOR respecté)",
                  query(db, "SELECT tricount_entry_id IS NULL FROM reimbursements WHERE uuid='\(reimbUuid)';") == "1", "")
            check("T14 file des différés soldée",
                  query(db, "SELECT COUNT(*) FROM sync_deferred_rows;") == "0", "")
        }
    }

    /// Régression session L.1 : `Int32(Int.max)` crashait. Le clamp doit
    /// rendre TOUTES les rows sans surflow.
    static func t1_limitMax(_ store: SyncPayloadStore, _ url: URL) {
        withDB(url) { db in
            exec(db, "INSERT INTO tags (name) VALUES ('a'), ('b'), ('c');")
        }
        let all = store.pendingRows(limit: .max)
        check("T1 pendingRows(.max) sans crash, rend tout", all.count == 3, "attendu 3, obtenu \(all.count)")
        let capped = store.pendingRows(limit: 2)
        check("T1 limit fini respecté", capped.count == 2, "attendu 2, obtenu \(capped.count)")
        _ = store.tombstoneRows(limit: .max)   // ne doit pas crasher
        withDB(url) { db in
            exec(db, "DELETE FROM tags; DELETE FROM sync_pending; DELETE FROM sync_tombstones;")
        }
    }

    /// Roundtrip A→B : payee + transaction + tag. Sur B les ids locaux
    /// diffèrent (décalés exprès) — la FK doit être résolue via uuid.
    static func t2_roundtripFKTags(_ storeA: SyncPayloadStore, _ urlA: URL,
                                   _ storeB: SyncPayloadStore, _ urlB: URL) {
        var payeeUuid = "", txUuid = "", tagUuid = ""
        withDB(urlA) { db in
            exec(db, "INSERT INTO payees (name) VALUES ('Carrefour');")
            exec(db, "INSERT INTO transactions (payee_id, amount, libelle_brut) VALUES (1, -42.5, 'CARREFOUR PARIS');")
            exec(db, "INSERT INTO tags (name) VALUES ('courses');")
            exec(db, "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (1, 1);")
            payeeUuid = query(db, "SELECT uuid FROM payees WHERE id = 1;")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE id = 1;")
            tagUuid = query(db, "SELECT uuid FROM tags WHERE id = 1;")
        }
        guard let payeePayload = storeA.payloadJSON(table: "payees", uuid: payeeUuid),
              let txPayload = storeA.payloadJSON(table: "transactions", uuid: txUuid),
              let tagPayload = storeA.payloadJSON(table: "tags", uuid: tagUuid) else {
            check("T2 payloads générés", false, "payloadJSON nil"); return
        }
        // Vérifie le format : FK en uuid dans "r", tags dans "g".
        let obj = try! JSONSerialization.jsonObject(with: txPayload) as! [String: Any]
        check("T2 FK sérialisée en uuid", (obj["r"] as? [String: String])?["payee_id"] == payeeUuid, "r=\(String(describing: obj["r"]))")
        check("T2 tags embarqués", (obj["g"] as? [String]) == [tagUuid], "g=\(String(describing: obj["g"]))")

        // Décale les ids sur B pour prouver que la résolution passe par uuid.
        withDB(urlB) { db in
            exec(db, "INSERT INTO sync_meta (key, value) VALUES ('suppress_triggers', '1') ON CONFLICT(key) DO UPDATE SET value='1';")
            exec(db, "INSERT INTO payees (id, name, uuid, updated_at) VALUES (77, 'décalage', lower(hex(randomblob(16))), '2020-01-01T00:00:00.000Z');")
        }
        check("T2 apply payee", storeB.applyRemoteRecord(table: "payees", payloadData: payeePayload) == .applied, "")
        check("T2 apply tag", storeB.applyRemoteRecord(table: "tags", payloadData: tagPayload) == .applied, "")
        check("T2 apply transaction", storeB.applyRemoteRecord(table: "transactions", payloadData: txPayload) == .applied, "")
        withDB(urlB) { db in
            let localPayeeId = query(db, "SELECT id FROM payees WHERE uuid = '\(payeeUuid)';")
            check("T2 payee inséré avec id local ≠ A", localPayeeId == "78", "id=\(localPayeeId)")
            let fk = query(db, "SELECT payee_id FROM transactions WHERE uuid = '\(txUuid)';")
            check("T2 FK résolue vers l'id local", fk == localPayeeId, "payee_id=\(fk) vs \(localPayeeId)")
            let linked = query(db, "SELECT COUNT(*) FROM transaction_tags tt JOIN transactions t ON t.id = tt.transaction_id WHERE t.uuid = '\(txUuid)';")
            check("T2 lien tag reconstruit", linked == "1", "liens=\(linked)")
            exec(db, "UPDATE sync_meta SET value='0' WHERE key='suppress_triggers';")
        }
    }

    /// LWW : un payload plus VIEUX que la row locale est ignoré.
    static func t3_lww(_ store: SyncPayloadStore, _ url: URL) {
        var uuid = ""
        withDB(url) { db in
            exec(db, "INSERT INTO categories (name) VALUES ('Récent local');")
            uuid = query(db, "SELECT uuid FROM categories WHERE name = 'Récent local';")
        }
        let old: [String: Any] = ["u": uuid, "t": "2000-01-01T00:00:00.000Z", "v": ["name": "Vieux distant"]]
        let data = try! JSONSerialization.data(withJSONObject: old)
        setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "categories", payloadData: data)
        setSuppress(url, false)
        check("T3 LWW skip (local plus récent)", r == .skippedLocalNewer, "résultat=\(r)")
        withDB(url) { db in
            check("T3 contenu local préservé", query(db, "SELECT name FROM categories WHERE uuid='\(uuid)';") == "Récent local", "")
        }
    }

    /// FK vers une cible pas encore arrivée → NULL + unresolved, résolue après.
    static func t4_unresolvedRefs(_ store: SyncPayloadStore, _ url: URL) {
        let payeeUuid = String(repeating: "1", count: 32)
        let txUuid = String(repeating: "2", count: 32)
        let tx: [String: Any] = ["u": txUuid, "t": "2999-01-01T00:00:00.000Z",
                                 "v": ["amount": -10.0], "r": ["payee_id": payeeUuid]]
        setSuppress(url, true)
        check("T4 apply tx orpheline", store.applyRemoteRecord(table: "transactions", payloadData: try! JSONSerialization.data(withJSONObject: tx)) == .applied, "")
        withDB(url) { db in
            check("T4 FK NULL en attendant", query(db, "SELECT payee_id IS NULL FROM transactions WHERE uuid='\(txUuid)';") == "1", "")
            check("T4 ref en attente enregistrée", query(db, "SELECT COUNT(*) FROM sync_unresolved_refs WHERE row_uuid='\(txUuid)';") == "1", "")
        }
        let payee: [String: Any] = ["u": payeeUuid, "t": "2999-01-01T00:00:00.000Z", "v": ["name": "Retardataire"]]
        check("T4 apply payee retard", store.applyRemoteRecord(table: "payees", payloadData: try! JSONSerialization.data(withJSONObject: payee)) == .applied, "")
        store.resolveUnresolvedRefs()
        setSuppress(url, false)
        withDB(url) { db in
            let expected = query(db, "SELECT id FROM payees WHERE uuid='\(payeeUuid)';")
            check("T4 FK résolue après coup", query(db, "SELECT payee_id FROM transactions WHERE uuid='\(txUuid)';") == expected, "")
            check("T4 file unresolved vidée", query(db, "SELECT COUNT(*) FROM sync_unresolved_refs;") == "0", "")
        }
    }

    /// Suppression distante d'une row propre : appliquée, liens tags nettoyés.
    static func t5_deletion(_ store: SyncPayloadStore, _ url: URL) {
        var txUuid = "", txId = ""
        withDB(url) { db in
            exec(db, "INSERT INTO transactions (amount) VALUES (-5);")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE amount = -5;")
            exec(db, "INSERT INTO tags (name) VALUES ('t5tag');")
            txId = query(db, "SELECT id FROM transactions WHERE uuid='\(txUuid)';")
            let tagId = query(db, "SELECT id FROM tags WHERE name='t5tag';")
            exec(db, "INSERT INTO transaction_tags VALUES (\(txId), \(tagId));")
            exec(db, "DELETE FROM sync_pending;")   // row "propre" (déjà synchronisée)
        }
        setSuppress(url, true)
        store.applyRemoteDeletion(table: "transactions", uuid: txUuid)
        setSuppress(url, false)
        withDB(url) { db in
            check("T5 row supprimée", query(db, "SELECT COUNT(*) FROM transactions WHERE uuid='\(txUuid)';") == "0", "")
            check("T5 liens tags purgés", query(db, "SELECT COUNT(*) FROM transaction_tags WHERE transaction_id = \(txId);") == "0", "")
        }
    }

    /// Delete-vs-update : la row a une édition locale PENDING → la
    /// suppression distante est ignorée, l'édition survit.
    static func t6_deleteVsUpdate(_ store: SyncPayloadStore, _ url: URL) {
        var uuid = ""
        withDB(url) { db in
            exec(db, "DELETE FROM sync_pending;")
            exec(db, "INSERT INTO payees (name) VALUES ('Édité localement');")   // trigger → pending
            uuid = query(db, "SELECT uuid FROM payees WHERE name = 'Édité localement';")
            check("T6 précondition : row pending", query(db, "SELECT COUNT(*) FROM sync_pending WHERE row_uuid='\(uuid)';") == "1", "")
        }
        setSuppress(url, true)
        store.applyRemoteDeletion(table: "payees", uuid: uuid)
        setSuppress(url, false)
        withDB(url) { db in
            check("T6 l'édition locale survit au delete distant", query(db, "SELECT COUNT(*) FROM payees WHERE uuid='\(uuid)';") == "1", "")
        }
    }

    /// Adoption : tag 'vacances' créé indépendamment des deux côtés →
    /// fusion d'identités sur l'uuid distant + tombstone de l'ancien.
    static func t7_tagAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var oldUuid = ""
        withDB(url) { db in
            exec(db, "DELETE FROM sync_pending; DELETE FROM sync_tombstones;")
            exec(db, "INSERT INTO tags (name) VALUES ('vacances');")   // → pending, uuid local
            oldUuid = query(db, "SELECT uuid FROM tags WHERE name = 'vacances';")
        }
        // Règle déterministe : le plus PETIT uuid gagne — remote "000…1" bat
        // n'importe quel uuid local aléatoire.
        let remoteUuid = String(repeating: "0", count: 31) + "1"
        let remote: [String: Any] = ["u": remoteUuid, "t": "2999-01-01T00:00:00.000Z",
                                     "v": ["name": "Vacances", "color": "#00FF00"]]
        setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "tags", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        setSuppress(url, false)
        check("T7 apply avec adoption réussit", r == .applied, "résultat=\(r)")
        withDB(url) { db in
            check("T7 une seule row (pas de doublon)", query(db, "SELECT COUNT(*) FROM tags WHERE name = 'Vacances' COLLATE NOCASE;") == "1", "")
            check("T7 uuid distant adopté", query(db, "SELECT uuid FROM tags WHERE name='Vacances';") == remoteUuid, "")
            check("T7 contenu distant appliqué (LWW)", query(db, "SELECT color FROM tags WHERE uuid='\(remoteUuid)';") == "#00FF00", "")
            check("T7 tombstone de l'ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
            check("T7 pending de l'ancien uuid purgé", query(db, "SELECT COUNT(*) FROM sync_pending WHERE row_uuid='\(oldUuid)';") == "0", "")
        }

        // Sens inverse : un remote au uuid PLUS GRAND ne vole pas l'identité
        // (anti ping-pong — c'est l'autre appareil qui adoptera notre uuid).
        let bigUuid = String(repeating: "f", count: 32)
        let big: [String: Any] = ["u": bigUuid, "t": "2999-06-01T00:00:00.000Z", "v": ["name": "vacances"]]
        setSuppress(url, true)
        let r2 = store.applyRemoteRecord(table: "tags", payloadData: try! JSONSerialization.data(withJSONObject: big))
        setSuppress(url, false)
        check("T7b local (petit uuid) gagne : record ignoré", r2 == .failed, "résultat=\(r2)")
        withDB(url) { db in
            check("T7b toujours une seule row", query(db, "SELECT COUNT(*) FROM tags WHERE name='vacances' COLLATE NOCASE;") == "1", "")
            check("T7b uuid conservé", query(db, "SELECT uuid FROM tags WHERE name='Vacances';") == remoteUuid, "")
        }
    }

    /// L.3 : le mécanisme "g" généralisé fonctionne pour tricount_entries.
    static func t8_tricountTagLinks(_ storeA: SyncPayloadStore, _ urlA: URL,
                                    _ storeB: SyncPayloadStore, _ urlB: URL) {
        var groupUuid = "", entryUuid = "", tagUuid = ""
        withDB(urlA) { db in
            exec(db, "INSERT INTO tricount_groups (tricount_key, title) VALUES ('k1', 'Vacances 2026');")
            exec(db, "INSERT INTO tricount_entries (group_id, who_paid, total, date) VALUES (1, 'Edwin', 120, '2026-07-01');")
            exec(db, "INSERT INTO tags (name) VALUES ('t8tag');")
            let tagId = query(db, "SELECT id FROM tags WHERE name='t8tag';")
            exec(db, "INSERT INTO tricount_entry_tags (entry_id, tag_id) VALUES (1, \(tagId));")
            groupUuid = query(db, "SELECT uuid FROM tricount_groups WHERE id=1;")
            entryUuid = query(db, "SELECT uuid FROM tricount_entries WHERE id=1;")
            tagUuid = query(db, "SELECT uuid FROM tags WHERE name='t8tag';")
        }
        guard let g = storeA.payloadJSON(table: "tricount_groups", uuid: groupUuid),
              let e = storeA.payloadJSON(table: "tricount_entries", uuid: entryUuid),
              let t = storeA.payloadJSON(table: "tags", uuid: tagUuid) else {
            check("T8 payloads générés", false, "nil"); return
        }
        let obj = try! JSONSerialization.jsonObject(with: e) as! [String: Any]
        check("T8 tags tricount embarqués", (obj["g"] as? [String]) == [tagUuid], "g=\(String(describing: obj["g"]))")

        setSuppress(urlB, true)
        check("T8 apply group", storeB.applyRemoteRecord(table: "tricount_groups", payloadData: g) == .applied, "")
        check("T8 apply tag", storeB.applyRemoteRecord(table: "tags", payloadData: t) == .applied, "")
        check("T8 apply entry", storeB.applyRemoteRecord(table: "tricount_entries", payloadData: e) == .applied, "")
        setSuppress(urlB, false)
        withDB(urlB) { db in
            let linked = query(db, "SELECT COUNT(*) FROM tricount_entry_tags et JOIN tricount_entries te ON te.id = et.entry_id WHERE te.uuid = '\(entryUuid)';")
            check("T8 lien tag tricount reconstruit", linked == "1", "liens=\(linked)")
            let fk = query(db, "SELECT tg.uuid FROM tricount_entries te JOIN tricount_groups tg ON tg.id = te.group_id WHERE te.uuid = '\(entryUuid)';")
            check("T8 FK group résolue", fk == groupUuid, "fk=\(fk)")
        }
    }

    /// L.3 : deux appareils qui importent le même trade Binance (même
    /// external_id) → adoption au lieu d'un échec d'INSERT en boucle.
    static func t9_orderExternalIdAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var posUuid = "", oldUuid = ""
        withDB(url) { db in
            exec(db, "INSERT INTO investment_accounts (name) VALUES ('Binance');")
            exec(db, "INSERT INTO investment_positions (account_id, asset_name, ticker) VALUES (1, 'Bitcoin', 'BTC');")
            exec(db, "INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, executed_at, external_id) VALUES (1, 'BUY', 0.5, 40000, '2026-01-15', 'binance_BTCUSDT_777');")
            posUuid = query(db, "SELECT uuid FROM investment_positions WHERE id=1;")
            oldUuid = query(db, "SELECT uuid FROM investment_orders WHERE id=1;")
        }
        let remoteUuid = String(repeating: "0", count: 31) + "2"
        let remote: [String: Any] = [
            "u": remoteUuid, "t": "2999-01-01T00:00:00.000Z",
            "v": ["order_type": "BUY", "quantity": 0.5, "unit_price": 40000,
                  "executed_at": "2026-01-15", "external_id": "binance_BTCUSDT_777"],
            "r": ["position_id": posUuid],
        ]
        setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "investment_orders", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        setSuppress(url, false)
        check("T9 apply avec adoption external_id", r == .applied, "résultat=\(r)")
        withDB(url) { db in
            check("T9 un seul ordre (pas de doublon)", query(db, "SELECT COUNT(*) FROM investment_orders WHERE external_id='binance_BTCUSDT_777';") == "1", "")
            check("T9 uuid distant adopté", query(db, "SELECT uuid FROM investment_orders WHERE external_id='binance_BTCUSDT_777';") == remoteUuid, "")
            check("T9 tombstone ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
        }
    }

    /// Purge du seed sur base vierge (flux "Rejoindre via iCloud") : les
    /// catégories/payment_types usine d'une base SANS transaction sont
    /// retirées avant la descente du coffre — pas de doublons de seed.
    static func t10_purgeVirginSeed(_ storeB: SyncPayloadStore, _ urlB: URL) {
        // Base C fraîche : seed usine, zéro transaction.
        let urlC = urlB.deletingLastPathComponent().appendingPathComponent("deviceC.sqlite")
        makeDevice(urlC)
        let storeC = SyncPayloadStore(databaseURL: urlC)
        withDB(urlC) { db in
            exec(db, "INSERT INTO categories (name) VALUES ('Transport');")
            exec(db, "INSERT INTO categories (name, parent_id) VALUES ('Carburant', 1);")
            exec(db, "INSERT INTO categories (name) VALUES ('Ma catégorie perso');")
            exec(db, "INSERT INTO payment_types (name) VALUES ('Carte bancaire');")
        }
        let purged = storeC.purgeVirginSeedReferenceData()
        check("T10 purge seed base vierge (3 rows usine)", purged == 3, "purgé=\(purged)")
        withDB(urlC) { db in
            check("T10 la catégorie perso survit", query(db, "SELECT COUNT(*) FROM categories WHERE name='Ma catégorie perso';") == "1", "")
            check("T10 seed usine retiré", query(db, "SELECT COUNT(*) FROM categories WHERE name IN ('Transport','Carburant');") == "0", "")
        }
        // Base B (a des transactions) : purge = no-op.
        let purgedB = storeB.purgeVirginSeedReferenceData()
        check("T10 no-op si base utilisée", purgedB == 0, "purgé=\(purgedB)")
    }

    /// Adoption PROACTIVE par nom : catégorie seed présente des deux côtés
    /// (aucune contrainte UNIQUE) → fusion au lieu d'un doublon silencieux.
    static func t11_categoryNameAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var oldUuid = ""
        withDB(url) { db in
            exec(db, "INSERT INTO categories (name, icon) VALUES ('Santé', 'heart.fill');")
            oldUuid = query(db, "SELECT uuid FROM categories WHERE name='Santé';")
        }
        let remoteUuid = String(repeating: "0", count: 31) + "3"
        let remote: [String: Any] = ["u": remoteUuid, "t": "2999-01-01T00:00:00.000Z",
                                     "v": ["name": "Santé", "icon": "cross.fill"]]
        setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "categories", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        setSuppress(url, false)
        check("T11 apply avec adoption par nom", r == .applied, "résultat=\(r)")
        withDB(url) { db in
            check("T11 une seule 'Santé' (pas de doublon)", query(db, "SELECT COUNT(*) FROM categories WHERE name='Santé';") == "1", "")
            check("T11 uuid distant adopté", query(db, "SELECT uuid FROM categories WHERE name='Santé';") == remoteUuid, "")
            check("T11 contenu distant appliqué", query(db, "SELECT icon FROM categories WHERE name='Santé';") == "cross.fill", "")
            check("T11 tombstone ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
        }

        // Chemin proactif, sens inverse : remote homonyme au uuid plus grand
        // → PAS d'insert (doublon évité), pas d'adoption (local gagne).
        let bigUuid = String(repeating: "f", count: 32)
        let big: [String: Any] = ["u": bigUuid, "t": "2999-06-01T00:00:00.000Z", "v": ["name": "Santé"]]
        setSuppress(url, true)
        let r2 = store.applyRemoteRecord(table: "categories", payloadData: try! JSONSerialization.data(withJSONObject: big))
        setSuppress(url, false)
        check("T11b local gagne : skip sans doublon", r2 == .skippedLocalNewer, "résultat=\(r2)")
        withDB(url) { db in
            check("T11b toujours une seule 'Santé'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Santé';") == "1", "")
            check("T11b uuid conservé", query(db, "SELECT uuid FROM categories WHERE name='Santé';") == remoteUuid, "")
        }
    }

    /// Réparation one-shot des doublons seed (post-L.1) : keeper = plus petit
    /// uuid, FK remappées, tombstones propagées — hiérarchie parent incluse.
    static func t12_dedupReferenceDuplicates(_ store: SyncPayloadStore, _ url: URL) {
        let keepUuid = String(repeating: "a", count: 32)
        let dupeUuid = String(repeating: "f", count: 32)
        let keepChildUuid = String(repeating: "b", count: 32)
        let dupeChildUuid = String(repeating: "e", count: 32)
        var keepId = "", dupeId = ""
        withDB(url) { db in
            exec(db, "DELETE FROM sync_tombstones;")
            exec(db, "INSERT INTO categories (name, uuid, updated_at) VALUES ('Courses', '\(keepUuid)', '2026-01-01T00:00:00.000Z');")
            exec(db, "INSERT INTO categories (name, uuid, updated_at) VALUES ('Courses', '\(dupeUuid)', '2026-01-01T00:00:00.000Z');")
            keepId = query(db, "SELECT id FROM categories WHERE uuid='\(keepUuid)';")
            dupeId = query(db, "SELECT id FROM categories WHERE uuid='\(dupeUuid)';")
            // Sous-catégorie "Bio" sous CHAQUE doublon → même clé (nom+parent).
            exec(db, "INSERT INTO categories (name, parent_id, uuid, updated_at) VALUES ('Bio', \(keepId), '\(keepChildUuid)', '2026-01-01T00:00:00.000Z');")
            exec(db, "INSERT INTO categories (name, parent_id, uuid, updated_at) VALUES ('Bio', \(dupeId), '\(dupeChildUuid)', '2026-01-01T00:00:00.000Z');")
            // Une transaction rattachée au DOUBLON → doit être remappée.
            exec(db, "INSERT INTO transactions (category_id, amount) VALUES (\(dupeId), -12.5);")
            // Doublon payment_types.
            exec(db, "INSERT INTO payment_types (name, uuid, updated_at) VALUES ('CB test', '\(keepUuid)', '2026-01-01T00:00:00.000Z');")
            exec(db, "INSERT INTO payment_types (name, uuid, updated_at) VALUES ('CB test', '\(dupeUuid)', '2026-01-01T00:00:00.000Z');")

            let merged = SyncPayloadStore.dedupReferenceDuplicates(db)
            check("T12 fusions effectuées (3 attendues)", merged == 3, "merged=\(merged)")

            check("T12 une seule 'Courses'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Courses';") == "1", "")
            check("T12 keeper = plus petit uuid", query(db, "SELECT uuid FROM categories WHERE name='Courses';") == keepUuid, "")
            check("T12 transaction remappée vers keeper", query(db, "SELECT category_id FROM transactions WHERE amount=-12.5;") == keepId, "")
            check("T12 une seule 'Bio'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Bio';") == "1", "")
            check("T12 'Bio' rattachée au keeper", query(db, "SELECT parent_id FROM categories WHERE name='Bio';") == keepId, "")
            check("T12 tombstone doublon 'Courses'", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE table_name='categories' AND row_uuid='\(dupeUuid)';") == "1", "")
            check("T12 un seul 'CB test'", query(db, "SELECT COUNT(*) FROM payment_types WHERE name='CB test';") == "1", "")
            check("T12 rerun = no-op", SyncPayloadStore.dedupReferenceDuplicates(db) == 0, "")
        }
    }

    // MARK: - Helpers

    static func check(_ label: String, _ ok: Bool, _ detail: String) {
        if ok { print("OK   \(label)") }
        else { print("FAIL \(label) — \(detail)"); failures += 1 }
    }

    static func withDB(_ url: URL, _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { fatalError("open") }
        defer { sqlite3_close(db) }
        body(db)
    }

    static func setSuppress(_ url: URL, _ on: Bool) {
        withDB(url) { db in
            exec(db, "INSERT INTO sync_meta (key, value) VALUES ('suppress_triggers', '\(on ? 1 : 0)') ON CONFLICT(key) DO UPDATE SET value='\(on ? 1 : 0)';")
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK, let msg = errmsg {
            print("SQL KO [\(String(cString: msg))] : \(sql.prefix(90))")
            sqlite3_free(errmsg)
            failures += 1
        }
    }

    static func query(_ db: OpaquePointer, _ sql: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return "<prepare KO>" }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "<no row>" }
        guard let c = sqlite3_column_text(stmt, 0) else { return "<null>" }
        return String(cString: c)
    }
}
