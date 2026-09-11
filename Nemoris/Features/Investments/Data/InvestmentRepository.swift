import Foundation
import SQLite3

private let SQLITE_TRANSIENT_INVEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct InvestmentRepository {

    private let store: SQLiteStore

    /// The default value targets the app's own database: existing call sites
    /// need no change.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Fetch (with derived columns computed on the fly)
    //
    // `quantity`, `average_buy_price` and `purchase_date` are not columns of
    // `investment_positions`; neither are `current_value` and `invested_amount`
    // on `investment_accounts`. Everything is computed in SQL at fetch time, from
    // the `investment_orders` and the current positions — drift is impossible.

    func fetchAccounts() -> [InvestmentAccount] {
        query { db in
            // position_summary CTE: for each position, compute the net quantity
            //   (Σ BUY − Σ SELL) and the weighted average cost (Σ BUY_cost / Σ BUY_qty).
            //   These values are then reused to sum per account.
            //
            // Account-level invested_amount = Σ (qty × average cost) of the account's
            //   positions = residual exposure. Consistent with the definition of
            //   InvestmentPosition.investedAmount.
            let sql = """
            WITH position_summary AS (
                SELECT
                    p.id,
                    p.account_id,
                    p.current_value,
                    COALESCE(SUM(CASE WHEN o.order_type='BUY'  THEN o.quantity ELSE 0 END), 0)
                    - COALESCE(SUM(CASE WHEN o.order_type='SELL' THEN o.quantity ELSE 0 END), 0) AS qty,
                    CASE
                        WHEN COALESCE(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity ELSE 0 END), 0) > 0
                        THEN COALESCE(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity*o.unit_price + o.fees ELSE 0 END), 0)
                             / SUM(CASE WHEN o.order_type='BUY' THEN o.quantity ELSE 0 END)
                        ELSE 0
                    END AS pru
                FROM investment_positions p
                LEFT JOIN investment_orders o ON o.position_id = p.id
                GROUP BY p.id
            )
            SELECT
                a.id, a.name, a.broker, a.currency, a.account_type, a.opened_at,
                COALESCE(SUM(ps.current_value), 0) AS current_value_total,
                COALESCE(SUM(ps.qty * ps.pru), 0) AS invested_amount_total,
                COALESCE(a.cash_balance, 0) AS cash_balance
            FROM investment_accounts a
            LEFT JOIN position_summary ps ON ps.account_id = a.id
            GROUP BY a.id
            ORDER BY a.name COLLATE NOCASE;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [InvestmentAccount] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateRaw = string(from: stmt, index: 5)
                results.append(InvestmentAccount(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    broker: string(from: stmt, index: 2),
                    currency: string(from: stmt, index: 3),
                    accountType: string(from: stmt, index: 4),
                    currentValue: sqlite3_column_double(stmt, 6),
                    investedAmount: sqlite3_column_double(stmt, 7),
                    openedAt: dateFormatter.date(from: dateRaw) ?? Date(),
                    cashBalance: sqlite3_column_double(stmt, 8)
                ))
            }
            return results
        } ?? []
    }

    func fetchPositions(accountId: Int) -> [InvestmentPosition] {
        query { db in
            // net qty = Σ BUY − Σ SELL
            // weighted average cost = Σ (BUY.qty × BUY.unit_price + BUY.fees) / Σ BUY.qty
            // first_buy_date = MIN(BUY.executed_at), falling back to today if no BUY
            //
            // ORDER BY first_buy_date DESC: most recent positions first. Positions
            // without orders fall back to "today" → they come first.
            let sql = """
            SELECT
                p.id, p.account_id, p.asset_type, p.asset_name, p.ticker,
                p.current_value, COALESCE(p.isin, '') AS isin,
                MAX(0,
                    COALESCE(SUM(CASE WHEN o.order_type='BUY'  THEN o.quantity ELSE 0 END), 0)
                  - COALESCE(SUM(CASE WHEN o.order_type='SELL' THEN o.quantity ELSE 0 END), 0)
                ) AS qty,
                CASE
                    WHEN COALESCE(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity ELSE 0 END), 0) > 0
                    THEN COALESCE(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity*o.unit_price + o.fees ELSE 0 END), 0)
                         / SUM(CASE WHEN o.order_type='BUY' THEN o.quantity ELSE 0 END)
                    ELSE 0
                END AS pru,
                COALESCE(MIN(CASE WHEN o.order_type='BUY' THEN o.executed_at END), date('now')) AS first_buy_date
            FROM investment_positions p
            LEFT JOIN investment_orders o ON o.position_id = p.id
            WHERE p.account_id = ?
            GROUP BY p.id
            ORDER BY first_buy_date DESC, p.id DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(accountId))

            var results: [InvestmentPosition] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateRaw = string(from: stmt, index: 9)
                results.append(InvestmentPosition(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    accountId: Int(sqlite3_column_int(stmt, 1)),
                    assetType: string(from: stmt, index: 2),
                    assetName: string(from: stmt, index: 3),
                    ticker: string(from: stmt, index: 4),
                    isin: string(from: stmt, index: 6),
                    quantity: sqlite3_column_double(stmt, 7),
                    averageBuyPrice: sqlite3_column_double(stmt, 8),
                    currentValue: sqlite3_column_double(stmt, 5),
                    purchaseDate: dateFormatter.date(from: dateRaw) ?? Date()
                ))
            }
            return results
        } ?? []
    }

    @discardableResult
    /// Variant of `addAccount` that returns the created account's `Int` ID (live
    /// sync needs it to attach the link to the freshly created account).
    func addAccountAndGetId(name: String, broker: String, currency: String, accountType: String,
                            openedAt: Date) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO investment_accounts
                (name, broker, currency, account_type, opened_at)
            VALUES (?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 2, broker, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 3, currency, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 4, accountType, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 5, dateFormatter.string(from: openedAt), -1, SQLITE_TRANSIENT_INVEST)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Creates an account. The `currentValue` and `investedAmount` parameters are
    /// accepted for call-site compatibility (LiveSync, forms) but SILENTLY
    /// IGNORED — these values are derived from positions/orders and computed at
    /// fetch time.
    func addAccount(name: String, broker: String, currency: String, accountType: String,
                    currentValue: Double, investedAmount: Double, openedAt: Date) -> Bool {
        writeSingle(sql: """
            INSERT INTO investment_accounts (name, broker, currency, account_type, opened_at)
            VALUES (?, ?, ?, ?, ?)
            """) { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 2, broker, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 3, currency, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 4, accountType, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 5, dateFormatter.string(from: openedAt), -1, SQLITE_TRANSIENT_INVEST)
        }
    }

    /// Updates an account's EDITABLE fields. `currentValue` and `investedAmount`
    /// on the struct are IGNORED — they are derived from positions/orders and
    /// computed at fetch time. `cashBalance` is persisted, for available cash.
    @discardableResult
    func updateAccount(_ account: InvestmentAccount) -> Bool {
        writeSingle(sql: """
            UPDATE investment_accounts
            SET name = ?, broker = ?, currency = ?, account_type = ?, opened_at = ?, cash_balance = ?
            WHERE id = ?
            """) { stmt in
            sqlite3_bind_text(stmt, 1, account.name, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 2, account.broker, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 3, account.currency, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 4, account.accountType, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 5, dateFormatter.string(from: account.openedAt), -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_double(stmt, 6, account.cashBalance)
            sqlite3_bind_int(stmt, 7, Int32(account.id))
        }
    }

    /// Deletes an account and its tree with a manual CASCADE.
    ///
    /// The schema does declare `ON DELETE CASCADE` on investment_positions (and
    /// investment_orders → positions, investment_live_sync → accounts), but
    /// SQLite has `foreign_keys = OFF` by default → the FK declarations are
    /// ignored. The cascade is therefore done by hand, rather than enabling
    /// `foreign_keys = ON` globally, which could break other tables.
    ///
    /// Order (children first, following the FK logic):
    ///   1. The positions' sync traces (UserDefaults)
    ///   2. investment_orders attached to the account's positions
    ///   3. The account's investment_positions
    ///   4. investment_live_sync links to this account (otherwise orphaned)
    ///   5. The final investment_accounts row
    @discardableResult
    func deleteAccount(id: Int) -> Bool {
        // Steps 1 + 2 + 3: positions and their orders / traces.
        let positions = fetchPositions(accountId: id)
        for position in positions {
            _ = deletePosition(id: position.id)  // cascade orders + trace + position
        }

        guard store.databaseExists else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Step 4: remove the LiveSync links attached to the account.
        // (The Keychain credential is cleaned by LiveSyncRepository.deleteLink, but
        // that API isn't reachable from here without a circular dependency → direct SQL.)
        sqlite3_exec(db,
            "DELETE FROM investment_live_sync WHERE account_id = \(id);",
            nil, nil, nil)

        // Step 5: DELETE the account
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "DELETE FROM investment_accounts WHERE id = ?",
            -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Creates a position. The `quantity`, `averageBuyPrice` and `purchaseDate`
    /// parameters are accepted for call-site compatibility (CSV import, LiveSync)
    /// but SILENTLY IGNORED — these values are derived from `investment_orders`
    /// and computed at fetch time. To materialize a quantity/average cost at
    /// creation, the caller must insert a BUY order after this method (see the
    /// PDF import, `insertPositionsDetailed`).
    ///
    /// `currentValue` is persisted: it's the instantaneous market value, not
    /// derived from the orders.
    @discardableResult
    func addPosition(accountId: Int, assetType: String, assetName: String, ticker: String,
                     quantity: Double, averageBuyPrice: Double, currentValue: Double, purchaseDate: Date) -> Bool {
        writeSingle(sql: """
            INSERT INTO investment_positions (account_id, asset_type, asset_name, ticker, current_value)
            VALUES (?, ?, ?, ?, ?)
            """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(accountId))
            sqlite3_bind_text(stmt, 2, assetType, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 3, assetName, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 4, ticker, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_double(stmt, 5, currentValue)
        }
    }


    /// Variant of `addPosition` that returns the created position's ID. Used by
    /// the PDF import, which then attaches orders to it. `purchaseDate` is
    /// IGNORED — the derived date will be the `MIN(executedAt)` of the attached
    /// BUY orders. `isin` is persisted to allow syncing via OpenFIGI.
    func addPositionAndGetId(accountId: Int, assetType: String, assetName: String,
                             ticker: String, isin: String = "", purchaseDate: Date) -> Int? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO investment_positions
                (account_id, asset_type, asset_name, ticker, isin, current_value)
            VALUES (?, ?, ?, ?, ?, 0)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(accountId))
        sqlite3_bind_text(stmt, 2, assetType, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 3, assetName, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 4, ticker, -1, SQLITE_TRANSIENT_INVEST)
        let isinTrimmed = isin.trimmingCharacters(in: .whitespacesAndNewlines)
        if isinTrimmed.isEmpty {
            sqlite3_bind_null(stmt, 5)
        } else {
            sqlite3_bind_text(stmt, 5, isinTrimmed, -1, SQLITE_TRANSIENT_INVEST)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Updates a position's EDITABLE fields (identity + market value). The
    /// DERIVED fields (`quantity`, `averageBuyPrice`, `purchaseDate`) are not in
    /// the schema — they are computed at fetch time by aggregating
    /// `investment_orders`. Values passed in these fields on the struct are
    /// silently ignored.
    @discardableResult
    func updatePosition(_ position: InvestmentPosition) -> Bool {
        writeSingle(sql: """
            UPDATE investment_positions
            SET asset_type = ?, asset_name = ?, ticker = ?, isin = ?, current_value = ?
            WHERE id = ?
            """) { stmt in
            sqlite3_bind_text(stmt, 1, position.assetType, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 2, position.assetName, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_text(stmt, 3, position.ticker, -1, SQLITE_TRANSIENT_INVEST)
            let isinTrimmed = position.isin.trimmingCharacters(in: .whitespacesAndNewlines)
            if isinTrimmed.isEmpty {
                sqlite3_bind_null(stmt, 4)
            } else {
                sqlite3_bind_text(stmt, 4, isinTrimmed, -1, SQLITE_TRANSIENT_INVEST)
            }
            sqlite3_bind_double(stmt, 5, position.currentValue)
            sqlite3_bind_int(stmt, 6, Int32(position.id))
        }
    }

    /// Deletes a position with a manual CASCADE:
    /// 1. Captures the identifiers (ticker + isin) to clear their sync trace
    /// 2. DELETEs the attached investment_orders (SQLite foreign keys are OFF by default)
    /// 3. DELETEs the position
    /// 4. Clears the UserDefaults trace — otherwise recreating a position with
    ///    the same ticker would bring back the old sync trace.
    @discardableResult
    func deletePosition(id: Int) -> Bool {
        // Step 1: capture the identifiers BEFORE the delete
        var traceIdentifiers: [String] = []
        if let position = query({ db -> InvestmentPosition? in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "SELECT id, account_id, asset_type, asset_name, ticker, current_value, COALESCE(isin, '') FROM investment_positions WHERE id = ?",
                -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(id))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return InvestmentPosition(
                id: Int(sqlite3_column_int(stmt, 0)),
                accountId: Int(sqlite3_column_int(stmt, 1)),
                assetType: string(from: stmt, index: 2),
                assetName: string(from: stmt, index: 3),
                ticker: string(from: stmt, index: 4),
                isin: string(from: stmt, index: 6),
                quantity: 0, averageBuyPrice: 0,
                currentValue: sqlite3_column_double(stmt, 5),
                purchaseDate: Date()
            )
        }) ?? nil {
            traceIdentifiers = [position.isin, position.ticker].filter { !$0.isEmpty }
        }

        // Step 2: DELETE the attached orders
        _ = writeSingle(sql: "DELETE FROM investment_orders WHERE position_id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }

        // Step 3: DELETE the position
        let deleted = writeSingle(sql: "DELETE FROM investment_positions WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }

        // Step 4: clean the UserDefaults traces
        if !traceIdentifiers.isEmpty {
            InvestmentSyncTraceStore.clear(identifiers: traceIdentifiers)
        }

        return deleted
    }

    // MARK: - Orders CRUD + recompute position

    /// Fetches a position's orders, sorted chronologically (oldest first).
    func fetchOrders(positionId: Int) -> [InvestmentOrder] {
        query { db in
            let sql = """
                SELECT id, position_id, order_type, quantity, unit_price, fees, executed_at, notes, external_id
                FROM investment_orders
                WHERE position_id = ?
                ORDER BY executed_at ASC, id ASC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(positionId))

            var orders: [InvestmentOrder] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let typeRaw = string(from: stmt, index: 2)
                let dateRaw = string(from: stmt, index: 6)
                guard let type = InvestmentOrderType(rawValue: typeRaw),
                      let date = dateFormatter.date(from: dateRaw) else { continue }
                let notes: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : string(from: stmt, index: 7)
                let externalId: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : string(from: stmt, index: 8)
                orders.append(InvestmentOrder(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    positionId: Int(sqlite3_column_int(stmt, 1)),
                    orderType: type,
                    quantity: sqlite3_column_double(stmt, 3),
                    unitPrice: sqlite3_column_double(stmt, 4),
                    fees: sqlite3_column_double(stmt, 5),
                    executedAt: date,
                    notes: notes,
                    externalId: externalId
                ))
            }
            return orders
        } ?? []
    }

    @discardableResult
    func addOrder(_ order: InvestmentOrder) -> Bool {
        // INSERT OR IGNORE allows atomic deduplication on external_id (UNIQUE INDEX).
        // Manual orders (externalId == nil) aren't constrained by the partial
        // "WHERE external_id IS NOT NULL" index → normal insertion.
        writeSingle(sql: """
            INSERT OR IGNORE INTO investment_orders
                (position_id, order_type, quantity, unit_price, fees, executed_at, notes, external_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(order.positionId))
            sqlite3_bind_text(stmt, 2, order.orderType.rawValue, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_double(stmt, 3, order.quantity)
            sqlite3_bind_double(stmt, 4, order.unitPrice)
            sqlite3_bind_double(stmt, 5, order.fees)
            sqlite3_bind_text(stmt, 6, dateFormatter.string(from: order.executedAt), -1, SQLITE_TRANSIENT_INVEST)
            if let n = order.notes {
                sqlite3_bind_text(stmt, 7, n, -1, SQLITE_TRANSIENT_INVEST)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let ext = order.externalId {
                sqlite3_bind_text(stmt, 8, ext, -1, SQLITE_TRANSIENT_INVEST)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
        }
    }

    /// Checks whether an order with this `external_id` already exists.
    /// Lets the sync skip a pointless re-INSERT (the UNIQUE INDEX would block it
    /// anyway, but this avoids the query).
    func orderExistsWithExternalId(_ externalId: String) -> Bool {
        query { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM investment_orders WHERE external_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, externalId, -1, SQLITE_TRANSIENT_INVEST)
            return sqlite3_step(stmt) == SQLITE_ROW
        } ?? false
    }

    @discardableResult
    func updateOrder(_ order: InvestmentOrder) -> Bool {
        writeSingle(sql: """
            UPDATE investment_orders SET
                order_type = ?, quantity = ?, unit_price = ?, fees = ?,
                executed_at = ?, notes = ?
            WHERE id = ?
            """) { stmt in
            sqlite3_bind_text(stmt, 1, order.orderType.rawValue, -1, SQLITE_TRANSIENT_INVEST)
            sqlite3_bind_double(stmt, 2, order.quantity)
            sqlite3_bind_double(stmt, 3, order.unitPrice)
            sqlite3_bind_double(stmt, 4, order.fees)
            sqlite3_bind_text(stmt, 5, dateFormatter.string(from: order.executedAt), -1, SQLITE_TRANSIENT_INVEST)
            if let n = order.notes {
                sqlite3_bind_text(stmt, 6, n, -1, SQLITE_TRANSIENT_INVEST)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int(stmt, 7, Int32(order.id))
        }
    }

    @discardableResult
    func deleteOrder(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM investment_orders WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    /// Deletes a position's SYNTHETIC orders — those created by
    /// `LiveSyncRegistry.persistPositions` on the 1st sync to materialize the
    /// snapshot quantity when trade history isn't available.
    ///
    /// Detection: `external_id IS NULL` (these are local seeds, unlike Binance
    /// trades, which all have an `external_id`) AND `notes LIKE 'Sync %'` (= the
    /// marker set by persistPositions). Orders entered manually by the user
    /// (null external_id but different notes) are therefore preserved.
    ///
    /// Call it from `persistTransactions` after inserting real trades —
    /// otherwise the quantity would be doubled (synthetic + sum of trades).
    /// Returns the number of deleted orders.
    @discardableResult
    func deleteSyntheticOrders(positionId: Int) -> Int {
        guard store.databaseExists else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        let sql = """
            DELETE FROM investment_orders
            WHERE position_id = ?
              AND external_id IS NULL
              AND notes LIKE 'Sync %'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(positionId))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// **NO-OP.** Kept for call sites that invoke it after mutating orders.
    ///
    /// `quantity` / `averageBuyPrice` / `purchaseDate` are computed on the fly in
    /// `fetchPositions` via JOIN + GROUP BY — there is no cache to maintain, so
    /// nothing to recompute. The method stays callable (always returns `true`)
    /// for code chaining it after `addOrder` / `updateOrder` / `deleteOrder`.
    @discardableResult
    func recomputePositionFromOrders(positionId: Int) -> Bool {
        // Deliberately empty: everything is derived at fetch time.
        return true
    }

    func insertPositions(_ rows: [InvestmentCSVPreviewRow], accountId: Int) -> (inserted: Int, errors: [String]) {
        let result = insertPositionsDetailed(rows, accountId: accountId)
        return (result.insertedCount, result.failures.map { "Ligne \($0.sourceRow): \($0.reason)" })
    }

    func insertPositionsDetailed(_ rows: [InvestmentCSVPreviewRow], accountId: Int) -> InvestmentImportResult {
        guard !rows.isEmpty else { return InvestmentImportResult(insertedCount: 0, failures: []) }
        var inserted = 0
        var failures: [InvestmentImportFailure] = []

        // `addPosition` ignores quantity/averageBuyPrice (derived from orders), so a
        // CSV-imported position would end up with a DERIVED quantity of 0. The
        // position is therefore created FIRST, then a synthetic BUY order (qty @
        // average cost) materializes the quantity and the average cost, + current_value
        // is written.
        let extIdFormatter = DateFormatter()
        extIdFormatter.locale = Locale(identifier: "en_US_POSIX")
        extIdFormatter.dateFormat = "yyyyMMdd"

        for row in rows {
            guard let newId = addPositionAndGetId(
                accountId: accountId,
                assetType: row.assetType,
                assetName: row.assetName,
                ticker: row.ticker,
                isin: "",
                purchaseDate: row.purchaseDate
            ) else {
                failures.append(InvestmentImportFailure(
                    sourceRow: row.sourceRow,
                    identifier: row.ticker,
                    quantity: row.quantity,
                    averageBuyPrice: row.averageBuyPrice,
                    reason: "Insertion SQL impossible"
                ))
                continue
            }

            // Synthetic BUY order (deduplicated via the "csv_…" external_id if the same
            // file is imported again). Skipped when the quantity is zero.
            if row.quantity > 0 {
                let key = row.ticker.isEmpty ? row.assetName : row.ticker
                let synthetic = InvestmentOrder(
                    id: 0,
                    positionId: newId,
                    orderType: .buy,
                    quantity: row.quantity,
                    unitPrice: row.averageBuyPrice,
                    fees: 0,
                    executedAt: row.purchaseDate,
                    notes: "Import CSV",
                    externalId: "csv_\(key)_\(extIdFormatter.string(from: row.purchaseDate))_\(row.quantity)"
                )
                _ = addOrder(synthetic)
            }

            // current_value: the CSV row's market value, falling back to cost.
            let marketValue = row.currentValue > 0 ? row.currentValue : row.quantity * row.averageBuyPrice
            let created = InvestmentPosition(
                id: newId, accountId: accountId,
                assetType: row.assetType, assetName: row.assetName,
                ticker: row.ticker, isin: "",
                quantity: row.quantity, averageBuyPrice: row.averageBuyPrice,
                currentValue: marketValue, purchaseDate: row.purchaseDate
            )
            _ = updatePosition(created)
            inserted += 1
        }
        return InvestmentImportResult(insertedCount: inserted, failures: failures)
    }

    /// After writing a price history, updates the `current_value` of every
    /// position matching this ticker — otherwise the hero shows €0 even after a
    /// successful sync.
    ///
    /// Logic: `current_value = derived_qty × last_close_price`. The quantity is
    /// computed on the fly through the same aggregation as `fetchPositions`
    /// (Σ BUY − Σ SELL).
    ///
    /// Cross-account: if several positions use the same ticker (uncommon but
    /// possible), all of them are updated.
    @MainActor
    @discardableResult
    func updatePositionsCurrentValueFromLatestPrice(identifier: String) -> Int {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.databaseExists else { return 0 }

        // The last close comes from the disk cache.
        guard let latestClose = PriceHistoryCache.shared.latestClose(identifier: trimmed) else {
            return 0
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Direct UPDATE: quantity recomputed inline from investment_orders, price
        // bound from the cache. A single SQL pass for every position matching the
        // ticker OR the ISIN.
        let sql = """
        UPDATE investment_positions AS pos
        SET current_value = (
            SELECT MAX(0,
                COALESCE(SUM(CASE WHEN o.order_type='BUY'  THEN o.quantity ELSE 0 END), 0)
              - COALESCE(SUM(CASE WHEN o.order_type='SELL' THEN o.quantity ELSE 0 END), 0)
            ) FROM investment_orders o WHERE o.position_id = pos.id
        ) * ?
        WHERE UPPER(pos.ticker) = UPPER(?)
           OR UPPER(COALESCE(pos.isin, '')) = UPPER(?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, latestClose)
        sqlite3_bind_text(stmt, 2, trimmed, -1, SQLITE_TRANSIENT_INVEST)
        sqlite3_bind_text(stmt, 3, trimmed, -1, SQLITE_TRANSIENT_INVEST)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Crypto repair: resets `current_value` to 0 for ALL CRYPTO positions + purges
    /// the price history stored under their tickers (BTC, ETH, FET, etc.), which
    /// actually belongs to same-named stocks scraped from Yahoo. Afterwards, the
    /// user reruns the Binance/wallet LiveSync to get the real values from
    /// CoinGecko.
    ///
    /// Safe to call several times (idempotent).
    @MainActor
    @discardableResult
    func purgeCorruptedCryptoData() -> (positionsReset: Int, historyRowsDeleted: Int) {
        guard store.databaseExists else { return (0, 0) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return (0, 0)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // 1. List the tickers of the CRYPTO positions (typically: BTC, ETH, FET, SOL...)
        var cryptoTickers: [String] = []
        let listSQL = "SELECT DISTINCT UPPER(ticker) FROM investment_positions WHERE UPPER(asset_type) = 'CRYPTO' AND ticker IS NOT NULL AND ticker != ''"
        var listStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, listSQL, -1, &listStmt, nil) == SQLITE_OK {
            while sqlite3_step(listStmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(listStmt, 0) {
                    cryptoTickers.append(String(cString: cStr))
                }
            }
        }
        sqlite3_finalize(listStmt)

        // 2. Purge the prices under these tickers from the disk cache (price history
        // lives in PriceHistoryCache, not in SQL).
        var deletedCount = 0
        for ticker in cryptoTickers {
            let existing = PriceHistoryCache.shared.fetch(identifier: ticker, limit: Int.max)
            if !existing.isEmpty {
                PriceHistoryCache.shared.remove(identifier: ticker)
                deletedCount += existing.count
            }
        }

        // 3. Reset current_value = 0 on every CRYPTO position
        var resetCount = 0
        let resetSQL = "UPDATE investment_positions SET current_value = 0 WHERE UPPER(asset_type) = 'CRYPTO'"
        var resetStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, resetSQL, -1, &resetStmt, nil) == SQLITE_OK,
           sqlite3_step(resetStmt) == SQLITE_DONE {
            resetCount = Int(sqlite3_changes(db))
        }
        sqlite3_finalize(resetStmt)

        return (resetCount, deletedCount)
    }

    /// Stores an asset's price history. This data lives in a disk cache
    /// (`Library/Caches/`), not in the SQLite database — prices aren't user data,
    /// just a cache of the Yahoo/Stooq/CoinGecko APIs, so there's no reason to
    /// put them in the database.
    @MainActor
    @discardableResult
    func savePriceHistory(identifier: String, points: [InvestmentPricePoint], source: String = "unknown") -> Int {
        // `source` is unused — ignored.
        _ = source
        return PriceHistoryCache.shared.save(identifier: identifier, points: points)
    }

    /// Reads the history from the disk cache (hydrated into RAM on first access).
    @MainActor
    func fetchPriceHistory(identifier: String, limit: Int = 365) -> [InvestmentPricePoint] {
        PriceHistoryCache.shared.fetch(identifier: identifier, limit: limit)
    }

    private func query<T>(_ block: (OpaquePointer) -> T) -> T? { store.read(block) }

    @discardableResult
    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        store.writeSingle(sql: sql, bind: bind)
    }

}

struct InvestmentCSVPreviewRow: Identifiable {
    let id = UUID()
    let sourceRow: Int
    let assetType: String
    let assetName: String
    let ticker: String
    let quantity: Double
    let averageBuyPrice: Double
    let currentValue: Double
    let purchaseDate: Date
}

struct InvestmentImportFailure: Identifiable, Hashable {
    let id = UUID()
    let sourceRow: Int
    let identifier: String
    let quantity: Double
    let averageBuyPrice: Double
    let reason: String
}

struct InvestmentImportResult {
    let insertedCount: Int
    let failures: [InvestmentImportFailure]
}
