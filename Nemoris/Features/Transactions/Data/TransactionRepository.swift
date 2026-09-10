import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TransactionRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    func fetchAccounts() -> [Account] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, ''), COALESCE(type, 'COURANT'), COALESCE(excluded_from_aggregates, 0) FROM accounts ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [Account] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Account(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    type: string(from: stmt, index: 2),
                    excludedFromAggregates: sqlite3_column_int(stmt, 3) != 0
                ))
            }
            return items
        }) ?? []
    }

    /// Fragment SQL partagé : exclut les transactions rattachées à un compte
    /// marqué "hors calculs agrégés" (v51). Même convention que le fragment
    /// d'exclusion des virements internes juste en dessous — jointure sur
    /// `accounts` plutôt qu'une sous-requête, pour rester un simple `AND` collable
    /// dans un WHERE existant. `IS NULL` couvre les lignes orphelines (compte
    /// supprimé) : on ne les exclut pas silencieusement, ce n'est pas leur rôle.
    private static let excludedAccountsClause =
        "(a.excluded_from_aggregates IS NULL OR a.excluded_from_aggregates = 0)"
    private static let excludedAccountsJoin =
        "LEFT JOIN accounts a ON a.id = t.account_id"

    /// `accountId == 0` est traité comme le sentinel "Tous les comptes" : la clause
    /// `t.account_id = ?` est alors retirée du WHERE. Cohérent avec le picker
    /// `TransactionFiltersSheet` qui expose une entrée "Tous les comptes" (tag 0).
    func fetchTransactions(accountId: Int, from: Date, to: Date, limit: Int = 100, offset: Int = 0) -> [FinanceTransaction] {
        let normalizedFrom = min(from, to)
        let normalizedTo = max(from, to)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fromRaw = formatter.string(from: normalizedFrom)
        let toRaw = formatter.string(from: normalizedTo)

        return query(read: { db in
            let accountClause = accountId == 0 ? "" : "t.account_id = ? AND"
            let sql = """
            SELECT
                t.id,
                t.account_id,
                COALESCE(ti.name, ''),
                COALESCE(c.name, ''),
                COALESCE(m.name, ''),
                COALESCE(t.information, ''),
                t.amount,
                COALESCE(t.tx_date, ''),
                t.payee_id,
                t.category_id,
                t.payment_type_id,
                rb.payee_id,
                COALESCE(tr.name, ''),
                t.libelle_brut
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN payment_types m ON m.id = t.payment_type_id
            LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
            LEFT JOIN payees tr ON tr.id = rb.payee_id
            WHERE \(accountClause) t.tx_date >= ?
              AND t.tx_date <= ?
            ORDER BY t.tx_date DESC, t.id DESC
            LIMIT ? OFFSET ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var col: Int32 = 1
            if accountId != 0 {
                sqlite3_bind_int(stmt, col, Int32(accountId)); col += 1
            }
            sqlite3_bind_text(stmt, col, fromRaw, -1, SQLITE_TRANSIENT); col += 1
            sqlite3_bind_text(stmt, col, toRaw, -1, SQLITE_TRANSIENT); col += 1
            sqlite3_bind_int(stmt, col, Int32(limit)); col += 1
            sqlite3_bind_int(stmt, col, Int32(offset))

            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }

            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(
                    FinanceTransaction(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        accountId: Int(sqlite3_column_int(stmt, 1)),
                        tiersId: optInt(8),
                        categoryId: optInt(9),
                        paymentTypeId: optInt(10),
                        remboursementTiersId: optInt(11),
                        tiersName: string(from: stmt, index: 2),
                        categoryName: string(from: stmt, index: 3),
                        paymentTypeName: string(from: stmt, index: 4),
                        remboursementTiersName: string(from: stmt, index: 12),
                        information: string(from: stmt, index: 5),
                        libelleBrut: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : string(from: stmt, index: 13),
                        amount: sqlite3_column_double(stmt, 6),
                        date: formatter.date(from: string(from: stmt, index: 7)) ?? Date()
                    )
                )
            }

            return results
        }) ?? []
    }

    /// Fetch d'une transaction unique par id (utilisé par le pane détail macOS
    /// pour rafraîchir après une édition). Mêmes JOINs que `fetchTransactions`.
    func fetchTransaction(id: Int) -> FinanceTransaction? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return query(read: { db in
            let sql = """
            SELECT
                t.id,
                t.account_id,
                COALESCE(ti.name, ''),
                COALESCE(c.name, ''),
                COALESCE(m.name, ''),
                COALESCE(t.information, ''),
                t.amount,
                COALESCE(t.tx_date, ''),
                t.payee_id,
                t.category_id,
                t.payment_type_id,
                rb.payee_id,
                COALESCE(tr.name, ''),
                t.libelle_brut
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN payment_types m ON m.id = t.payment_type_id
            LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
            LEFT JOIN payees tr ON tr.id = rb.payee_id
            WHERE t.id = ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(id))

            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return FinanceTransaction(
                id: Int(sqlite3_column_int(stmt, 0)),
                accountId: Int(sqlite3_column_int(stmt, 1)),
                tiersId: optInt(8),
                categoryId: optInt(9),
                paymentTypeId: optInt(10),
                remboursementTiersId: optInt(11),
                tiersName: string(from: stmt, index: 2),
                categoryName: string(from: stmt, index: 3),
                paymentTypeName: string(from: stmt, index: 4),
                remboursementTiersName: string(from: stmt, index: 12),
                information: string(from: stmt, index: 5),
                libelleBrut: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : string(from: stmt, index: 13),
                amount: sqlite3_column_double(stmt, 6),
                date: formatter.date(from: string(from: stmt, index: 7)) ?? Date()
            )
        }) ?? nil
    }

    func fetchCategories() -> [Category] {
        query(read: { db in
            // Try with icon column (available after migration v18).
            // Fall back to 3-column query if the column doesn't exist yet.
            var stmt: OpaquePointer?
            let hasIcon = sqlite3_prepare_v2(
                db, "SELECT id, COALESCE(name, ''), parent_id, icon FROM categories ORDER BY name COLLATE NOCASE;",
                -1, &stmt, nil
            ) == SQLITE_OK

            if !hasIcon {
                sqlite3_finalize(stmt)
                guard sqlite3_prepare_v2(
                    db, "SELECT id, COALESCE(name, ''), parent_id FROM categories ORDER BY name COLLATE NOCASE;",
                    -1, &stmt, nil
                ) == SQLITE_OK, let stmt else { return [] }
                defer { sqlite3_finalize(stmt) }
                var items: [Category] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let parentId = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int(stmt, 2))
                    items.append(Category(id: Int(sqlite3_column_int(stmt, 0)),
                                          name: string(from: stmt, index: 1),
                                          parentId: parentId))
                }
                return items
            }

            guard let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var items: [Category] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let parentId = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 2))
                let iconStr = string(from: stmt, index: 3)
                items.append(Category(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    parentId: parentId,
                    icon: iconStr.isEmpty ? nil : iconStr
                ))
            }
            return items
        }) ?? []
    }

    func fetchTiers() -> [Tiers] {
        query(read: { db in
            let sql = """
                SELECT id, COALESCE(name, ''), COALESCE(regex, ''),
                       category_id, linked_account_id,
                       engine_merchant_id, domain,
                       address, city, country, group_id, custom, note,
                       tier_type, contact_identifier
                FROM payees
                ORDER BY name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [Tiers] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let regex = string(from: stmt, index: 2)
                let categoryId = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
                let linkedCompteId = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
                let engineId = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : string(from: stmt, index: 5)
                let domain = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : string(from: stmt, index: 6)
                let address = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : string(from: stmt, index: 7)
                let city = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : string(from: stmt, index: 8)
                let country = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : string(from: stmt, index: 9)
                let groupId = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 10))
                let custom = sqlite3_column_int(stmt, 11) != 0
                let note = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : string(from: stmt, index: 12)
                let tierTypeRaw = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? "merchant" : string(from: stmt, index: 13)
                let tierType = TierType(rawValue: tierTypeRaw) ?? .merchant
                let contactId = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : string(from: stmt, index: 14)
                items.append(
                    Tiers(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        name: string(from: stmt, index: 1),
                        regex: regex.isEmpty ? nil : regex,
                        categoryId: categoryId,
                        linkedCompteId: linkedCompteId,
                        engineMerchantId: (engineId?.isEmpty ?? true) ? nil : engineId,
                        domain: (domain?.isEmpty ?? true) ? nil : domain,
                        address: (address?.isEmpty ?? true) ? nil : address,
                        city: (city?.isEmpty ?? true) ? nil : city,
                        country: (country?.isEmpty ?? true) ? nil : country,
                        groupId: groupId,
                        custom: custom,
                        note: (note?.isEmpty ?? true) ? nil : note,
                        tierType: tierType,
                        contactIdentifier: (contactId?.isEmpty ?? true) ? nil : contactId
                    )
                )
            }
            return items
        }) ?? []
    }

    /// Met à jour TOUS les champs éditables d'un payee.
    /// Retourne true si la ligne a été modifiée.
    @discardableResult
    func updatePayeeFull(_ p: Tiers) -> Bool {
        guard p.id > 0 else { return false }
        let sql = """
            UPDATE payees SET
                name               = ?,
                regex              = ?,
                category_id        = ?,
                linked_account_id  = ?,
                engine_merchant_id = ?,
                domain             = ?,
                address            = ?,
                city               = ?,
                country            = ?,
                group_id           = ?,
                custom             = ?,
                note               = ?,
                tier_type          = ?,
                contact_identifier = ?
            WHERE id = ?;
            """
        return writeSingle(sql: sql) { stmt in
            func bindText(_ idx: Int32, _ s: String?) {
                if let s, !s.isEmpty {
                    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            }
            func bindInt(_ idx: Int32, _ v: Int?) {
                if let v { sqlite3_bind_int(stmt, idx, Int32(v)) } else { sqlite3_bind_null(stmt, idx) }
            }

            bindText(1,  p.name)
            bindText(2,  p.regex)
            bindInt(3,   p.categoryId)
            bindInt(4,   p.linkedCompteId)
            bindText(5,  p.engineMerchantId)
            bindText(6,  p.domain)
            bindText(7,  p.address)
            bindText(8,  p.city)
            bindText(9,  p.country)
            bindInt(10,  p.groupId)
            sqlite3_bind_int(stmt, 11, p.custom ? 1 : 0)
            bindText(12, p.note)
            sqlite3_bind_text(stmt, 13, p.tierType.rawValue, -1, SQLITE_TRANSIENT)
            bindText(14, p.contactIdentifier)
            sqlite3_bind_int(stmt, 15, Int32(p.id))
        }
    }

    // MARK: - Payee groups

    func fetchPayeeGroups() -> [PayeeGroup] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(display_name, ''), engine_merchant_id, custom FROM payee_groups ORDER BY display_name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var groups: [PayeeGroup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let engineId = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                groups.append(PayeeGroup(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    displayName: string(from: stmt, index: 1),
                    engineMerchantId: (engineId?.isEmpty ?? true) ? nil : engineId,
                    custom: sqlite3_column_int(stmt, 3) != 0
                ))
            }
            return groups
        }) ?? []
    }

    func addPayeeGroup(displayName: String, engineMerchantId: String? = nil, custom: Bool = true) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let dbURL = store.databaseURL
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "INSERT INTO payee_groups (display_name, engine_merchant_id, custom) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, displayName, -1, SQLITE_TRANSIENT)
        if let engineMerchantId, !engineMerchantId.isEmpty {
            sqlite3_bind_text(stmt, 2, engineMerchantId, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, custom ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Nombre de tiers rattachés à chaque groupe (id groupe → compte).
    func countPayeesByGroup() -> [Int: Int] {
        query(read: { db in
            let sql = "SELECT group_id, COUNT(*) FROM payees WHERE group_id IS NOT NULL GROUP BY group_id;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var counts: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                counts[Int(sqlite3_column_int(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
            }
            return counts
        }) ?? [:]
    }

    @discardableResult
    func updatePayeeGroup(id: Int, displayName: String) -> Bool {
        writeSingle(sql: "UPDATE payee_groups SET display_name = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, displayName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    /// Supprime un groupe. Les tiers qui y étaient rattachés perdent
    /// simplement leur `group_id` (mis à `NULL`) — ils ne sont pas touchés.
    @discardableResult
    func deletePayeeGroup(id: Int) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var nullGroupStmt: OpaquePointer?
        var delGroupStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE payees SET group_id = NULL WHERE group_id = ?;", -1, &nullGroupStmt, nil)
        sqlite3_prepare_v2(db, "DELETE FROM payee_groups WHERE id = ?;", -1, &delGroupStmt, nil)
        defer {
            sqlite3_finalize(nullGroupStmt)
            sqlite3_finalize(delGroupStmt)
        }

        if let s = nullGroupStmt { sqlite3_bind_int(s, 1, Int32(id)); sqlite3_step(s) }
        var deleted = false
        if let s = delGroupStmt {
            sqlite3_bind_int(s, 1, Int32(id))
            deleted = sqlite3_step(s) == SQLITE_DONE
        }

        guard deleted, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    /// Fusionne `sourceId` dans `intoId` : tous les tiers du groupe source
    /// rejoignent le groupe cible, puis le groupe source est supprimé.
    @discardableResult
    func mergePayeeGroups(sourceId: Int, intoId: Int) -> Bool {
        guard sourceId != intoId, store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var reassignStmt: OpaquePointer?
        var delGroupStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE payees SET group_id = ? WHERE group_id = ?;", -1, &reassignStmt, nil)
        sqlite3_prepare_v2(db, "DELETE FROM payee_groups WHERE id = ?;", -1, &delGroupStmt, nil)
        defer {
            sqlite3_finalize(reassignStmt)
            sqlite3_finalize(delGroupStmt)
        }

        if let s = reassignStmt {
            sqlite3_bind_int(s, 1, Int32(intoId))
            sqlite3_bind_int(s, 2, Int32(sourceId))
            sqlite3_step(s)
        }
        var deleted = false
        if let s = delGroupStmt {
            sqlite3_bind_int(s, 1, Int32(sourceId))
            deleted = sqlite3_step(s) == SQLITE_DONE
        }

        guard deleted, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    /// Fusionne des tiers DOUBLONS : chaque `sourceIds` rejoint `intoId`
    /// (transactions, récurrents budget, remboursements réaffectés), puis
    /// les sources sont supprimées. Contrairement à `deleteTiers`, les
    /// transactions ne perdent PAS leur tiers — elles sont réaffectées à la
    /// cible, c'est tout l'intérêt d'une fusion plutôt qu'une suppression.
    ///
    /// Les 3 seules tables qui référencent `payees(id)` sont réaffectées
    /// (source unique : `SyncPayloadStore.foreignKeys`) : `transactions`,
    /// `recurring_patterns`, `reimbursements`.
    @discardableResult
    func mergeTiers(sourceIds: Set<Int>, intoId: Int) -> Bool {
        let sources = sourceIds.subtracting([intoId])
        guard !sources.isEmpty, store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var reassignTxStmt: OpaquePointer?
        var reassignPatternStmt: OpaquePointer?
        var dropConflictingReimbStmt: OpaquePointer?
        var reassignReimbStmt: OpaquePointer?
        var deletePayeeStmt: OpaquePointer?

        sqlite3_prepare_v2(db, "UPDATE transactions SET payee_id = ? WHERE payee_id = ?;", -1, &reassignTxStmt, nil)
        sqlite3_prepare_v2(db, "UPDATE recurring_patterns SET payee_id = ? WHERE payee_id = ?;", -1, &reassignPatternStmt, nil)
        // Un remboursement Tricount est unique par (tricount_entry_id, payee_id) :
        // si la cible a déjà une ligne pour un entry où la source en a une
        // aussi, la ligne de la cible cède la place (fusion d'identité — les
        // deux "personnes" deviennent la même) au lieu de faire échouer le
        // UPDATE qui suit avec une violation de contrainte UNIQUE.
        sqlite3_prepare_v2(db, """
            DELETE FROM reimbursements
            WHERE payee_id = ?
              AND tricount_entry_id IS NOT NULL
              AND tricount_entry_id IN (
                  SELECT tricount_entry_id FROM reimbursements
                  WHERE payee_id = ? AND tricount_entry_id IS NOT NULL
              );
            """, -1, &dropConflictingReimbStmt, nil)
        sqlite3_prepare_v2(db, "UPDATE reimbursements SET payee_id = ? WHERE payee_id = ?;", -1, &reassignReimbStmt, nil)
        sqlite3_prepare_v2(db, "DELETE FROM payees WHERE id = ?;", -1, &deletePayeeStmt, nil)
        defer {
            sqlite3_finalize(reassignTxStmt)
            sqlite3_finalize(reassignPatternStmt)
            sqlite3_finalize(dropConflictingReimbStmt)
            sqlite3_finalize(reassignReimbStmt)
            sqlite3_finalize(deletePayeeStmt)
        }

        @discardableResult
        func run2(_ stmt: OpaquePointer?, _ a: Int, _ b: Int) -> Bool {
            guard let stmt else { return false }
            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(a))
            sqlite3_bind_int(stmt, 2, Int32(b))
            return sqlite3_step(stmt) == SQLITE_DONE
        }

        var ok = true
        for sourceId in sources {
            ok = run2(reassignTxStmt, intoId, sourceId) && ok
            ok = run2(reassignPatternStmt, intoId, sourceId) && ok
            ok = run2(dropConflictingReimbStmt, intoId, sourceId) && ok
            ok = run2(reassignReimbStmt, intoId, sourceId) && ok

            guard let s = deletePayeeStmt else { ok = false; continue }
            sqlite3_reset(s)
            sqlite3_bind_int(s, 1, Int32(sourceId))
            ok = (sqlite3_step(s) == SQLITE_DONE) && ok
        }

        guard ok, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    func fetchPaymentTypes() -> [PaymentType] {
        query(read: { db in
            let sql = "SELECT id, COALESCE(name, ''), COALESCE(regex, '') FROM payment_types ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var items: [PaymentType] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let regex = string(from: stmt, index: 2)
                items.append(
                    PaymentType(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        name: string(from: stmt, index: 1),
                        regex: regex.isEmpty ? nil : regex
                    )
                )
            }
            return items
        }) ?? []
    }

    @discardableResult
    func insertTransactions(_ transactions: [PendingTransaction]) -> Int {
        insertTransactionsDetailed(transactions).insertedCount
    }

    func insertTransactionsDetailed(_ transactions: [PendingTransaction]) -> TransactionImportResult {
        guard !transactions.isEmpty else { return TransactionImportResult(insertedCount: 0, failures: []) }

        func makeFailure(_ tx: PendingTransaction, reason: String) -> TransactionImportFailure {
            TransactionImportFailure(
                sourceRowNumber: tx.sourceRowNumber,
                information: tx.information,
                amount: tx.amount,
                date: tx.date,
                reason: reason
            )
        }

        guard store.databaseExists else {
            return TransactionImportResult(
                insertedCount: 0,
                failures: transactions.map { makeFailure($0, reason: "Aucune base de données configurée.") }
            )
        }

        var db: OpaquePointer?
        let dbURL = store.databaseURL
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let reason: String
            if let db {
                reason = String(cString: sqlite3_errmsg(db))
            } else {
                reason = "Impossible d'ouvrir la base de données."
            }
            sqlite3_close(db)
            return TransactionImportResult(
                insertedCount: 0,
                failures: transactions.map { makeFailure($0, reason: reason) }
            )
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        // Auto-fill category_id from tiers.category_id via subquery
        // Le libellé brut du CSV va dans libelle_brut ; information reste libre pour l'utilisateur.
        let sql = """
        INSERT INTO transactions (account_id, payee_id, payment_type_id, category_id, libelle_brut, amount, tx_date)
        VALUES (?, ?, ?, (SELECT category_id FROM payees WHERE id = ?), ?, ?, ?)
        """

        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(db))
            return TransactionImportResult(
                insertedCount: 0,
                failures: transactions.map { makeFailure($0, reason: reason) }
            )
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let reason = String(cString: sqlite3_errmsg(db))
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return TransactionImportResult(
                insertedCount: 0,
                failures: transactions.map { makeFailure($0, reason: reason) }
            )
        }
        defer { sqlite3_finalize(stmt) }

        var inserted = 0
        var failures: [TransactionImportFailure] = []
        var insertedIds: [Int: Int] = [:]

        for tx in transactions {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            sqlite3_bind_int(stmt, 1, Int32(tx.accountId))
            if let tiersId = tx.tiersId {
                sqlite3_bind_int(stmt, 2, Int32(tiersId))
                sqlite3_bind_int(stmt, 4, Int32(tiersId))
            } else {
                sqlite3_bind_null(stmt, 2)
                sqlite3_bind_null(stmt, 4)
            }
            if let mdpId = tx.mdpId {
                sqlite3_bind_int(stmt, 3, Int32(mdpId))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 5, tx.information, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, tx.amount)
            sqlite3_bind_text(stmt, 7, formatter.string(from: tx.date), -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_DONE {
                inserted += 1
                insertedIds[tx.sourceRowNumber] = Int(sqlite3_last_insert_rowid(db))
            } else {
                let dbReason = String(cString: sqlite3_errmsg(db))
                let reason = dbReason.isEmpty ? "Erreur SQLite inconnue." : dbReason
                failures.append(makeFailure(tx, reason: reason))
            }
        }

        if failures.isEmpty {
            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                let reason = String(cString: sqlite3_errmsg(db))
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return TransactionImportResult(
                    insertedCount: 0,
                    failures: transactions.map { makeFailure($0, reason: "Commit échoué: \(reason)") }
                )
            }
            return TransactionImportResult(insertedCount: inserted, failures: [], insertedIds: insertedIds)
        }

        _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return TransactionImportResult(insertedCount: 0, failures: failures)
    }

    // MARK: - Transaction CRUD

    /// Retourne l'id de la transaction créée (nil si échec). Le remboursement
    /// éventuel (`remboursementTiersId`) n'est plus une colonne de cette table
    /// depuis v44 — l'appelant doit enchaîner avec
    /// `ReimbursementRepository.setReimbursement(transactionId:payeeId:)` une
    /// fois l'id obtenu.
    @discardableResult
    func addTransaction(accountId: Int, tiersId: Int?, categoryId: Int?, paymentTypeId: Int?,
                        information: String, amount: Double, date: Date) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO transactions (account_id, payee_id, category_id, payment_type_id, information, amount, tx_date)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(accountId))
        if let v = tiersId { sqlite3_bind_int(stmt, 2, Int32(v)) } else { sqlite3_bind_null(stmt, 2) }
        if let v = categoryId { sqlite3_bind_int(stmt, 3, Int32(v)) } else { sqlite3_bind_null(stmt, 3) }
        if let v = paymentTypeId { sqlite3_bind_int(stmt, 4, Int32(v)) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, information, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, amount)
        sqlite3_bind_text(stmt, 7, fmt.string(from: date), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    @discardableResult
    func deleteTransaction(id: Int) -> Bool {
        store.write { db in
            Self.detacherEnfants(db, transactionId: id)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM transactions WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    /// Supprime tout ce qui pend à une transaction, avant de la supprimer.
    ///
    /// Le schéma déclare pourtant `ON DELETE CASCADE` sur les trois premières
    /// tables. SQLite ignore les clés étrangères tant que
    /// `PRAGMA foreign_keys = ON` n'a pas été posé, et ce réglage vaut PAR
    /// CONNEXION : une déclaration de schéma n'est donc jamais une garantie.
    ///
    /// ⚠️ Poser ce pragma ici serait pire que le défaut qu'il corrige.
    /// `tricount_entries.linked_transaction_id` référence `transactions(id)`
    /// SANS action déclarée, ce qui vaut `NO ACTION` : l'application des clés
    /// étrangères ferait alors REFUSER la suppression de toute transaction
    /// rattachée à une dépense Tricount. La cascade explicite obtient le
    /// nettoyage sans importer ce blocage — c'est le même choix, pour la même
    /// raison, que celui déjà fait côté investissements.
    ///
    /// Sans ce nettoyage, les lignes filles survivent en pointant vers une
    /// transaction disparue. Elles ne sont pas seulement du poids mort : elles
    /// portent un `uuid` et un `updated_at`, donc elles partent en
    /// synchronisation et arrivent sur les autres appareils dans le même état.
    private static func detacherEnfants(_ db: OpaquePointer, transactionId: Int) {
        let instructions = [
            "DELETE FROM transaction_tags WHERE transaction_id = ?;",
            "DELETE FROM reimbursements WHERE transaction_id = ?;",
            "DELETE FROM transaction_metadata_values WHERE transaction_id = ?;",
            // Ces deux-là ne sont pas supprimées mais détachées : la prévision
            // budgétaire et la dépense Tricount existent indépendamment de la
            // transaction à laquelle on les avait rapprochées.
            "UPDATE budget_previsions SET actual_transaction_id = NULL WHERE actual_transaction_id = ?;",
            "UPDATE tricount_entries SET linked_transaction_id = NULL WHERE linked_transaction_id = ?;"
        ]
        for sql in instructions {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int(stmt, 1, Int32(transactionId))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Supprime plusieurs transactions et renvoie le nombre de lignes
    /// RÉELLEMENT supprimées.
    ///
    /// La nuance compte : SQLite répond `SQLITE_DONE` à un `DELETE` qui ne
    /// touche aucune ligne — l'instruction s'est bien exécutée, elle n'a rien
    /// trouvé. Compter les instructions réussies, comme le faisait la version
    /// précédente, surestimait donc le total dès qu'un identifiant était périmé,
    /// ce qui arrive dès que deux appareils synchronisés suppriment en parallèle.
    /// `sqlite3_changes` donne le nombre de lignes effectivement touchées.
    ///
    /// Une seule connexion et un seul statement réutilisé, au lieu d'un cycle
    /// ouverture/fermeture par identifiant.
    func deleteTransactions(ids: Set<Int>) -> Int {
        guard !ids.isEmpty else { return 0 }
        return store.write { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM transactions WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }

            var supprimees = 0
            for id in ids {
                Self.detacherEnfants(db, transactionId: id)
                sqlite3_reset(stmt)
                sqlite3_bind_int(stmt, 1, Int32(id))
                if sqlite3_step(stmt) == SQLITE_DONE {
                    supprimees += Int(sqlite3_changes(db))
                }
            }
            return supprimees
        } ?? 0
    }

    /// Remboursement géré séparément par ReimbursementRepository.setReimbursement
    /// depuis v44 — l'appelant enchaîne après ce updateTransaction.
    @discardableResult
    func updateTransaction(_ draft: TransactionEditDraft) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: draft.date)
        return writeSingle(sql: """
            UPDATE transactions
            SET payee_id = ?, category_id = ?, payment_type_id = ?, information = ?, amount = ?, tx_date = ?
            WHERE id = ?
            """) { stmt in
            if let v = draft.tiersId { sqlite3_bind_int(stmt, 1, Int32(v)) } else { sqlite3_bind_null(stmt, 1) }
            if let v = draft.categoryId { sqlite3_bind_int(stmt, 2, Int32(v)) } else { sqlite3_bind_null(stmt, 2) }
            if let v = draft.paymentTypeId { sqlite3_bind_int(stmt, 3, Int32(v)) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_text(stmt, 4, draft.information, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, draft.amount)
            sqlite3_bind_text(stmt, 6, dateStr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, Int32(draft.id))
        }
    }

    /// Insère un nouveau tiers et retourne son ID généré.
    func addTiersAndGetId(name: String, regex: String, categoryId: Int? = nil) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let dbURL = store.databaseURL
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "INSERT INTO payees (name, regex, category_id) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        if let cid = categoryId { sqlite3_bind_int(stmt, 3, Int32(cid)) } else { sqlite3_bind_null(stmt, 3) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    // MARK: - Reference Data CRUD

    @discardableResult
    func updateAccount(id: Int, name: String, type: String = "COURANT", excludedFromAggregates: Bool = false) -> Bool {
        writeSingle(sql: "UPDATE accounts SET name = ?, type = ?, excluded_from_aggregates = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, excludedFromAggregates ? 1 : 0)
            sqlite3_bind_int(stmt, 4, Int32(id))
        }
    }

    @discardableResult
    func addAccount(name: String, type: String = "COURANT", excludedFromAggregates: Bool = false) -> Bool {
        writeSingle(sql: "INSERT INTO accounts (name, type, excluded_from_aggregates) VALUES (?, ?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, excludedFromAggregates ? 1 : 0)
        }
    }

    @discardableResult
    func updateCategory(id: Int, name: String, parentId: Int? = nil, icon: String? = nil) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE categories SET name = ?, parent_id = ?, icon = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            if let pid = parentId { sqlite3_bind_int(stmt, 2, Int32(pid)) } else { sqlite3_bind_null(stmt, 2) }
            if let ic = icon { sqlite3_bind_text(stmt, 3, ic, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int(stmt, 4, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        }
        // Fallback : colonne icon absente (DB pré-v18), migration non encore appliquée
        sqlite3_finalize(stmt)
        guard sqlite3_prepare_v2(db, "UPDATE categories SET name = ?, parent_id = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        if let pid = parentId { sqlite3_bind_int(stmt, 2, Int32(pid)) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_int(stmt, 3, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func addCategory(name: String, parentId: Int? = nil, icon: String? = nil) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO categories (name, parent_id, icon) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        if let pid = parentId { sqlite3_bind_int(stmt, 2, Int32(pid)) } else { sqlite3_bind_null(stmt, 2) }
        if let ic = icon { sqlite3_bind_text(stmt, 3, ic, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Déplace une catégorie dans l'arbre (change son parent, nil = racine).
    @discardableResult
    func moveCategory(id: Int, toParentId: Int?) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE categories SET parent_id = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        if let pid = toParentId { sqlite3_bind_int(stmt, 1, Int32(pid)) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int(stmt, 2, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Supprime une catégorie (et éventuellement ses sous-catégories) en désassignant
    /// tout ce qui la référence (transactions, récurrents, enveloppes budget passent à NULL).
    /// Les transactions ne sont jamais perdues : elles deviennent "non catégorisées".
    /// Retourne true si la suppression a eu lieu.
    @discardableResult
    func deleteCategory(id: Int, includingChildren childIds: [Int] = []) -> Bool {
        let allIds = [id] + childIds
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        sqlite3_exec(db, "PRAGMA foreign_keys = OFF;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        let placeholders = allIds.map { _ in "?" }.joined(separator: ",")
        // Désassigner les références connues (les tables budget/enrichment tolèrent NULL).
        let nullStatements = [
            "UPDATE transactions SET category_id = NULL WHERE category_id IN (\(placeholders));",
            "UPDATE recurring_patterns SET category_id = NULL WHERE category_id IN (\(placeholders));",
            "UPDATE budget_envelopes SET category_id = NULL WHERE category_id IN (\(placeholders));",
            "UPDATE payees SET category_id = NULL WHERE category_id IN (\(placeholders));",
        ]
        for sql in nullStatements {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s {
                for (i, cid) in allIds.enumerated() { sqlite3_bind_int(s, Int32(i + 1), Int32(cid)) }
                sqlite3_step(s)
            }
            sqlite3_finalize(s)
        }

        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM categories WHERE id IN (\(placeholders))", -1, &delStmt, nil) == SQLITE_OK, let delStmt else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil); return false
        }
        defer { sqlite3_finalize(delStmt) }
        for (i, cid) in allIds.enumerated() { sqlite3_bind_int(delStmt, Int32(i + 1), Int32(cid)) }
        let ok = sqlite3_step(delStmt) == SQLITE_DONE
        sqlite3_exec(db, ok ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return ok
    }

    // MARK: - Comptage transactions par entité (pour l'écran Données)

    /// Nombre de transactions par valeur d'une colonne FK de `transactions`.
    /// `column` est une constante interne (jamais une saisie utilisateur).
    private func transactionCounts(column: String) -> [Int: Int] {
        query(read: { db in
            var stmt: OpaquePointer?
            let sql = "SELECT \(column), COUNT(*) FROM transactions WHERE \(column) IS NOT NULL GROUP BY \(column);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var map: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                map[Int(sqlite3_column_int(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
            }
            return map
        }) ?? [:]
    }

    func countTransactionsByCategory() -> [Int: Int]    { transactionCounts(column: "category_id") }
    func countTransactionsByPayee() -> [Int: Int]       { transactionCounts(column: "payee_id") }
    func countTransactionsByPaymentType() -> [Int: Int] { transactionCounts(column: "payment_type_id") }
    func countTransactionsByAccount() -> [Int: Int]     { transactionCounts(column: "account_id") }

    /// Nombre de transactions taguées par tag (via la table de liaison).
    func countTransactionsByTag() -> [Int: Int] {
        query(read: { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT tag_id, COUNT(*) FROM transaction_tags GROUP BY tag_id;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var map: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                map[Int(sqlite3_column_int(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
            }
            return map
        }) ?? [:]
    }

    // MARK: - Suppression moyen de paiement / compte / tag

    /// Supprime un moyen de paiement. Les transactions concernées passent à NULL.
    @discardableResult
    func deletePaymentType(id: Int) -> Bool {
        deleteAndUnassign(
            table: "payment_types",
            id: id,
            unassign: ["UPDATE transactions SET payment_type_id = NULL WHERE payment_type_id = ?;"]
        )
    }

    /// Supprime un tag et ses liaisons.
    ///
    /// Un tag se pose aussi bien sur une transaction que sur une dépense
    /// Tricount : les DEUX tables de liaison doivent être nettoyées, pas
    /// seulement celle du module depuis lequel la suppression est déclenchée.
    @discardableResult
    func deleteTag(id: Int) -> Bool {
        deleteAndUnassign(
            table: "tags",
            id: id,
            unassign: [
                "DELETE FROM transaction_tags WHERE tag_id = ?;",
                "DELETE FROM tricount_entry_tags WHERE tag_id = ?;"
            ]
        )
    }

    /// Supprime plusieurs tags en une fois (sélection multiple, Données →
    /// Tags). Boucle sur `deleteTag` — le nombre de tags sélectionnés à la
    /// fois reste faible (quelques dizaines au plus), pas besoin de la même
    /// transaction dédiée que `deleteTiers`. Retourne le nombre effectivement
    /// supprimé.
    @discardableResult
    func deleteTags(ids: Set<Int>) -> Int {
        ids.reduce(0) { count, id in deleteTag(id: id) ? count + 1 : count }
    }

    /// Supprime un compte SEULEMENT s'il ne porte aucune transaction (garde-fou :
    /// un compte est structurant, on ne veut pas orpheliner des écritures).
    /// Retourne false si le compte est encore utilisé.
    @discardableResult
    func deleteAccount(id: Int) -> Bool {
        guard countTransactionsByAccount()[id] == nil else { return false }
        return deleteAndUnassign(
            table: "accounts",
            id: id,
            unassign: ["UPDATE payees SET linked_account_id = NULL WHERE linked_account_id = ?;"]
        )
    }

    /// Helper commun : exécute les UPDATE/DELETE de désassignation puis DELETE la row.
    private func deleteAndUnassign(table: String, id: Int, unassign: [String]) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        sqlite3_exec(db, "PRAGMA foreign_keys = OFF;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        for sql in unassign {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s {
                sqlite3_bind_int(s, 1, Int32(id)); sqlite3_step(s)
            }
            sqlite3_finalize(s)
        }

        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK, let delStmt else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil); return false
        }
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_int(delStmt, 1, Int32(id))
        let ok = sqlite3_step(delStmt) == SQLITE_DONE
        sqlite3_exec(db, ok ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return ok
    }

    // MARK: - Tags

    func fetchAllTags() -> [Tag] {
        query(read: { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var items: [Tag] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let color = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                items.append(Tag(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1), color: color?.isEmpty == true ? nil : color))
            }
            return items
        }) ?? []
    }

    func fetchTags(forTransaction txId: Int) -> [Tag] {
        query(read: { db in
            let sql = """
                SELECT t.id, t.name, t.color FROM tags t
                JOIN transaction_tags tt ON tt.tag_id = t.id
                WHERE tt.transaction_id = ?
                ORDER BY t.name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(txId))
            var items: [Tag] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let color = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                items.append(Tag(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1), color: color?.isEmpty == true ? nil : color))
            }
            return items
        }) ?? []
    }

    /// Met à jour la couleur d'un tag (hex sans #, nil = couleur par défaut).
    @discardableResult
    func updateTagColor(id: Int, colorHex: String?) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tags SET color = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        if let hex = colorHex { sqlite3_bind_text(stmt, 1, hex, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int(stmt, 2, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Crée le tag s'il n'existe pas (insensible à la casse), retourne son id.
    func findOrCreateTag(name: String) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO tags (name) VALUES (?);", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_prepare_v2(db, "SELECT id FROM tags WHERE name = ? COLLATE NOCASE;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        var tagId: Int? = nil
        if sqlite3_step(stmt) == SQLITE_ROW { tagId = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        return tagId
    }

    // MARK: - Tags Tricount

    func fetchTags(forTricountEntry entryId: Int) -> [Tag] {
        query(read: { db in
            let sql = """
                SELECT t.id, t.name, t.color FROM tags t
                JOIN tricount_entry_tags tet ON tet.tag_id = t.id
                WHERE tet.entry_id = ?
                ORDER BY t.name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(entryId))
            var items: [Tag] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let color = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                items.append(Tag(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1), color: color?.isEmpty == true ? nil : color))
            }
            return items
        }) ?? []
    }

    @discardableResult
    func setTags(_ tagIds: [Int], forTricountEntry entryId: Int) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM tricount_entry_tags WHERE entry_id = ?;", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(entryId))
        sqlite3_step(stmt); sqlite3_finalize(stmt)
        for tagId in tagIds {
            sqlite3_prepare_v2(db, "INSERT INTO tricount_entry_tags (entry_id, tag_id) VALUES (?, ?);", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(entryId))
            sqlite3_bind_int(stmt, 2, Int32(tagId))
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
        return sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Résumé par tag

    func fetchTagExpenseSummary() -> [TagExpenseSummary] {
        query(read: { db in
            // Conversion EUR pour la sous-requête Tricount :
            //   1. Déjà en EUR → ts.amount directement
            //   2. local_currency = 'EUR' et local_total dispo → ratio proportionnel
            //   3. Fallback → ts.amount brut (pas de conversion connue)
            // Note : total et local_total sont stockés négatifs pour les dépenses.
            let sql = """
                SELECT
                    t.id, t.name, t.color,
                    COALESCE(tx_s.total, 0.0),
                    COALESCE(tc_s.total, 0.0)
                FROM tags t
                LEFT JOIN (
                    SELECT tt.tag_id, SUM(tr.amount) AS total
                    FROM transaction_tags tt
                    JOIN transactions tr ON tr.id = tt.transaction_id
                    LEFT JOIN accounts a ON a.id = tr.account_id
                    WHERE (a.excluded_from_aggregates IS NULL OR a.excluded_from_aggregates = 0)
                    GROUP BY tt.tag_id
                ) tx_s ON tx_s.tag_id = t.id
                LEFT JOIN (
                    SELECT tet.tag_id,
                        SUM(
                            (CASE WHEN UPPER(COALESCE(te.type_transaction,'NORMAL')) = 'NORMAL' THEN -1 ELSE 1 END)
                            *
                            (CASE
                                WHEN te.currency = 'EUR' OR te.currency = ''
                                    THEN ABS(ts.amount)
                                WHEN te.local_currency = 'EUR'
                                     AND te.local_total IS NOT NULL
                                     AND te.total != 0
                                    THEN ABS(ts.amount) * ABS(te.local_total / te.total)
                                WHEN cr.rate IS NOT NULL
                                    THEN ABS(ts.amount) * cr.rate
                                ELSE ABS(ts.amount)
                            END)
                        ) AS total
                    FROM tricount_entry_tags tet
                    JOIN tricount_entries te ON te.id = tet.entry_id
                    JOIN tricount_groups tg ON tg.id = te.group_id
                    JOIN tricount_shares ts ON ts.entry_id = te.id
                        AND ts.member_name = tg.my_name
                    LEFT JOIN currency_rates cr
                        ON cr.from_currency = te.currency
                       AND cr.to_currency   = 'EUR'
                       AND cr.date          = te.date
                    GROUP BY tet.tag_id
                ) tc_s ON tc_s.tag_id = t.id
                WHERE tx_s.tag_id IS NOT NULL OR tc_s.tag_id IS NOT NULL
                ORDER BY t.name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var items: [TagExpenseSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let color = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                let tag = Tag(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1), color: color?.isEmpty == true ? nil : color)
                items.append(TagExpenseSummary(
                    tag: tag,
                    transactionTotal: sqlite3_column_double(stmt, 3),
                    tricountTotal: sqlite3_column_double(stmt, 4)
                ))
            }
            return items
        }) ?? []
    }

    func fetchTransactions(forTagId tagId: Int) -> [FinanceTransaction] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return query(read: { db in
            let sql = """
                SELECT t.id, t.account_id,
                    COALESCE(ti.name,''), COALESCE(c.name,''), COALESCE(m.name,''),
                    COALESCE(t.information,''), t.amount, COALESCE(t.tx_date,''),
                    t.payee_id, t.category_id, t.payment_type_id, rb.payee_id,
                    COALESCE(tr.name,'')
                FROM transactions t
                JOIN transaction_tags tt ON tt.transaction_id = t.id
                LEFT JOIN payees ti ON ti.id = t.payee_id
                LEFT JOIN categories c ON c.id = t.category_id
                LEFT JOIN payment_types m ON m.id = t.payment_type_id
                LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
                LEFT JOIN payees tr ON tr.id = rb.payee_id
                WHERE tt.tag_id = ?
                ORDER BY t.tx_date DESC, t.id DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(tagId))
            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }
            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FinanceTransaction(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    accountId: Int(sqlite3_column_int(stmt, 1)),
                    tiersId: optInt(8), categoryId: optInt(9), paymentTypeId: optInt(10),
                    remboursementTiersId: optInt(11),
                    tiersName: string(from: stmt, index: 2),
                    categoryName: string(from: stmt, index: 3),
                    paymentTypeName: string(from: stmt, index: 4),
                    remboursementTiersName: string(from: stmt, index: 12),
                    information: string(from: stmt, index: 5),
                    libelleBrut: nil,
                    amount: sqlite3_column_double(stmt, 6),
                    date: formatter.date(from: string(from: stmt, index: 7)) ?? Date()
                ))
            }
            return results
        }) ?? []
    }

    func fetchTricountEntries(forTagId tagId: Int) -> [TaggedTricountEntry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return query(read: { db in
            // Colonnes 0-6 : données de base
            // Colonne 7   : eurShare (NULL si pas de taux disponible)
            // Colonne 8   : type_transaction
            let sql = """
                SELECT te.id, COALESCE(te.description,''),
                    ABS(COALESCE(ts.amount, te.total)),
                    te.currency,
                    COALESCE(te.date,''), COALESCE(te.who_paid,''), COALESCE(tg.title,''),
                    CASE
                        WHEN te.currency = 'EUR' OR te.currency = ''
                            THEN ABS(COALESCE(ts.amount, te.total))
                        WHEN te.local_currency = 'EUR'
                             AND te.local_total IS NOT NULL
                             AND te.total != 0
                            THEN ABS(COALESCE(ts.amount, te.total)) * ABS(te.local_total / te.total)
                        WHEN cr.rate IS NOT NULL
                            THEN ABS(COALESCE(ts.amount, te.total)) * cr.rate
                        ELSE NULL
                    END AS eur_share,
                    COALESCE(te.type_transaction, 'NORMAL')
                FROM tricount_entries te
                JOIN tricount_entry_tags tet ON tet.entry_id = te.id
                JOIN tricount_groups tg ON tg.id = te.group_id
                LEFT JOIN tricount_shares ts ON ts.entry_id = te.id
                    AND ts.member_name = tg.my_name
                LEFT JOIN currency_rates cr
                    ON cr.from_currency = te.currency
                   AND cr.to_currency   = 'EUR'
                   AND cr.date          = te.date
                WHERE tet.tag_id = ?
                ORDER BY te.date DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(tagId))
            var results: [TaggedTricountEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let eurShare: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(stmt, 7)
                results.append(TaggedTricountEntry(
                    id:              Int(sqlite3_column_int(stmt, 0)),
                    description:     string(from: stmt, index: 1),
                    myShare:         sqlite3_column_double(stmt, 2),
                    currency:        string(from: stmt, index: 3),
                    eurShare:        eurShare,
                    date:            formatter.date(from: string(from: stmt, index: 4)) ?? Date(),
                    whoPaid:         string(from: stmt, index: 5),
                    groupTitle:      string(from: stmt, index: 6),
                    typeTransaction: string(from: stmt, index: 8)
                ))
            }
            return results
        }) ?? []
    }

    /// Retourne les IDs de transactions ayant au moins un des tags donnés.
    func fetchTransactionIds(havingAnyTagIds tagIds: Set<Int>) -> Set<Int> {
        guard !tagIds.isEmpty else { return [] }
        return query(read: { db in
            let placeholders = tagIds.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT DISTINCT transaction_id FROM transaction_tags WHERE tag_id IN (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return Set<Int>() }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in tagIds.enumerated() {
                sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
            }
            var ids = Set<Int>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.insert(Int(sqlite3_column_int(stmt, 0)))
            }
            return ids
        }) ?? []
    }

    /// Remplace tous les tags d'une transaction (opération atomique).
    @discardableResult
    func setTags(_ tagIds: [Int], forTransaction txId: Int) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM transaction_tags WHERE transaction_id = ?;", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(txId))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        for tagId in tagIds {
            sqlite3_prepare_v2(db, "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (?, ?);", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(txId))
            sqlite3_bind_int(stmt, 2, Int32(tagId))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func updateTiers(id: Int, name: String, regex: String, categoryId: Int? = nil, linkedCompteId: Int? = nil) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE payees SET name = ?, regex = ?, category_id = ?, linked_account_id = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        if let cid = categoryId { sqlite3_bind_int(stmt, 3, Int32(cid)) } else { sqlite3_bind_null(stmt, 3) }
        if let lcid = linkedCompteId { sqlite3_bind_int(stmt, 4, Int32(lcid)) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_int(stmt, 5, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func addTiers(name: String, regex: String, categoryId: Int? = nil, linkedCompteId: Int? = nil) -> Bool {
        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO payees (name, regex, category_id, linked_account_id) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        if let cid = categoryId { sqlite3_bind_int(stmt, 3, Int32(cid)) } else { sqlite3_bind_null(stmt, 3) }
        if let lcid = linkedCompteId { sqlite3_bind_int(stmt, 4, Int32(lcid)) } else { sqlite3_bind_null(stmt, 4) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func updatePaymentType(id: Int, name: String, regex: String) -> Bool {
        writeSingle(sql: "UPDATE payment_types SET name = ?, regex = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(id))
        }
    }

    @discardableResult
    func addPaymentType(name: String, regex: String) -> Bool {
        writeSingle(sql: "INSERT INTO payment_types (name, regex) VALUES (?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, regex, -1, SQLITE_TRANSIENT)
        }
    }

    // MARK: - Suppression tiers (multi)

    /// Supprime les tiers et délie les transactions/remboursements associés (SET NULL).
    /// Retourne le nombre de tiers effectivement supprimés.
    @discardableResult
    func deleteTiers(ids: Set<Int>) -> Int {
        guard !ids.isEmpty, store.databaseExists else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        sqlite3_exec(db, "PRAGMA foreign_keys = OFF;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var nullTiersStmt: OpaquePointer?
        var delRembStmt:   OpaquePointer?
        var delTiersStmt:  OpaquePointer?

        sqlite3_prepare_v2(db, "UPDATE transactions SET payee_id = NULL WHERE payee_id = ?;",      -1, &nullTiersStmt, nil)
        // Couvre les 2 origines (transaction simple + Tricount) en un seul DELETE — v44
        sqlite3_prepare_v2(db, "DELETE FROM reimbursements WHERE payee_id = ?;",                    -1, &delRembStmt,  nil)
        sqlite3_prepare_v2(db, "DELETE FROM payees WHERE id = ?;",                                  -1, &delTiersStmt, nil)
        defer {
            sqlite3_finalize(nullTiersStmt)
            sqlite3_finalize(delRembStmt)
            sqlite3_finalize(delTiersStmt)
        }

        var deleted = 0
        for id in ids {
            let i32 = Int32(id)
            func run(_ s: OpaquePointer?) { if let s { sqlite3_reset(s); sqlite3_bind_int(s, 1, i32); sqlite3_step(s) } }
            run(nullTiersStmt)
            run(delRembStmt)
            if let s = delTiersStmt { sqlite3_reset(s); sqlite3_bind_int(s, 1, i32); if sqlite3_step(s) == SQLITE_DONE { deleted += 1 } }
        }

        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return 0
        }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return deleted
    }

    // MARK: - Bulk import tiers

    func bulkInsertTiers(_ rows: [(name: String, regex: String, categoryId: Int?)]) -> TiersBulkImportResult {
        guard !rows.isEmpty, store.databaseExists else {
            return TiersBulkImportResult(insertedCount: 0, skippedCount: rows.count)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return TiersBulkImportResult(insertedCount: 0, skippedCount: rows.count)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Charger les noms existants (minuscules) pour déduplication
        var existingNames = Set<String>()
        var nameStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT LOWER(COALESCE(name,'')) FROM payees;", -1, &nameStmt, nil) == SQLITE_OK, let nameStmt {
            defer { sqlite3_finalize(nameStmt) }
            while sqlite3_step(nameStmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(nameStmt, 0) {
                    existingNames.insert(String(cString: cstr))
                }
            }
        }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO payees (name, regex, category_id) VALUES (?, ?, ?)", -1, &insertStmt, nil) == SQLITE_OK, let insertStmt else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return TiersBulkImportResult(insertedCount: 0, skippedCount: rows.count)
        }
        defer { sqlite3_finalize(insertStmt) }

        var inserted = 0, skipped = 0
        for row in rows {
            guard !existingNames.contains(row.name.lowercased()) else { skipped += 1; continue }
            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)
            sqlite3_bind_text(insertStmt, 1, row.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStmt, 2, row.regex, -1, SQLITE_TRANSIENT)
            if let cid = row.categoryId { sqlite3_bind_int(insertStmt, 3, Int32(cid)) } else { sqlite3_bind_null(insertStmt, 3) }
            if sqlite3_step(insertStmt) == SQLITE_DONE {
                inserted += 1
                existingNames.insert(row.name.lowercased()) // évite doublons intra-batch
            } else {
                skipped += 1
            }
        }

        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return TiersBulkImportResult(insertedCount: 0, skippedCount: rows.count)
        }
        return TiersBulkImportResult(insertedCount: inserted, skippedCount: skipped)
    }

    // MARK: - Mise à jour rapide catégorie

    func updateTransactionsCategory(ids: Set<Int>, categoryId: Int?) -> Int {
        ids.reduce(0) { count, id in
            updateTransactionCategory(id: id, categoryId: categoryId) ? count + 1 : count
        }
    }

    @discardableResult
    func updateTransactionCategory(id: Int, categoryId: Int?) -> Bool {
        writeSingle(sql: "UPDATE transactions SET category_id = ? WHERE id = ?") { stmt in
            if let cid = categoryId { sqlite3_bind_int(stmt, 1, Int32(cid)) }
            else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    // MARK: - Données pour graphiques

    /// accountId = nil → tous les comptes confondus.
    func fetchMonthlyTotals(accountId: Int? = nil, from: Date, to: Date) -> [MonthlyTotals] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to)); let toRaw = fmt.string(from: max(from, to))
        return query(read: { db in
            let accountClause = accountId != nil ? "AND t.account_id = ?" : ""
            // Un compte explicite = l'utilisateur consulte CE compte : jamais exclu.
            // "Tous comptes" (accountId == nil) exclut les comptes marqués "autres".
            let excludedAccountsJoin = accountId == nil ? Self.excludedAccountsJoin : ""
            let excludedAccountsClause = accountId == nil ? "AND \(Self.excludedAccountsClause)" : ""
            let sql = """
            SELECT strftime('%Y-%m', t.tx_date) AS mois,
                   SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END),
                   SUM(CASE WHEN t.amount < 0 THEN t.amount ELSE 0 END)
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            \(excludedAccountsJoin)
            WHERE t.tx_date >= ? AND t.tx_date <= ?
              \(accountClause)
              AND (t.payee_id IS NULL OR ti.linked_account_id IS NULL)
              \(excludedAccountsClause)
            GROUP BY mois ORDER BY mois ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, toRaw, -1, SQLITE_TRANSIENT)
            if let accountId { sqlite3_bind_int(stmt, 3, Int32(accountId)) }
            var results: [MonthlyTotals] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(MonthlyTotals(
                    month: string(from: stmt, index: 0),
                    income: sqlite3_column_double(stmt, 1),
                    expense: sqlite3_column_double(stmt, 2)
                ))
            }
            return results
        }) ?? []
    }

    /// accountId = nil → tous les comptes confondus.
    func fetchCategoryTotals(accountId: Int? = nil, from: Date, to: Date) -> [CategoryTotal] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to)); let toRaw = fmt.string(from: max(from, to))
        return query(read: { db in
            let accountClause = accountId != nil ? "AND t.account_id = ?" : ""
            let excludedAccountsJoin = accountId == nil ? Self.excludedAccountsJoin : ""
            let excludedAccountsClause = accountId == nil ? "AND \(Self.excludedAccountsClause)" : ""
            let sql = """
            SELECT
                COALESCE(c.name, 'Non catégorisé') as name,
                SUM(t.amount) as total,
                p.name as parent_name
            FROM transactions t
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN categories p ON p.id = c.parent_id
            LEFT JOIN payees ti ON ti.id = t.payee_id
            \(excludedAccountsJoin)
            WHERE t.tx_date >= ? AND t.tx_date <= ?
              \(accountClause)
              AND (t.payee_id IS NULL OR ti.linked_account_id IS NULL)
              \(excludedAccountsClause)
            GROUP BY t.category_id
            ORDER BY ABS(SUM(t.amount)) DESC LIMIT 20;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, toRaw, -1, SQLITE_TRANSIENT)
            if let accountId { sqlite3_bind_int(stmt, 3, Int32(accountId)) }
            var results: [CategoryTotal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let parentName: String? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                    ? string(from: stmt, index: 2) : nil
                results.append(CategoryTotal(
                    category: string(from: stmt, index: 0),
                    parentCategory: parentName,
                    total: sqlite3_column_double(stmt, 1)
                ))
            }
            return results
        }) ?? []
    }

    // MARK: - Fetch toutes transactions (picker)

    func fetchAllTransactions(limit: Int = 300) -> [FinanceTransaction] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return query(read: { db in
            let sql = """
            SELECT
                t.id, t.account_id,
                COALESCE(ti.name, ''), COALESCE(c.name, ''), COALESCE(m.name, ''),
                COALESCE(t.information, ''), t.amount, COALESCE(t.tx_date, ''),
                t.payee_id, t.category_id, t.payment_type_id, rb.payee_id,
                COALESCE(tr.name, '')
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN payment_types m ON m.id = t.payment_type_id
            LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
            LEFT JOIN payees tr ON tr.id = rb.payee_id
            ORDER BY t.tx_date DESC, t.id DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }
            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FinanceTransaction(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    accountId: Int(sqlite3_column_int(stmt, 1)),
                    tiersId: optInt(8), categoryId: optInt(9), paymentTypeId: optInt(10),
                    remboursementTiersId: optInt(11),
                    tiersName: string(from: stmt, index: 2),
                    categoryName: string(from: stmt, index: 3),
                    paymentTypeName: string(from: stmt, index: 4),
                    remboursementTiersName: string(from: stmt, index: 12),
                    information: string(from: stmt, index: 5),
                    libelleBrut: nil,
                    amount: sqlite3_column_double(stmt, 6),
                    date: formatter.date(from: string(from: stmt, index: 7)) ?? Date()
                ))
            }
            return results
        }) ?? []
    }

    // MARK: - Tricount Links

    /// Retourne l'ensemble des transaction IDs liées à une entrée Tricount.
    func fetchLinkedTransactionIds() -> Set<Int> {
        query(read: { db in
            let sql = "SELECT linked_transaction_id FROM tricount_entries WHERE linked_transaction_id IS NOT NULL"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return Set<Int>() }
            defer { sqlite3_finalize(stmt) }
            var ids = Set<Int>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.insert(Int(sqlite3_column_int(stmt, 0)))
            }
            return ids
        }) ?? []
    }

    /// Retourne le groupId, titre et entryId du Tricount lié à une transaction donnée.
    func fetchLinkedTricountInfo(transactionId: Int) -> (groupId: Int, groupTitle: String, entryId: Int)? {
        query(read: { db in
            let sql = """
            SELECT g.id, g.title, e.id
            FROM tricount_entries e
            JOIN tricount_groups g ON g.id = e.group_id
            WHERE e.linked_transaction_id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (Int(sqlite3_column_int(stmt, 0)), string(from: stmt, index: 1), Int(sqlite3_column_int(stmt, 2)))
        }) ?? nil
    }

    /// Retourne un dictionnaire transaction_id → [Tag] pour une liste d'IDs donnée.
    func fetchTagsForTransactions(_ ids: [Int]) -> [Int: [Tag]] {
        guard !ids.isEmpty else { return [:] }
        return query(read: { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let sql = """
            SELECT tt.transaction_id, tg.id, tg.name, tg.color
            FROM transaction_tags tt
            JOIN tags tg ON tg.id = tt.tag_id
            WHERE tt.transaction_id IN (\(placeholders))
            ORDER BY tg.name COLLATE NOCASE;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
            }
            var result: [Int: [Tag]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let txId  = Int(sqlite3_column_int(stmt, 0))
                let tagId = Int(sqlite3_column_int(stmt, 1))
                let name  = string(from: stmt, index: 2)
                let color = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : string(from: stmt, index: 3)
                result[txId, default: []].append(Tag(id: tagId, name: name, color: color?.isEmpty == true ? nil : color))
            }
            return result
        }) ?? [:]
    }

    // MARK: - Comptage non catégorisé

    /// Nombre de transactions en catégorie AUTRE (id=40 ou NULL) sur la période donnée.
    /// `accountId == 0` = tous les comptes.
    func fetchUncategorizedCount(accountId: Int, from: Date, to: Date) -> Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to))
        let toRaw   = fmt.string(from: max(from, to))
        return query(read: { db in
            let accountClause = accountId == 0 ? "" : "account_id = ? AND"
            // "Tous comptes" (0) exclut les comptes marqués "autres" ; un compte
            // précis reste inchangé, l'utilisateur consulte CE compte.
            let excludedAccountsClause = accountId == 0
                ? "AND (a.excluded_from_aggregates IS NULL OR a.excluded_from_aggregates = 0)"
                : ""
            let sql = """
            SELECT COUNT(*) FROM transactions
            LEFT JOIN accounts a ON a.id = transactions.account_id
            WHERE \(accountClause) tx_date >= ? AND tx_date <= ?
              AND category_id IS NULL
              \(excludedAccountsClause)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            var col: Int32 = 1
            if accountId != 0 {
                sqlite3_bind_int(stmt, col, Int32(accountId)); col += 1
            }
            sqlite3_bind_text(stmt, col, fromRaw, -1, SQLITE_TRANSIENT); col += 1
            sqlite3_bind_text(stmt, col, toRaw, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }) ?? 0
    }

    // MARK: - Balance

    /// Solde du compte depuis le début jusqu'à upToDate (ou toutes dates si nil).
    /// `accountId == 0` = somme sur tous les comptes (à manier avec précaution côté UI :
    /// la TransactionsView masque ce solde global car sa lecture est ambigüe lorsque
    /// les comptes incluent des CB, du cash et de l'épargne aux régimes différents).
    func fetchAccountBalance(accountId: Int, upToDate: Date? = nil) -> Double {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = upToDate.map { fmt.string(from: $0) }
        return query(read: { db in
            var stmt: OpaquePointer?
            let accountClause = accountId == 0 ? "" : "account_id = ?"
            let dateClause: String = {
                guard dateStr != nil else { return "" }
                return accountClause.isEmpty ? "tx_date <= ?" : "AND tx_date <= ?"
            }()
            let whereCombined = [accountClause, dateClause].filter { !$0.isEmpty }.joined(separator: " ")
            let sql = whereCombined.isEmpty
                ? "SELECT COALESCE(SUM(amount), 0.0) FROM transactions"
                : "SELECT COALESCE(SUM(amount), 0.0) FROM transactions WHERE \(whereCombined)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0.0 }
            defer { sqlite3_finalize(stmt) }
            var col: Int32 = 1
            if accountId != 0 {
                sqlite3_bind_int(stmt, col, Int32(accountId)); col += 1
            }
            if let ds = dateStr {
                sqlite3_bind_text(stmt, col, (ds as NSString).utf8String, -1, nil)
            }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : 0.0
        }) ?? 0.0
    }

    // MARK: - Tag totals (dashboard)

    /// accountId = nil → tous les comptes confondus.
    func fetchTagTotals(accountId: Int? = nil, from: Date, to: Date) -> [TagTotal] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(from, to)); let toRaw = fmt.string(from: max(from, to))
        return query(read: { db in
            let accountClause = accountId != nil ? "AND t.account_id = ?" : ""
            let excludedAccountsJoin = accountId == nil ? Self.excludedAccountsJoin : ""
            let excludedAccountsClause = accountId == nil ? "AND \(Self.excludedAccountsClause)" : ""
            let sql = """
            SELECT tg.id, tg.name, tg.color, SUM(t.amount) as total
            FROM tags tg
            JOIN transaction_tags tt ON tt.tag_id = tg.id
            JOIN transactions t ON t.id = tt.transaction_id
            LEFT JOIN payees ti ON ti.id = t.payee_id
            \(excludedAccountsJoin)
            WHERE t.tx_date >= ? AND t.tx_date <= ?
              \(accountClause)
              AND (t.payee_id IS NULL OR ti.linked_account_id IS NULL)
              \(excludedAccountsClause)
            GROUP BY tg.id
            ORDER BY ABS(SUM(t.amount)) DESC
            LIMIT 15;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, toRaw, -1, SQLITE_TRANSIENT)
            if let accountId { sqlite3_bind_int(stmt, 3, Int32(accountId)) }
            var results: [TagTotal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let color = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : string(from: stmt, index: 2)
                let tag = Tag(id: Int(sqlite3_column_int(stmt, 0)), name: string(from: stmt, index: 1), color: color?.isEmpty == true ? nil : color)
                results.append(TagTotal(tag: tag, total: sqlite3_column_double(stmt, 3)))
            }
            return results
        }) ?? []
    }

    // MARK: - Fetch all filtered transactions (filtered dashboard)

    /// `excludeOtherAccounts` : opt-in, comme `excludeInternalTransfers` — seuls les
    /// appelants "calcul agrégé" (ex. `FilteredDashboardViewModel`) le passent à `true`.
    /// L'explorateur Transactions et la recherche globale ne sont PAS des calculs :
    /// un compte marqué "hors calculs" doit y rester visible/recherchable normalement.
    func fetchAllFilteredTransactions(filter: TransactionFilter, excludeInternalTransfers: Bool = false, excludeOtherAccounts: Bool = false) -> [FinanceTransaction] {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let fromRaw = fmt.string(from: min(filter.from, filter.to))
        let toRaw   = fmt.string(from: max(filter.from, filter.to))

        return query(read: { db in
            // accountId == 0 = "Tous les comptes" → on retire la clause account.
            var conditions: [String] = []
            if filter.accountId != 0 { conditions.append("t.account_id = ?") }
            conditions.append(contentsOf: ["t.tx_date >= ?", "t.tx_date <= ?"])
            if filter.categoryId == -2 { conditions.append("t.category_id IS NULL") }
            else if filter.categoryId != -1 { conditions.append("t.category_id = ?") }
            if let txIds = filter.tagFilteredTxIds, !txIds.isEmpty {
                let placeholders = txIds.map { _ in "?" }.joined(separator: ",")
                conditions.append("t.id IN (\(placeholders))")
            }
            if !filter.payeeSearchText.isEmpty {
                conditions.append("COALESCE(ti.name,'') LIKE ?")
            }
            if !filter.labelSearchText.isEmpty {
                conditions.append("COALESCE(t.information,'') LIKE ?")
            }
            if excludeInternalTransfers {
                conditions.append("(t.payee_id IS NULL OR ti.linked_account_id IS NULL)")
            }
            if excludeOtherAccounts { conditions.append(Self.excludedAccountsClause) }
            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
            SELECT t.id, t.account_id,
                COALESCE(ti.name,''), COALESCE(c.name,''), COALESCE(m.name,''),
                COALESCE(t.information,''), t.amount, COALESCE(t.tx_date,''),
                t.payee_id, t.category_id, t.payment_type_id, rb.payee_id,
                COALESCE(tr.name,'')
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN payment_types m ON m.id = t.payment_type_id
            LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
            LEFT JOIN payees tr ON tr.id = rb.payee_id
            \(excludeOtherAccounts ? Self.excludedAccountsJoin : "")
            WHERE \(whereClause)
            ORDER BY t.tx_date ASC, t.id ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            var col: Int32 = 1
            if filter.accountId != 0 {
                sqlite3_bind_int(stmt, col, Int32(filter.accountId));  col += 1
            }
            sqlite3_bind_text(stmt, col, fromRaw, -1, SQLITE_TRANSIENT); col += 1
            sqlite3_bind_text(stmt, col, toRaw, -1, SQLITE_TRANSIENT);   col += 1
            if filter.categoryId != -1 && filter.categoryId != -2 { sqlite3_bind_int(stmt, col, Int32(filter.categoryId)); col += 1 }
            if let txIds = filter.tagFilteredTxIds, !txIds.isEmpty {
                for id in txIds { sqlite3_bind_int(stmt, col, Int32(id)); col += 1 }
            }
            if !filter.payeeSearchText.isEmpty {
                sqlite3_bind_text(stmt, col, "%\(filter.payeeSearchText)%", -1, SQLITE_TRANSIENT); col += 1
            }
            if !filter.labelSearchText.isEmpty {
                sqlite3_bind_text(stmt, col, "%\(filter.labelSearchText)%", -1, SQLITE_TRANSIENT); col += 1
            }

            func optInt(_ c: Int32) -> Int? {
                sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, c))
            }
            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FinanceTransaction(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    accountId: Int(sqlite3_column_int(stmt, 1)),
                    tiersId: optInt(8), categoryId: optInt(9), paymentTypeId: optInt(10),
                    remboursementTiersId: optInt(11),
                    tiersName: string(from: stmt, index: 2),
                    categoryName: string(from: stmt, index: 3),
                    paymentTypeName: string(from: stmt, index: 4),
                    remboursementTiersName: string(from: stmt, index: 12),
                    information: string(from: stmt, index: 5),
                    libelleBrut: nil,
                    amount: sqlite3_column_double(stmt, 6),
                    date: fmt.date(from: string(from: stmt, index: 7)) ?? Date()
                ))
            }
            return results
        }) ?? []
    }

    // MARK: - Console SQL

    func executeSQL(_ sql: String) -> Result<SQLQueryResult, SQLError> {
        guard store.databaseExists else { return .failure(SQLError(message: "Aucune base de données disponible")) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return .failure(SQLError(message: "Impossible d'ouvrir la base de données"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(SQLError(message: "Erreur SQL : \(String(cString: sqlite3_errmsg(db)))"))
        }
        defer { sqlite3_finalize(stmt) }
        let colCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<colCount).map { i in
            sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
        }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW && rows.count < 2000 {
            let row = (0..<colCount).map { i -> String in
                switch sqlite3_column_type(stmt, Int32(i)) {
                case SQLITE_INTEGER: return String(sqlite3_column_int64(stmt, Int32(i)))
                case SQLITE_FLOAT:   return String(sqlite3_column_double(stmt, Int32(i)))
                case SQLITE_TEXT:    return String(cString: sqlite3_column_text(stmt, Int32(i)))
                case SQLITE_NULL:    return "NULL"
                default:             return "BLOB"
                }
            }
            rows.append(row)
        }
        return .success(SQLQueryResult(columns: columns, rows: rows))
    }

    @discardableResult
    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        store.writeSingle(sql: sql, bind: bind)
    }

    // MARK: - Toutes transactions toutes comptes (budget)

    /// Recupere les transactions de TOUS les comptes sur une periode donnee.
    /// Utilise par le module Budget qui ne filtre pas par compte.
    func fetchTransactionsAllAccounts(from: Date, to: Date, limit: Int = 500, offset: Int = 0) -> [FinanceTransaction] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fromRaw = formatter.string(from: min(from, to))
        let toRaw   = formatter.string(from: max(from, to))

        return query(read: { db in
            let sql = """
            SELECT
                t.id,
                t.account_id,
                COALESCE(ti.name, ''),
                COALESCE(c.name, ''),
                COALESCE(m.name, ''),
                COALESCE(t.information, ''),
                t.amount,
                COALESCE(t.tx_date, ''),
                t.payee_id,
                t.category_id,
                t.payment_type_id,
                rb.payee_id,
                COALESCE(tr.name, ''),
                t.libelle_brut
            FROM transactions t
            LEFT JOIN payees ti ON ti.id = t.payee_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN payment_types m ON m.id = t.payment_type_id
            LEFT JOIN reimbursements rb ON rb.transaction_id = t.id
            LEFT JOIN payees tr ON tr.id = rb.payee_id
            \(Self.excludedAccountsJoin)
            WHERE t.tx_date >= ?
              AND t.tx_date <= ?
              AND (t.payee_id IS NULL OR ti.linked_account_id IS NULL)
              AND \(Self.excludedAccountsClause)
            ORDER BY t.tx_date DESC, t.id DESC
            LIMIT ? OFFSET ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, fromRaw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, toRaw,   -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt,  3, Int32(limit))
            sqlite3_bind_int(stmt,  4, Int32(offset))

            func optInt(_ col: Int32) -> Int? {
                sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
            }
            var results: [FinanceTransaction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FinanceTransaction(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    accountId: Int(sqlite3_column_int(stmt, 1)),
                    tiersId: optInt(8), categoryId: optInt(9),
                    paymentTypeId: optInt(10), remboursementTiersId: optInt(11),
                    tiersName: string(from: stmt, index: 2),
                    categoryName: string(from: stmt, index: 3),
                    paymentTypeName: string(from: stmt, index: 4),
                    remboursementTiersName: string(from: stmt, index: 12),
                    information: string(from: stmt, index: 5),
                    libelleBrut: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : string(from: stmt, index: 13),
                    amount: sqlite3_column_double(stmt, 6),
                    date: formatter.date(from: string(from: stmt, index: 7)) ?? Date()
                ))
            }
            return results
        }) ?? []
    }

    private func query<T>(read block: (OpaquePointer) -> T) -> T? { store.read(block) }

}
