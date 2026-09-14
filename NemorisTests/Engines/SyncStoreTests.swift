
// SyncPayloadStore test harness — compiled standalone via run_sync_tests.sh
// against the REAL files SyncSchema.swift + SyncPayloadStore.swift (no
// logic copied). Covers the L.1 session regressions (limit .max
// overflow) and the L.2 conflict semantics.

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// The SQLite layer of CloudKit sync.
///
/// ⚠️ The fifteen scenarios share TWO databases (a source device, a
/// receiving device) and run in a fixed order — each one relies
/// on the state left by the previous ones. Splitting them into independent tests
/// would change their semantics, which isn't an option on the layer
/// that decides which data survives a merge between devices.
@Suite("Synchronisation — couche SQLite")
struct SyncStoreEngineTests {

    /// A scoping shortcut: the scenarios are static and call each other.
    private typealias S = SyncStoreEngineTests

    @Test("Les quinze scénarios de synchronisation, dans l'ordre")
    func scenariosDeSynchronisation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemoris_sync_tests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Database "B" = the local device receiving remote changes.
        let urlB = dir.appendingPathComponent("deviceB.sqlite")
        S.makeDevice(urlB)
        let storeB = SyncPayloadStore(databaseURL: urlB)

        // Database "A" = the source device for the payloads.
        let urlA = dir.appendingPathComponent("deviceA.sqlite")
        S.makeDevice(urlA)
        let storeA = SyncPayloadStore(databaseURL: urlA)

