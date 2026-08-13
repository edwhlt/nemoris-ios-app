import Foundation
import SQLite3

private let SQLITE_TRANSIENT_INVEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct InvestmentRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Fetch (avec colonnes dérivées calculées à la volée)
    //
    // Depuis la migration v30, `quantity`, `average_buy_price` et `purchase_date`
    // n'existent plus comme colonnes sur `investment_positions` ; pareil pour
    // `current_value` et `invested_amount` sur `investment_accounts`. Tout est
    // calculé via SQL au moment du fetch, à partir des `investment_orders` et
    // des positions courantes — impossible de drift.

    func fetchAccounts() -> [InvestmentAccount] {
        query { db in
            // CTE position_summary : pour chaque position, on calcule qty nette
            //   (Σ BUY − Σ SELL) et PRU pondéré (Σ BUY_cost / Σ BUY_qty). On
            //   réutilise ensuite ces valeurs pour sommer par compte.
            //
            // invested_amount au niveau compte = Σ (qty × PRU) des positions du
            //   compte = exposure résiduelle. Cohérent avec la définition de
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
            // qty nette = Σ BUY − Σ SELL
            // pru pondéré = Σ (BUY.qty × BUY.unit_price + BUY.fees) / Σ BUY.qty
            // first_buy_date = MIN(BUY.executed_at), fallback today si aucun BUY
            //
            // ORDER BY first_buy_date DESC : on conserve l'ordre antérieur
            // (anciennement ORDER BY purchase_date DESC). Pour positions sans
            // ordre, on tombe sur "today" → elles se retrouvent en tête.
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
    /// Variante d'`addAccount` qui retourne le `Int` ID du compte créé (utile pour
    /// le live sync qui doit lier le link à l'account fraîchement créé).
    /// AXE I Couche 4.
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

    /// Crée un compte. Les paramètres `currentValue` et `investedAmount` sont
    /// conservés pour rétro-compat des call sites (LiveSync, formulaires) mais
    /// SILENCIEUSEMENT IGNORÉS depuis la migration v30 — ces valeurs sont
    /// désormais dérivées des positions/ordres et calculées au fetch.
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

    /// Met à jour les champs ÉDITABLES d'un compte. `currentValue` et
    /// `investedAmount` sur le struct sont conservés pour rétro-compat mais
    /// IGNORÉS — ils sont dérivés des positions/ordres et calculés au fetch.
    /// `cashBalance` (v34) est persisté pour la trésorerie disponible.
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

    /// Supprime un compte et son arborescence en CASCADE manuelle.
    ///
    /// Le schéma déclare bien `ON DELETE CASCADE` sur investment_positions
    /// (et investment_orders → positions, investment_live_sync → accounts)
    /// mais SQLite a `foreign_keys = OFF` par défaut → les déclarations FK
    /// sont ignorées. On fait donc le cascade manuellement pour ne pas
    /// activer `foreign_keys = ON` global qui pourrait casser d'autres tables.
    ///
    /// Ordre (enfants d'abord pour respecter la "logique FK") :
    ///   1. Sync traces des positions (UserDefaults)
    ///   2. investment_orders rattachés aux positions du compte
    ///   3. investment_positions du compte
    ///   4. investment_live_sync liens vers ce compte (sinon ils restent orphelins)
    ///   5. investment_accounts row finale
    @discardableResult
    func deleteAccount(id: Int) -> Bool {
        // Étape 1 + 2 + 3 : positions et leurs ordres / traces.
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

        // Étape 4 : retirer les LiveSync links rattachés au compte.
        // (Le credential Keychain est nettoyé par LiveSyncRepository.deleteLink
        // mais on n'a pas accès à l'API ici sans dépendance circulaire → SQL direct.)
        sqlite3_exec(db,
            "DELETE FROM investment_live_sync WHERE account_id = \(id);",
            nil, nil, nil)

        // Étape 5 : DELETE compte
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "DELETE FROM investment_accounts WHERE id = ?",
            -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Crée une position. Les paramètres `quantity`, `averageBuyPrice` et
    /// `purchaseDate` sont conservés pour rétro-compat des call sites (CSV
    /// import legacy, LiveSync) mais SILENCIEUSEMENT IGNORÉS depuis la
    /// migration v30 — ces valeurs sont dérivées des `investment_orders` et
    /// calculées au fetch. Pour matérialiser une qty/PRU à la création, le
    /// caller doit insérer un ordre BUY après cette méthode (cf. PDF import,
    /// `insertPositionsDetailed`).
    ///
    /// `currentValue` est persisté : c'est la valeur de marché instantanée,
    /// pas dérivée des ordres.
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


    /// Variante d'`addPosition` qui renvoie l'ID de la position créée. Utilisée
    /// par l'import PDF qui doit ensuite y rattacher des ordres. Le paramètre
    /// `purchaseDate` est conservé pour rétro-compat mais IGNORÉ depuis v30 —
    /// la date dérivée sera le `MIN(executedAt)` des ordres BUY rattachés.
    /// `isin` (v31) est persisté pour permettre la sync via OpenFIGI.
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

    /// Met à jour les champs ÉDITABLES d'une position (identité + valeur marché).
    /// Les champs DÉRIVÉS (`quantity`, `averageBuyPrice`, `purchaseDate`) ont été
    /// supprimés du schéma à la migration v30 — ils sont calculés au fetch via
    /// agrégation des `investment_orders`. Si tu passes des valeurs dans ces
    /// champs sur le struct, elles sont silencieusement ignorées.
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

    /// Supprime une position en CASCADE manuelle :
    /// 1. Capture les identifiers (ticker + isin) pour effacer leur sync trace
    /// 2. DELETE des investment_orders rattachés (foreign keys SQLite OFF par défaut)
    /// 3. DELETE de la position
    /// 4. Efface la trace UserDefaults — sinon recréer une position avec le
    ///    même ticker ferait remonter l'ancien trace de sync.
    @discardableResult
    func deletePosition(id: Int) -> Bool {
        // Étape 1 : capturer les identifiers AVANT le delete
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

        // Étape 2 : DELETE ordres rattachés
        _ = writeSingle(sql: "DELETE FROM investment_orders WHERE position_id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }

        // Étape 3 : DELETE position
        let deleted = writeSingle(sql: "DELETE FROM investment_positions WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }

        // Étape 4 : nettoyer les traces UserDefaults
        if !traceIdentifiers.isEmpty {
            InvestmentSyncTraceStore.clear(identifiers: traceIdentifiers)
        }

        return deleted
    }

    // MARK: - AXE K : Orders CRUD + recompute position

    /// Récupère les ordres d'une position, triés chronologiquement (plus ancien d'abord).
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
        // INSERT OR IGNORE permet la dédup atomique sur external_id (UNIQUE INDEX v33).
        // Pour les ordres manuels (externalId == nil), l'INDEX partiel "WHERE external_id IS NOT NULL"
        // ne les contraint pas → insertion normale possible.
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

    /// vérifie si un ordre avec cet `external_id` existe déjà.
    /// Permet au sync d'éviter le re-INSERT inutile (l'UNIQUE INDEX bloquerait
    /// de toute façon mais ça évite la requête).
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

    /// Supprime les ordres SYNTHÉTIQUES d'une position — ceux créés par
    /// `LiveSyncRegistry.persistPositions` à la 1ère sync pour matérialiser
    /// la quantité snapshot quand l'historique des trades n'est pas dispo.
    ///
    /// Détection : `external_id IS NULL` (ce sont nos seeds locaux, pas des
    /// trades Binance qui ont tous un `external_id`) ET `notes LIKE 'Sync %'`
    /// (= marqueur posé par persistPositions). On préserve donc les ordres
    /// saisis manuellement par l'utilisateur (qui ont external_id nul mais des notes
    /// différentes).
    ///
    /// À appeler depuis `persistTransactions` après qu'on ait inséré des
    /// trades réels — sinon on doublerait la qty (synthetic + somme des trades).
    /// Retourne le nombre d'ordres supprimés.
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

    /// **NO-OP depuis migration v30.** Conservé pour rétro-compat des call sites
    /// (PDF import, edit d'ordres, etc.) qui l'appelaient après mutation des
    /// ordres pour maintenir la cohérence du cache.
    ///
    /// Désormais, `quantity` / `averageBuyPrice` / `purchaseDate` sont calculés
    /// à la volée dans `fetchPositions` via JOIN+GROUP BY — pas de cache à
    /// maintenir, donc pas de recompute à déclencher. La méthode reste callable
    /// (retourne toujours `true`) pour ne pas casser le code existant qui
    /// la chaîne après `addOrder` / `updateOrder` / `deleteOrder`.
    @discardableResult
    func recomputePositionFromOrders(positionId: Int) -> Bool {
        // Volontairement vide : tout est dérivé au fetch.
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

        // Chantier C — fix bug qty=0 : depuis v30, `addPosition` ignore
        // quantity/averageBuyPrice (dérivés des ordres). Une position importée
        // en CSV se retrouvait donc avec une quantité DÉRIVÉE de 0. On crée
        // désormais la position PUIS un ordre BUY synthétique (qty @ PRU) pour
        // matérialiser la quantité et le PRU, + on écrit current_value.
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

            // Ordre BUY synthétique (dédup via external_id "csv_…" en cas de
            // ré-import du même fichier). Ignoré si quantité nulle.
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

            // current_value : valeur de marché de la ligne CSV, fallback coût.
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

    /// Après écriture d'un historique de cours, met à jour la `current_value`
    /// de toutes les positions qui matchent ce ticker — sinon le hero affiche
    /// €0 même après une sync réussie.
    ///
    /// Logique : `current_value = qty_dérivée × dernier_close_price`. La qty
    /// est calculée à la volée via la même agrégation que `fetchPositions`
    /// (Σ BUY − Σ SELL).
    ///
    /// Cross-account : si plusieurs positions utilisent le même ticker (peu
    /// fréquent mais possible), toutes sont mises à jour.
    @MainActor
    @discardableResult
    func updatePositionsCurrentValueFromLatestPrice(identifier: String) -> Int {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.databaseExists else { return 0 }

        // Depuis v33 : le dernier close vient du cache disque (plus de subquery SQL).
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

        // UPDATE direct : qty recalculée inline depuis investment_orders, prix
        // passé en bind depuis le cache. 1 seule passe SQL pour toutes les
        // positions matchant ticker OU ISIN.
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

    /// Réparation crypto : reset à 0 le `current_value` de TOUTES les positions
    /// CRYPTO + purge les `investment_price_history` stockés sous leurs tickers
    /// (BTC, ETH, FET, etc.) qui correspondent en fait à des données d'actions
    /// homonymes scrappées sur Yahoo. Après ça, l'utilisateur relance LiveSync Binance/
    /// wallet pour récupérer les vraies valeurs depuis CoinGecko.
    ///
    /// Sûr à appeler plusieurs fois (idempotent).
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

        // 1. Liste les tickers des positions CRYPTO (typique : BTC, ETH, FET, SOL...)
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

        // 2. Purge des prix sous ces tickers depuis le cache disque (depuis v33,
        // les price_history ne sont plus en SQL — voir PriceHistoryCache).
        var deletedCount = 0
        for ticker in cryptoTickers {
            let existing = PriceHistoryCache.shared.fetch(identifier: ticker, limit: Int.max)
            if !existing.isEmpty {
                PriceHistoryCache.shared.remove(identifier: ticker)
                deletedCount += existing.count
            }
        }

        // 3. Reset current_value = 0 sur toutes les positions CRYPTO
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

    /// Stocke l'historique de prix d'un actif. Depuis la migration v33 cette
    /// data est en cache disque (`Library/Caches/`), plus dans la base SQLite —
    /// les prix ne sont pas data utilisateur, juste un cache des APIs Yahoo/
    /// Stooq/CoinGecko, donc inutile de polluer la DB.
    @MainActor
    @discardableResult
    func savePriceHistory(identifier: String, points: [InvestmentPricePoint], source: String = "unknown") -> Int {
        // `source` ne sert plus à rien (avant on l'écrivait en SQL) — on l'ignore.
        _ = source
        return PriceHistoryCache.shared.save(identifier: identifier, points: points)
    }

    /// Lit l'historique depuis le cache disque (RAM-hydraté au 1er accès).
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