        S.t1_limitMax(storeB, urlB)
        S.t2_roundtripFKTags(storeA, urlA, storeB, urlB)
        S.t3_lww(storeB, urlB)
        S.t4_unresolvedRefs(storeB, urlB)
        S.t5_deletion(storeB, urlB)
        S.t6_deleteVsUpdate(storeB, urlB)
        S.t7_tagAdoption(storeB, urlB)
        S.t8_tricountTagLinks(storeA, urlA, storeB, urlB)
        S.t9_orderExternalIdAdoption(storeB, urlB)
        S.t10_purgeVirginSeed(storeB, urlB)
        S.t11_categoryNameAdoption(storeB, urlB)
        S.t12_dedupReferenceDuplicates(storeB, urlB)
        S.t13_deferredNotNullFK(storeA, urlA, storeB, urlB)
        S.t14_reimbursementXorDeferral(storeA, urlA, storeB, urlB)
        S.t15_metadataDoubleNotNullFK(storeA, urlA, storeB, urlB)

    }

    // MARK: - Setup

    /// Creates a database reproducing the 7 core tables + sync infra + triggers,
    /// via the REAL SyncSchema statements (the same DDL as migration v40).
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
            // — L.3 subset: tricount (generalized tag-link) + investments (external_id adoption)
            "CREATE TABLE tricount_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, tricount_key TEXT NOT NULL, title TEXT NOT NULL, my_name TEXT NOT NULL DEFAULT '', fetched_at TEXT NOT NULL DEFAULT '');",
            "CREATE TABLE tricount_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES tricount_groups(id) ON DELETE CASCADE, who_paid TEXT NOT NULL DEFAULT '', total REAL NOT NULL DEFAULT 0, date TEXT NOT NULL DEFAULT '', user_category_id INTEGER, linked_transaction_id INTEGER REFERENCES transactions(id));",
            """
            CREATE TABLE tricount_entry_tags (
                entry_id INTEGER NOT NULL REFERENCES tricount_entries(id) ON DELETE CASCADE,
                tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (entry_id, tag_id)
            );
            """,
            // — Unified reimbursement (v44, AXE R): transaction_id/tricount_entry_id XOR.
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
            // — Free-form transaction metadata (v46).
            // ⚠️ BOTH FKs are NOT NULL: this is the case that caused records to be LOST
            // in L.7 (a rejected INSERT is never re-delivered by
            // CloudKit). Deferral via `sync_deferred_rows` must catch them.
            "CREATE TABLE transaction_metadata_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, icon TEXT, sort_order INTEGER NOT NULL DEFAULT 0, role TEXT, created_at TEXT NOT NULL DEFAULT '');",
            "CREATE UNIQUE INDEX idx_tmk_name ON transaction_metadata_keys(name COLLATE NOCASE);",
            "CREATE TABLE transaction_metadata_values (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, key_id INTEGER NOT NULL REFERENCES transaction_metadata_keys(id) ON DELETE CASCADE, value TEXT NOT NULL);",
            "CREATE UNIQUE INDEX idx_tmv_pair ON transaction_metadata_values(transaction_id, key_id);",
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
        S.query(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(t)';") == "1"
    }

    // MARK: - Tests

    /// The "683 lost orders" fix: a record whose NOT NULL FK points to a
    /// target that hasn't arrived yet (CloudKit batches with no guaranteed order) must
    /// be DEFERRED then replayed once the target arrives — not lost. A
    /// full cascade: the order waits on its position, which waits on its account.
    static func t13_deferredNotNullFK(_ storeA: SyncPayloadStore, _ urlA: URL,
                                      _ storeB: SyncPayloadStore, _ urlB: URL) {
        var accUuid = "", posUuid = "", ordUuid = ""
        S.withDB(urlA) { db in
            S.exec(db, "INSERT INTO investment_accounts (name) VALUES ('PEA-T13');")
            S.exec(db, "INSERT INTO investment_positions (account_id, asset_name, ticker) VALUES ((SELECT id FROM investment_accounts WHERE name='PEA-T13'), 'Thales', 'HO-T13');")
            S.exec(db, "INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, executed_at) VALUES ((SELECT id FROM investment_positions WHERE ticker='HO-T13'), 'BUY', 3, 140, '2026-01-15');")
            accUuid = query(db, "SELECT uuid FROM investment_accounts WHERE name='PEA-T13';")
            posUuid = query(db, "SELECT uuid FROM investment_positions WHERE ticker='HO-T13';")
            ordUuid = query(db, "SELECT uuid FROM investment_orders WHERE unit_price=140;")
        }
        guard let accP = storeA.payloadJSON(table: "investment_accounts", uuid: accUuid),
              let posP = storeA.payloadJSON(table: "investment_positions", uuid: posUuid),
              let ordP = storeA.payloadJSON(table: "investment_orders", uuid: ordUuid) else {
            S.check("T13 payloads générés", false, "payloadJSON nil"); return
        }

        // Batch 1: the ORDER alone — its position doesn't exist on B yet.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "investment_orders", uuid: ordUuid, payloadData: ordP, systemFields: Data([9]))],
            deletions: [])
        S.withDB(urlB) { db in
            S.check("T13 ordre PAS inséré (FK NOT NULL absente)",
                  S.query(db, "SELECT COUNT(*) FROM investment_orders WHERE uuid='\(ordUuid)';") == "0", "")
            S.check("T13 ordre DIFFÉRÉ (pas perdu)",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(ordUuid)';") == "1", "")
            S.check("T13 system fields attachés au différé",
                  S.query(db, "SELECT length(system_fields) FROM sync_deferred_rows WHERE row_uuid='\(ordUuid)';") == "1", "")
        }

        // Batch 2: position and account DELIBERATELY out of order — the
        // internal sort (referenced-first) applies account → position, then
        // the end-of-batch replay unblocks the deferred order.
        storeB.applyRemoteBatch(
            modifications: [
                .init(table: "investment_positions", uuid: posUuid, payloadData: posP, systemFields: Data([8])),
                .init(table: "investment_accounts", uuid: accUuid, payloadData: accP, systemFields: Data([7])),
            ],
            deletions: [])
        S.withDB(urlB) { db in
            let posId = query(db, "SELECT id FROM investment_positions WHERE uuid='\(posUuid)';")
            S.check("T13 position appliquée (compte trié avant)", posId != "<no row>", "posId=\(posId)")
            S.check("T13 ordre rejoué avec la bonne FK",
                  S.query(db, "SELECT position_id FROM investment_orders WHERE uuid='\(ordUuid)';") == posId, "")
            S.check("T13 file des différés soldée",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows;") == "0", "")
            S.check("T13 system fields promus en record_meta",
                  S.query(db, "SELECT COUNT(*) FROM sync_record_meta WHERE row_uuid='\(ordUuid)';") == "1", "")
        }
    }

    /// v46: a metadata value has TWO NOT NULL FKs (transaction + key).
    ///
    /// ⚠️ This is the exact configuration that caused 683 orders to be LOST in L.7: a
    /// record whose NOT NULL FK isn't resolved yet has its INSERT
    /// rejected, and CloudKit NEVER re-delivers an unapplied fetched record.
    /// Deferral (`sync_deferred_rows`, v43) must therefore catch it — and here
    /// BOTH targets must arrive before it goes through.
    static func t15_metadataDoubleNotNullFK(_ storeA: SyncPayloadStore, _ urlA: URL,
                                            _ storeB: SyncPayloadStore, _ urlB: URL) {
        var keyUuid = "", txUuid = "", valueUuid = ""
        S.withDB(urlA) { db in
            S.exec(db, "INSERT INTO transaction_metadata_keys (name, created_at) VALUES ('Projet-T15', '');")
            S.exec(db, "INSERT INTO transactions (amount, information) VALUES (-15, 'Achat T15');")
            S.exec(db, """
                INSERT INTO transaction_metadata_values (transaction_id, key_id, value)
                VALUES ((SELECT id FROM transactions WHERE information='Achat T15'),
                        (SELECT id FROM transaction_metadata_keys WHERE name='Projet-T15'),
                        'Cuisine');
                """)
            keyUuid = query(db, "SELECT uuid FROM transaction_metadata_keys WHERE name='Projet-T15';")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE information='Achat T15';")
            valueUuid = query(db, "SELECT uuid FROM transaction_metadata_values WHERE value='Cuisine';")
        }
        guard let keyP = storeA.payloadJSON(table: "transaction_metadata_keys", uuid: keyUuid),
              let txP = storeA.payloadJSON(table: "transactions", uuid: txUuid),
              let valueP = storeA.payloadJSON(table: "transaction_metadata_values", uuid: valueUuid) else {
            S.check("T15 payloads générés", false, "payloadJSON nil"); return
        }

        // Batch 1: the value ALONE — neither its transaction nor its key exist on B.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "transaction_metadata_values", uuid: valueUuid,
                                  payloadData: valueP, systemFields: Data([7]))],
            deletions: [])
        S.withDB(urlB) { db in
            S.check("T15 valeur PAS insérée (2 FK NOT NULL absentes)",
                  S.query(db, "SELECT COUNT(*) FROM transaction_metadata_values WHERE uuid='\(valueUuid)';") == "0", "")
            S.check("T15 valeur DIFFÉRÉE (pas perdue)",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(valueUuid)';") == "1", "")
        }

        // Batch 2: the key alone — only one of the two targets, so STILL blocked.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "transaction_metadata_keys", uuid: keyUuid,
                                  payloadData: keyP, systemFields: Data([6]))],
            deletions: [])
        S.withDB(urlB) { db in
            S.check("T15 toujours différée avec UNE seule cible résolue",
                  S.query(db, "SELECT COUNT(*) FROM transaction_metadata_values WHERE uuid='\(valueUuid)';") == "0", "")
        }

        // Batch 3: the transaction arrives — both targets are there, the
        // end-of-batch replay unblocks the value.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "transactions", uuid: txUuid, payloadData: txP, systemFields: Data([5]))],
            deletions: [])
        S.withDB(urlB) { db in
            S.check("T15 valeur rejouée une fois les 2 cibles présentes",
                  S.query(db, "SELECT COUNT(*) FROM transaction_metadata_values WHERE uuid='\(valueUuid)';") == "1", "")
            S.check("T15 valeur correcte",
                  S.query(db, "SELECT value FROM transaction_metadata_values WHERE uuid='\(valueUuid)';") == "Cuisine", "")
            S.check("T15 FK clé correctement résolue",
                  S.query(db, """
                      SELECT k.name FROM transaction_metadata_values v
                      JOIN transaction_metadata_keys k ON k.id = v.key_id
                      WHERE v.uuid='\(valueUuid)';
                      """) == "Projet-T15", "")
            S.check("T15 file des différés soldée",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(valueUuid)';") == "0", "")
        }
    }

    /// v44 AXE R: the XOR CHECK (transaction_id / tricount_entry_id) isn't
    /// just an integrity constraint — it lets the deferral mechanism (v43)
    /// catch a `reimbursements` row whose target transaction
    /// arrives LATER (CloudKit batches with no guaranteed order). Without it, the INSERT
    /// would succeed with BOTH transaction_id AND tricount_entry_id NULL (a phantom
    /// row never repaired) instead of failing and being deferred.
    static func t14_reimbursementXorDeferral(_ storeA: SyncPayloadStore, _ urlA: URL,
                                             _ storeB: SyncPayloadStore, _ urlB: URL) {
        var payeeUuid = "", txUuid = "", reimbUuid = ""
        S.withDB(urlA) { db in
            S.exec(db, "INSERT INTO payees (name) VALUES ('Papa-T14');")
            S.exec(db, "INSERT INTO transactions (amount, information) VALUES (-80, 'Cadeau T14');")
            S.exec(db, "INSERT INTO reimbursements (transaction_id, payee_id) VALUES ((SELECT id FROM transactions WHERE information='Cadeau T14'), (SELECT id FROM payees WHERE name='Papa-T14'));")
            payeeUuid = query(db, "SELECT uuid FROM payees WHERE name='Papa-T14';")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE information='Cadeau T14';")
            reimbUuid = query(db, "SELECT uuid FROM reimbursements WHERE payee_id=(SELECT id FROM payees WHERE name='Papa-T14');")
        }
        guard let payeeP = storeA.payloadJSON(table: "payees", uuid: payeeUuid),
              let txP = storeA.payloadJSON(table: "transactions", uuid: txUuid),
              let reimbP = storeA.payloadJSON(table: "reimbursements", uuid: reimbUuid) else {
            S.check("T14 payloads générés", false, "payloadJSON nil"); return
        }

        // Precondition: the payee already exists on B (payee_id FK resolves OK)
        // — only the transaction_id FK should be a problem.
        S.setSuppress(urlB, true)
        S.check("T14 apply payee (précondition)", storeB.applyRemoteRecord(table: "payees", payloadData: payeeP) == .applied, "")
        S.setSuppress(urlB, false)

        // Batch 1: the reimbursement alone — its transaction doesn't exist on B yet.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "reimbursements", uuid: reimbUuid, payloadData: reimbP, systemFields: Data([9]))],
            deletions: [])
        S.withDB(urlB) { db in
            S.check("T14 remboursement PAS inséré (CHECK XOR violé)",
                  S.query(db, "SELECT COUNT(*) FROM reimbursements WHERE uuid='\(reimbUuid)';") == "0", "")
            S.check("T14 remboursement DIFFÉRÉ (pas perdu)",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows WHERE row_uuid='\(reimbUuid)';") == "1", "")
        }

        // Batch 2: the transaction arrives — the end-of-batch replay unblocks
        // the deferred reimbursement.
        storeB.applyRemoteBatch(
            modifications: [.init(table: "transactions", uuid: txUuid, payloadData: txP, systemFields: Data([8]))],
            deletions: [])
        S.withDB(urlB) { db in
            let txId = query(db, "SELECT id FROM transactions WHERE uuid='\(txUuid)';")
            S.check("T14 transaction appliquée", txId != "<no row>", "txId=\(txId)")
            S.check("T14 remboursement rejoué avec la bonne FK",
                  S.query(db, "SELECT transaction_id FROM reimbursements WHERE uuid='\(reimbUuid)';") == txId, "")
            S.check("T14 tricount_entry_id resté NULL (XOR respecté)",
                  S.query(db, "SELECT tricount_entry_id IS NULL FROM reimbursements WHERE uuid='\(reimbUuid)';") == "1", "")
            S.check("T14 file des différés soldée",
                  S.query(db, "SELECT COUNT(*) FROM sync_deferred_rows;") == "0", "")
        }
    }

    /// L.1 session regression: `Int32(Int.max)` used to crash. The clamp must
    /// make EVERY row overflow-free.
    static func t1_limitMax(_ store: SyncPayloadStore, _ url: URL) {
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO tags (name) VALUES ('a'), ('b'), ('c');")
        }
        let all = store.pendingRows(limit: .max)
        S.check("T1 pendingRows(.max) sans crash, rend tout", all.count == 3, "attendu 3, obtenu \(all.count)")
        let capped = store.pendingRows(limit: 2)
        S.check("T1 limit fini respecté", capped.count == 2, "attendu 2, obtenu \(capped.count)")
        _ = store.tombstoneRows(limit: .max)   // ne doit pas crasher
        S.withDB(url) { db in
            S.exec(db, "DELETE FROM tags; DELETE FROM sync_pending; DELETE FROM sync_tombstones;")
        }
    }

    /// A→B roundtrip: payee + transaction + tag. On B the local ids
    /// differ (deliberately shifted) — the FK must resolve via uuid.
    static func t2_roundtripFKTags(_ storeA: SyncPayloadStore, _ urlA: URL,
                                   _ storeB: SyncPayloadStore, _ urlB: URL) {
        var payeeUuid = "", txUuid = "", tagUuid = ""
        S.withDB(urlA) { db in
            S.exec(db, "INSERT INTO payees (name) VALUES ('Carrefour');")
            S.exec(db, "INSERT INTO transactions (payee_id, amount, libelle_brut) VALUES (1, -42.5, 'CARREFOUR PARIS');")
            S.exec(db, "INSERT INTO tags (name) VALUES ('courses');")
            S.exec(db, "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (1, 1);")
            payeeUuid = query(db, "SELECT uuid FROM payees WHERE id = 1;")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE id = 1;")
            tagUuid = query(db, "SELECT uuid FROM tags WHERE id = 1;")
        }
        guard let payeePayload = storeA.payloadJSON(table: "payees", uuid: payeeUuid),
              let txPayload = storeA.payloadJSON(table: "transactions", uuid: txUuid),
              let tagPayload = storeA.payloadJSON(table: "tags", uuid: tagUuid) else {
            S.check("T2 payloads générés", false, "payloadJSON nil"); return
        }
        // Verifies the format: FK as uuid in "r", tags in "g".
        let obj = try! JSONSerialization.jsonObject(with: txPayload) as! [String: Any]
        S.check("T2 FK sérialisée en uuid", (obj["r"] as? [String: String])?["payee_id"] == payeeUuid, "r=\(String(describing: obj["r"]))")
        S.check("T2 tags embarqués", (obj["g"] as? [String]) == [tagUuid], "g=\(String(describing: obj["g"]))")

        // Shifts the ids on B to prove resolution goes through uuid.
        S.withDB(urlB) { db in
            S.exec(db, "INSERT INTO sync_meta (key, value) VALUES ('suppress_triggers', '1') ON CONFLICT(key) DO UPDATE SET value='1';")
            S.exec(db, "INSERT INTO payees (id, name, uuid, updated_at) VALUES (77, 'décalage', lower(hex(randomblob(16))), '2020-01-01T00:00:00.000Z');")
        }
        S.check("T2 apply payee", storeB.applyRemoteRecord(table: "payees", payloadData: payeePayload) == .applied, "")
        S.check("T2 apply tag", storeB.applyRemoteRecord(table: "tags", payloadData: tagPayload) == .applied, "")
        S.check("T2 apply transaction", storeB.applyRemoteRecord(table: "transactions", payloadData: txPayload) == .applied, "")
        S.withDB(urlB) { db in
            let localPayeeId = query(db, "SELECT id FROM payees WHERE uuid = '\(payeeUuid)';")
            S.check("T2 payee inséré avec id local ≠ A", localPayeeId == "78", "id=\(localPayeeId)")
            let fk = query(db, "SELECT payee_id FROM transactions WHERE uuid = '\(txUuid)';")
            S.check("T2 FK résolue vers l'id local", fk == localPayeeId, "payee_id=\(fk) vs \(localPayeeId)")
            let linked = query(db, "SELECT COUNT(*) FROM transaction_tags tt JOIN transactions t ON t.id = tt.transaction_id WHERE t.uuid = '\(txUuid)';")
            S.check("T2 lien tag reconstruit", linked == "1", "liens=\(linked)")
            S.exec(db, "UPDATE sync_meta SET value='0' WHERE key='suppress_triggers';")
        }
    }

    /// LWW: a payload OLDER than the local row is ignored.
    static func t3_lww(_ store: SyncPayloadStore, _ url: URL) {
        var uuid = ""
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO categories (name) VALUES ('Récent local');")
            uuid = query(db, "SELECT uuid FROM categories WHERE name = 'Récent local';")
        }
        let old: [String: Any] = ["u": uuid, "t": "2000-01-01T00:00:00.000Z", "v": ["name": "Vieux distant"]]
        let data = try! JSONSerialization.data(withJSONObject: old)
        S.setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "categories", payloadData: data)
        S.setSuppress(url, false)
        S.check("T3 LWW skip (local plus récent)", r == .skippedLocalNewer, "résultat=\(r)")
        S.withDB(url) { db in
            S.check("T3 contenu local préservé", query(db, "SELECT name FROM categories WHERE uuid='\(uuid)';") == "Récent local", "")
        }
    }

    /// A FK to a target that hasn't arrived yet → NULL + unresolved, resolved later.
    static func t4_unresolvedRefs(_ store: SyncPayloadStore, _ url: URL) {
        let payeeUuid = String(repeating: "1", count: 32)
        let txUuid = String(repeating: "2", count: 32)
        let tx: [String: Any] = ["u": txUuid, "t": "2999-01-01T00:00:00.000Z",
                                 "v": ["amount": -10.0], "r": ["payee_id": payeeUuid]]
        S.setSuppress(url, true)
        S.check("T4 apply tx orpheline", store.applyRemoteRecord(table: "transactions", payloadData: try! JSONSerialization.data(withJSONObject: tx)) == .applied, "")
        S.withDB(url) { db in
            S.check("T4 FK NULL en attendant", query(db, "SELECT payee_id IS NULL FROM transactions WHERE uuid='\(txUuid)';") == "1", "")
            S.check("T4 ref en attente enregistrée", query(db, "SELECT COUNT(*) FROM sync_unresolved_refs WHERE row_uuid='\(txUuid)';") == "1", "")
        }
        let payee: [String: Any] = ["u": payeeUuid, "t": "2999-01-01T00:00:00.000Z", "v": ["name": "Retardataire"]]
        S.check("T4 apply payee retard", store.applyRemoteRecord(table: "payees", payloadData: try! JSONSerialization.data(withJSONObject: payee)) == .applied, "")
        store.resolveUnresolvedRefs()
        S.setSuppress(url, false)
        S.withDB(url) { db in
            let expected = query(db, "SELECT id FROM payees WHERE uuid='\(payeeUuid)';")
            S.check("T4 FK résolue après coup", query(db, "SELECT payee_id FROM transactions WHERE uuid='\(txUuid)';") == expected, "")
            S.check("T4 file unresolved vidée", query(db, "SELECT COUNT(*) FROM sync_unresolved_refs;") == "0", "")
        }
    }

    /// A remote deletion of a clean row: applied, tag links cleaned up.
    static func t5_deletion(_ store: SyncPayloadStore, _ url: URL) {
        var txUuid = "", txId = ""
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO transactions (amount) VALUES (-5);")
            txUuid = query(db, "SELECT uuid FROM transactions WHERE amount = -5;")
            S.exec(db, "INSERT INTO tags (name) VALUES ('t5tag');")
            txId = query(db, "SELECT id FROM transactions WHERE uuid='\(txUuid)';")
            let tagId = query(db, "SELECT id FROM tags WHERE name='t5tag';")
            S.exec(db, "INSERT INTO transaction_tags VALUES (\(txId), \(tagId));")
            S.exec(db, "DELETE FROM sync_pending;")   // a "clean" row (already synced)
        }
        S.setSuppress(url, true)
        store.applyRemoteDeletion(table: "transactions", uuid: txUuid)
        S.setSuppress(url, false)
        S.withDB(url) { db in
            S.check("T5 row supprimée", query(db, "SELECT COUNT(*) FROM transactions WHERE uuid='\(txUuid)';") == "0", "")
            S.check("T5 liens tags purgés", query(db, "SELECT COUNT(*) FROM transaction_tags WHERE transaction_id = \(txId);") == "0", "")
        }
    }

    /// Delete-vs-update: the row has a PENDING local edit → the
    /// remote deletion is ignored, the edit survives.
    static func t6_deleteVsUpdate(_ store: SyncPayloadStore, _ url: URL) {
        var uuid = ""
        S.withDB(url) { db in
            S.exec(db, "DELETE FROM sync_pending;")
            S.exec(db, "INSERT INTO payees (name) VALUES ('Édité localement');")   // trigger → pending
            uuid = query(db, "SELECT uuid FROM payees WHERE name = 'Édité localement';")
            S.check("T6 précondition : row pending", query(db, "SELECT COUNT(*) FROM sync_pending WHERE row_uuid='\(uuid)';") == "1", "")
        }
        S.setSuppress(url, true)
        store.applyRemoteDeletion(table: "payees", uuid: uuid)
        S.setSuppress(url, false)
        S.withDB(url) { db in
            S.check("T6 l'édition locale survit au delete distant", query(db, "SELECT COUNT(*) FROM payees WHERE uuid='\(uuid)';") == "1", "")
        }
    }

    /// Adoption: a 'vacances' tag created independently on both sides →
    /// identity merge on the remote uuid + tombstone for the old one.
    static func t7_tagAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var oldUuid = ""
        S.withDB(url) { db in
            S.exec(db, "DELETE FROM sync_pending; DELETE FROM sync_tombstones;")
            S.exec(db, "INSERT INTO tags (name) VALUES ('vacances');")   // → pending, uuid local
            oldUuid = query(db, "SELECT uuid FROM tags WHERE name = 'vacances';")
        }
        // A deterministic rule: the SMALLEST uuid wins — remote "000…1" beats
        // any random local uuid.
        let remoteUuid = String(repeating: "0", count: 31) + "1"
        let remote: [String: Any] = ["u": remoteUuid, "t": "2999-01-01T00:00:00.000Z",
                                     "v": ["name": "Vacances", "color": "#00FF00"]]
        S.setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "tags", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        S.setSuppress(url, false)
        S.check("T7 apply avec adoption réussit", r == .applied, "résultat=\(r)")
        S.withDB(url) { db in
            S.check("T7 une seule row (pas de doublon)", query(db, "SELECT COUNT(*) FROM tags WHERE name = 'Vacances' COLLATE NOCASE;") == "1", "")
            S.check("T7 uuid distant adopté", query(db, "SELECT uuid FROM tags WHERE name='Vacances';") == remoteUuid, "")
            S.check("T7 contenu distant appliqué (LWW)", query(db, "SELECT color FROM tags WHERE uuid='\(remoteUuid)';") == "#00FF00", "")
            S.check("T7 tombstone de l'ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
            S.check("T7 pending de l'ancien uuid purgé", query(db, "SELECT COUNT(*) FROM sync_pending WHERE row_uuid='\(oldUuid)';") == "0", "")
        }

        // The reverse case: a remote with a LARGER uuid doesn't steal
        // identity (anti ping-pong — it's the other device that will adopt our uuid).
        let bigUuid = String(repeating: "f", count: 32)
        let big: [String: Any] = ["u": bigUuid, "t": "2999-06-01T00:00:00.000Z", "v": ["name": "vacances"]]
        S.setSuppress(url, true)
        let r2 = store.applyRemoteRecord(table: "tags", payloadData: try! JSONSerialization.data(withJSONObject: big))
        S.setSuppress(url, false)
        S.check("T7b local (petit uuid) gagne : record ignoré", r2 == .failed, "résultat=\(r2)")
        S.withDB(url) { db in
            S.check("T7b toujours une seule row", query(db, "SELECT COUNT(*) FROM tags WHERE name='vacances' COLLATE NOCASE;") == "1", "")
            S.check("T7b uuid conservé", query(db, "SELECT uuid FROM tags WHERE name='Vacances';") == remoteUuid, "")
        }
    }

    /// L.3: the generalized "g" mechanism works for tricount_entries.
    static func t8_tricountTagLinks(_ storeA: SyncPayloadStore, _ urlA: URL,
                                    _ storeB: SyncPayloadStore, _ urlB: URL) {
        var groupUuid = "", entryUuid = "", tagUuid = ""
        S.withDB(urlA) { db in
            S.exec(db, "INSERT INTO tricount_groups (tricount_key, title) VALUES ('k1', 'Vacances 2026');")
            S.exec(db, "INSERT INTO tricount_entries (group_id, who_paid, total, date) VALUES (1, 'Edwin', 120, '2026-07-01');")
            S.exec(db, "INSERT INTO tags (name) VALUES ('t8tag');")
            let tagId = query(db, "SELECT id FROM tags WHERE name='t8tag';")
            S.exec(db, "INSERT INTO tricount_entry_tags (entry_id, tag_id) VALUES (1, \(tagId));")
            groupUuid = query(db, "SELECT uuid FROM tricount_groups WHERE id=1;")
            entryUuid = query(db, "SELECT uuid FROM tricount_entries WHERE id=1;")
            tagUuid = query(db, "SELECT uuid FROM tags WHERE name='t8tag';")
        }
        guard let g = storeA.payloadJSON(table: "tricount_groups", uuid: groupUuid),
              let e = storeA.payloadJSON(table: "tricount_entries", uuid: entryUuid),
              let t = storeA.payloadJSON(table: "tags", uuid: tagUuid) else {
            S.check("T8 payloads générés", false, "nil"); return
        }
        let obj = try! JSONSerialization.jsonObject(with: e) as! [String: Any]
        S.check("T8 tags tricount embarqués", (obj["g"] as? [String]) == [tagUuid], "g=\(String(describing: obj["g"]))")

        S.setSuppress(urlB, true)
        S.check("T8 apply group", storeB.applyRemoteRecord(table: "tricount_groups", payloadData: g) == .applied, "")
        S.check("T8 apply tag", storeB.applyRemoteRecord(table: "tags", payloadData: t) == .applied, "")
        S.check("T8 apply entry", storeB.applyRemoteRecord(table: "tricount_entries", payloadData: e) == .applied, "")
        S.setSuppress(urlB, false)
        S.withDB(urlB) { db in
            let linked = query(db, "SELECT COUNT(*) FROM tricount_entry_tags et JOIN tricount_entries te ON te.id = et.entry_id WHERE te.uuid = '\(entryUuid)';")
            S.check("T8 lien tag tricount reconstruit", linked == "1", "liens=\(linked)")
            let fk = query(db, "SELECT tg.uuid FROM tricount_entries te JOIN tricount_groups tg ON tg.id = te.group_id WHERE te.uuid = '\(entryUuid)';")
            S.check("T8 FK group résolue", fk == groupUuid, "fk=\(fk)")
        }
    }

    /// L.3: two devices importing the same Binance trade (same
    /// external_id) → adoption instead of a looping INSERT failure.
    static func t9_orderExternalIdAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var posUuid = "", oldUuid = ""
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO investment_accounts (name) VALUES ('Binance');")
            S.exec(db, "INSERT INTO investment_positions (account_id, asset_name, ticker) VALUES (1, 'Bitcoin', 'BTC');")
            S.exec(db, "INSERT INTO investment_orders (position_id, order_type, quantity, unit_price, executed_at, external_id) VALUES (1, 'BUY', 0.5, 40000, '2026-01-15', 'binance_BTCUSDT_777');")
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
        S.setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "investment_orders", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        S.setSuppress(url, false)
        S.check("T9 apply avec adoption external_id", r == .applied, "résultat=\(r)")
        S.withDB(url) { db in
            S.check("T9 un seul ordre (pas de doublon)", query(db, "SELECT COUNT(*) FROM investment_orders WHERE external_id='binance_BTCUSDT_777';") == "1", "")
            S.check("T9 uuid distant adopté", query(db, "SELECT uuid FROM investment_orders WHERE external_id='binance_BTCUSDT_777';") == remoteUuid, "")
            S.check("T9 tombstone ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
        }
    }

    /// Purging the seed on a virgin database (the "Join via iCloud" flow): the
    /// factory-seeded categories/payment_types of a database with NO transactions are
    /// removed before the vault comes down — no seed duplicates.
    static func t10_purgeVirginSeed(_ storeB: SyncPayloadStore, _ urlB: URL) {
        // A fresh database C: factory seed, zero transactions.
        let urlC = urlB.deletingLastPathComponent().appendingPathComponent("deviceC.sqlite")
        S.makeDevice(urlC)
        let storeC = SyncPayloadStore(databaseURL: urlC)
        S.withDB(urlC) { db in
            S.exec(db, "INSERT INTO categories (name) VALUES ('Transport');")
            S.exec(db, "INSERT INTO categories (name, parent_id) VALUES ('Carburant', 1);")
            S.exec(db, "INSERT INTO categories (name) VALUES ('Ma catégorie perso');")
            S.exec(db, "INSERT INTO payment_types (name) VALUES ('Carte bancaire');")
        }
        let purged = storeC.purgeVirginSeedReferenceData()
        S.check("T10 purge seed base vierge (3 rows usine)", purged == 3, "purgé=\(purged)")
        S.withDB(urlC) { db in
            S.check("T10 la catégorie perso survit", query(db, "SELECT COUNT(*) FROM categories WHERE name='Ma catégorie perso';") == "1", "")
            S.check("T10 seed usine retiré", query(db, "SELECT COUNT(*) FROM categories WHERE name IN ('Transport','Carburant');") == "0", "")
        }
        // Database B (has transactions): the purge is a no-op.
        let purgedB = storeB.purgeVirginSeedReferenceData()
        S.check("T10 no-op si base utilisée", purgedB == 0, "purgé=\(purgedB)")
    }

    /// PROACTIVE adoption by name: a seed category present on both sides
    /// (no UNIQUE constraint) → merged instead of a silent duplicate.
    static func t11_categoryNameAdoption(_ store: SyncPayloadStore, _ url: URL) {
        var oldUuid = ""
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO categories (name, icon) VALUES ('Santé', 'heart.fill');")
            oldUuid = query(db, "SELECT uuid FROM categories WHERE name='Santé';")
        }
        let remoteUuid = String(repeating: "0", count: 31) + "3"
        let remote: [String: Any] = ["u": remoteUuid, "t": "2999-01-01T00:00:00.000Z",
                                     "v": ["name": "Santé", "icon": "cross.fill"]]
        S.setSuppress(url, true)
        let r = store.applyRemoteRecord(table: "categories", payloadData: try! JSONSerialization.data(withJSONObject: remote))
        S.setSuppress(url, false)
        S.check("T11 apply avec adoption par nom", r == .applied, "résultat=\(r)")
        S.withDB(url) { db in
            S.check("T11 une seule 'Santé' (pas de doublon)", query(db, "SELECT COUNT(*) FROM categories WHERE name='Santé';") == "1", "")
            S.check("T11 uuid distant adopté", query(db, "SELECT uuid FROM categories WHERE name='Santé';") == remoteUuid, "")
            S.check("T11 contenu distant appliqué", query(db, "SELECT icon FROM categories WHERE name='Santé';") == "cross.fill", "")
            S.check("T11 tombstone ancien uuid", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE row_uuid='\(oldUuid)';") == "1", "")
        }

        // The proactive path, reversed: a same-named remote with a larger uuid
        // → NO insert (duplicate avoided), no adoption (local wins).
        let bigUuid = String(repeating: "f", count: 32)
        let big: [String: Any] = ["u": bigUuid, "t": "2999-06-01T00:00:00.000Z", "v": ["name": "Santé"]]
        S.setSuppress(url, true)
        let r2 = store.applyRemoteRecord(table: "categories", payloadData: try! JSONSerialization.data(withJSONObject: big))
        S.setSuppress(url, false)
        S.check("T11b local gagne : skip sans doublon", r2 == .skippedLocalNewer, "résultat=\(r2)")
        S.withDB(url) { db in
            S.check("T11b toujours une seule 'Santé'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Santé';") == "1", "")
            S.check("T11b uuid conservé", query(db, "SELECT uuid FROM categories WHERE name='Santé';") == remoteUuid, "")
        }
    }

    /// One-shot seed-duplicate repair (post-L.1): keeper = smallest
    /// uuid, FKs remapped, tombstones propagated — parent hierarchy included.
    static func t12_dedupReferenceDuplicates(_ store: SyncPayloadStore, _ url: URL) {
        let keepUuid = String(repeating: "a", count: 32)
        let dupeUuid = String(repeating: "f", count: 32)
        let keepChildUuid = String(repeating: "b", count: 32)
        let dupeChildUuid = String(repeating: "e", count: 32)
        var keepId = "", dupeId = ""
        S.withDB(url) { db in
            S.exec(db, "DELETE FROM sync_tombstones;")
            S.exec(db, "INSERT INTO categories (name, uuid, updated_at) VALUES ('Courses', '\(keepUuid)', '2026-01-01T00:00:00.000Z');")
            S.exec(db, "INSERT INTO categories (name, uuid, updated_at) VALUES ('Courses', '\(dupeUuid)', '2026-01-01T00:00:00.000Z');")
            keepId = query(db, "SELECT id FROM categories WHERE uuid='\(keepUuid)';")
            dupeId = query(db, "SELECT id FROM categories WHERE uuid='\(dupeUuid)';")
            // A "Bio" subcategory under EACH duplicate → the same key (name+parent).
            S.exec(db, "INSERT INTO categories (name, parent_id, uuid, updated_at) VALUES ('Bio', \(keepId), '\(keepChildUuid)', '2026-01-01T00:00:00.000Z');")
            S.exec(db, "INSERT INTO categories (name, parent_id, uuid, updated_at) VALUES ('Bio', \(dupeId), '\(dupeChildUuid)', '2026-01-01T00:00:00.000Z');")
            // A transaction attached to the DUPLICATE → must be remapped.
            S.exec(db, "INSERT INTO transactions (category_id, amount) VALUES (\(dupeId), -12.5);")
            // Doublon payment_types.
            S.exec(db, "INSERT INTO payment_types (name, uuid, updated_at) VALUES ('CB test', '\(keepUuid)', '2026-01-01T00:00:00.000Z');")
            S.exec(db, "INSERT INTO payment_types (name, uuid, updated_at) VALUES ('CB test', '\(dupeUuid)', '2026-01-01T00:00:00.000Z');")

            let merged = SyncPayloadStore.dedupReferenceDuplicates(db)
            S.check("T12 fusions effectuées (3 attendues)", merged == 3, "merged=\(merged)")

            S.check("T12 une seule 'Courses'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Courses';") == "1", "")
            S.check("T12 keeper = plus petit uuid", query(db, "SELECT uuid FROM categories WHERE name='Courses';") == keepUuid, "")
            S.check("T12 transaction remappée vers keeper", query(db, "SELECT category_id FROM transactions WHERE amount=-12.5;") == keepId, "")
            S.check("T12 une seule 'Bio'", query(db, "SELECT COUNT(*) FROM categories WHERE name='Bio';") == "1", "")
            S.check("T12 'Bio' rattachée au keeper", query(db, "SELECT parent_id FROM categories WHERE name='Bio';") == keepId, "")
            S.check("T12 tombstone doublon 'Courses'", query(db, "SELECT COUNT(*) FROM sync_tombstones WHERE table_name='categories' AND row_uuid='\(dupeUuid)';") == "1", "")
            S.check("T12 un seul 'CB test'", query(db, "SELECT COUNT(*) FROM payment_types WHERE name='CB test';") == "1", "")
            S.check("T12 rerun = no-op", SyncPayloadStore.dedupReferenceDuplicates(db) == 0, "")
        }
    }

    // MARK: - Helpers

    /// `sourceLocation` propagates the caller's position: without it, every
    /// failure would point to this line instead of the actual scenario.
    static func check(_ label: String, _ ok: Bool, _ detail: String,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(ok, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }

    static func withDB(_ url: URL, _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { fatalError("open") }
        defer { sqlite3_close(db) }
        body(db)
    }

    static func setSuppress(_ url: URL, _ on: Bool) {
        S.withDB(url) { db in
            S.exec(db, "INSERT INTO sync_meta (key, value) VALUES ('suppress_triggers', '\(on ? 1 : 0)') ON CONFLICT(key) DO UPDATE SET value='\(on ? 1 : 0)';")
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK, let msg = errmsg {
            print("SQL KO [\(String(cString: msg))] : \(sql.prefix(90))")
            sqlite3_free(errmsg)
            Issue.record("SQL en échec : \(sql.prefix(90))")
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
