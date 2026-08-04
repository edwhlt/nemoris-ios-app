import Foundation
import SQLite3

#if targetEnvironment(simulator)

/// Seeds the SQLite database with realistic fake French finance data for simulator testing.
/// Called once at app launch if the database is empty (no accounts).
enum SimulatorSeeder {

    static func seedIfNeeded() {
        let db = DatabaseManager.shared
        guard db.hasDatabase() else { return }
        var conn: OpaquePointer?
        guard sqlite3_open_v2(db.sqliteURL().path, &conn, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let conn else { sqlite3_close(conn); return }
        defer { sqlite3_close(conn) }

        // Branche 1 : DB neuve (pas d'accounts) → seed complet, tout est virgin.
        if tableIsEmpty(conn, table: "accounts") {
            exec(conn, "BEGIN;")
            seedAccounts(conn)
            seedPayees(conn)
            seedTags(conn)
            seedTransactions(conn)
            seedInvestments(conn)
            seedTricount(conn)
            seedBudget(conn)
            seedPatrimoine(conn)
            exec(conn, "COMMIT;")
            return
        }

        // Branche 2 : DB déjà peuplée par l'user (ou par un seed antérieur).
        // On ne touche à RIEN sauf au module Patrimoine si ses tables sont vides —
        // sinon les users existants ne verraient jamais de données de démo Patrimoine.
        // Garde-fou : on vérifie les 3 tables Patrimoine indépendamment.
        let assetsEmpty = tableIsEmpty(conn, table: "patrimoine_assets")
        let realEstateEmpty = tableIsEmpty(conn, table: "patrimoine_real_estate")
        let loansEmpty = tableIsEmpty(conn, table: "patrimoine_loans")
        if assetsEmpty && realEstateEmpty && loansEmpty {
            exec(conn, "BEGIN;")
            // Variante standalone-only : tous les actifs en manuel, pas de linkage
            // hardcodé vers accounts/investment_accounts (dont les IDs sont
            // inconnus dans une DB déjà peuplée par l'user).
            seedPatrimoineStandalone(conn)
            exec(conn, "COMMIT;")
        }

        // Goals — seed indépendant si la table est vide. Permet aux users qui
        // ont déjà du Patrimoine mais pas encore d'Objectifs de voir des démos.
        if tableIsEmpty(conn, table: "goals") {
            exec(conn, "BEGIN;")
            seedGoals(conn)
            exec(conn, "COMMIT;")
        }
    }

    /// Retourne true si la table existe et contient 0 ligne. Tolère les tables
    /// absentes (cas migrations pas encore appliquées) — renvoie false dans ce cas
    /// pour ne pas seed sur une base demi-migrée.
    private static func tableIsEmpty(_ conn: OpaquePointer, table: String) -> Bool {
        var stmt: OpaquePointer?
        // sqlite_master pour confirmer l'existence avant le SELECT COUNT
        let existsSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table)';"
        guard sqlite3_prepare_v2(conn, existsSQL, -1, &stmt, nil) == SQLITE_OK else { return false }
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        guard exists else { return false }

        sqlite3_prepare_v2(conn, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil)
        let count = sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        sqlite3_finalize(stmt)
        return count == 0
    }

    // MARK: - Accounts

    private static func seedAccounts(_ db: OpaquePointer) {
        let rows = [
            (1, "Compte Courant BNP", "COURANT"),
            (2, "Livret A", "EPARGNE"),
            (3, "Carte Différée Boursorama", "DIFFERE"),
        ]
        for (id, name, type) in rows {
            exec(db, "INSERT OR IGNORE INTO accounts (id, name, type) VALUES (\(id), '\(name)', '\(type)');")
        }
    }

    // MARK: - Payees

    private static func seedPayees(_ db: OpaquePointer) {
        // (id, name, regex, category_id)
        let rows: [(Int, String, String?, Int?)] = [
            (1,  "Carrefour Market",   "CARREFOUR",        10),
            (2,  "Leclerc",            "LECLERC",          10),
            (3,  "Monoprix",           "MONOPRIX",         10),
            (4,  "McDonald's",         "MCDONALD",         11),
            (5,  "Sushi Shop",         "SUSHI",            11),
            (6,  "Le Petit Bistrot",   nil,                11),
            (7,  "TotalEnergies",      "TOTAL",            12),
            (8,  "SNCF",              "SNCF",             13),
            (9,  "Navigo",            "NAVIGO|RATP",      13),
            (10, "Propriétaire",      nil,                14),
            (11, "EDF",               "EDF",              16),
            (12, "Orange",            "ORANGE",           15),
            (13, "Docteur Martin",    nil,                17),
            (14, "Pharmacie du Centre","PHARMACIE",        18),
            (15, "Fnac",              "FNAC",              5),
            (16, "Netflix",           "NETFLIX",          21),
            (17, "Spotify",           "SPOTIFY",          21),
            (18, "Decathlon",         "DECATHLON",        20),
            (19, "H&M",               "H&M|HM",            6),
            (20, "Zara",              "ZARA",              6),
            (21, "Booking.com",       "BOOKING",           7),
            (22, "Salaire Société Générale", "VIR SALAIRE", 22),
            (23, "Impôts",            "TRESOR PUBLIC",     9),
            (24, "Ameli",             "CPAM|AMELI",       23),
            (25, "Virement Livret A", nil,                nil),
        ]
        for (id, name, regex, catId) in rows {
            let r = regex.map { "'\($0)'" } ?? "NULL"
            let c = catId.map { "\($0)" } ?? "NULL"
            exec(db, "INSERT OR IGNORE INTO payees (id, name, regex, category_id) VALUES (\(id), '\(esc(name))', \(r), \(c));")
        }
        // Mark payee 25 as internal transfer to savings account
        exec(db, "UPDATE payees SET linked_account_id = 2 WHERE id = 25;")
    }

    // MARK: - Tags

    private static func seedTags(_ db: OpaquePointer) {
        let rows = [
            (1, "Vacances", "F59E0B"),
            (2, "Urgent",   "EF4444"),
            (3, "Pro",      "3B82F6"),
            (4, "Plaisir",  "8B5CF6"),
        ]
        for (id, name, color) in rows {
            exec(db, "INSERT OR IGNORE INTO tags (id, name, color) VALUES (\(id), '\(name)', '\(color)');")
        }
    }

    // MARK: - Transactions

    private static func seedTransactions(_ db: OpaquePointer) {
        // Generate 14 months of transactions (back-dated from today)
        let cal = Calendar.current
        let today = Date()
        var txId = 1

        struct TX {
            let payeeId: Int; let catId: Int?; let ptId: Int; let amount: Double; let info: String; let daysAgo: Int; let tagId: Int?
        }

        // Recurring monthly transactions per month
        func monthlyRecurring(offset: Int) -> [TX] {
            let base = offset * 30
            return [
                TX(payeeId: 10, catId: 14, ptId: 3, amount: -950.0,  info: "Loyer + charges", daysAgo: base + 1,  tagId: nil),
                TX(payeeId: 12, catId: 15, ptId: 3, amount: -29.99,  info: "Abonnement mobile", daysAgo: base + 5, tagId: 3),
                TX(payeeId: 11, catId: 16, ptId: 3, amount: -68.50,  info: "EDF électricité",  daysAgo: base + 8, tagId: nil),
                TX(payeeId: 16, catId: 21, ptId: 1, amount: -15.99,  info: "Netflix",          daysAgo: base + 3, tagId: 4),
                TX(payeeId: 17, catId: 21, ptId: 1, amount: -9.99,   info: "Spotify",          daysAgo: base + 3, tagId: 4),
                TX(payeeId: 22, catId: 22, ptId: 2, amount: 2850.0,  info: "Salaire net",      daysAgo: base + 0, tagId: nil),
                TX(payeeId: 25, catId: nil, ptId: 2, amount: -200.0, info: "Virement Livret A",daysAgo: base + 2, tagId: nil),
            ]
        }

        // Variable spending per month
        func variableSpending(offset: Int) -> [TX] {
            let base = offset * 30
            var txs: [TX] = []
            // Supermarket 2-3x/week
            let supermarkets: [(Int, Double)] = [(1, -67.40), (2, -103.20), (3, -45.80), (1, -88.60), (2, -55.10)]
            for (i, (pId, amt)) in supermarkets.enumerated() {
                txs.append(TX(payeeId: pId, catId: 10, ptId: 1, amount: amt + Double.random(in: -5...5), info: "Courses", daysAgo: base + 4 + i * 5, tagId: nil))
            }
            // Restaurants
            txs.append(TX(payeeId: 4,  catId: 11, ptId: 1, amount: -12.50, info: "Déjeuner", daysAgo: base + 7,  tagId: nil))
            txs.append(TX(payeeId: 6,  catId: 11, ptId: 1, amount: -38.00, info: "Dîner en famille", daysAgo: base + 14, tagId: nil))
            txs.append(TX(payeeId: 5,  catId: 11, ptId: 1, amount: -22.80, info: "Sushi",    daysAgo: base + 21, tagId: 4))
            // Transport
            txs.append(TX(payeeId: 9,  catId: 13, ptId: 1, amount: -86.40, info: "Pass Navigo mensuel", daysAgo: base + 2, tagId: nil))
            txs.append(TX(payeeId: 8,  catId: 13, ptId: 1, amount: -45.00, info: "TGV Paris-Lyon", daysAgo: base + 12, tagId: nil))
            // Health
            txs.append(TX(payeeId: 13, catId: 17, ptId: 1, amount: -25.00, info: "Consultation", daysAgo: base + 9, tagId: nil))
            txs.append(TX(payeeId: 14, catId: 18, ptId: 1, amount: -18.40, info: "Médicaments", daysAgo: base + 10, tagId: nil))
            // Ameli reimbursement
            txs.append(TX(payeeId: 24, catId: 23, ptId: 2, amount: +16.50, info: "Remboursement sécu", daysAgo: base + 20, tagId: nil))
            return txs
        }

        // Leisure / one-offs distributed across months
        let oneOffs: [(Int, TX)] = [
            (0, TX(payeeId: 15, catId: 5,  ptId: 1, amount: -129.0,  info: "Casque audio Fnac",     daysAgo: 8,  tagId: 4)),
            (1, TX(payeeId: 18, catId: 20, ptId: 1, amount: -89.99,  info: "Chaussures running",     daysAgo: 38, tagId: nil)),
            (1, TX(payeeId: 19, catId: 6,  ptId: 1, amount: -55.00,  info: "Veste H&M",              daysAgo: 42, tagId: nil)),
            (2, TX(payeeId: 20, catId: 6,  ptId: 1, amount: -79.90,  info: "Manteau Zara",           daysAgo: 72, tagId: nil)),
            (3, TX(payeeId: 21, catId: 7,  ptId: 1, amount: -340.0,  info: "Hôtel Barcelone",        daysAgo: 95, tagId: 1)),
            (3, TX(payeeId: 8,  catId: 7,  ptId: 1, amount: -120.0,  info: "Train aller-retour",     daysAgo: 97, tagId: 1)),
            (4, TX(payeeId: 7,  catId: 12, ptId: 1, amount: -65.00,  info: "Plein d'essence",        daysAgo: 125, tagId: nil)),
            (5, TX(payeeId: 23, catId: 9,  ptId: 2, amount: -1240.0, info: "Impôts sur le revenu",   daysAgo: 155, tagId: nil)),
            (6, TX(payeeId: 21, catId: 7,  ptId: 1, amount: -850.0,  info: "Vacances Italie",        daysAgo: 185, tagId: 1)),
            (7, TX(payeeId: 18, catId: 20, ptId: 1, amount: -120.0,  info: "Vélo elliptique",        daysAgo: 215, tagId: nil)),
            (9, TX(payeeId: 15, catId: 5,  ptId: 1, amount: -299.0,  info: "Tablette Fnac",          daysAgo: 275, tagId: 4)),
           (11, TX(payeeId: 21, catId: 7,  ptId: 1, amount: -620.0,  info: "Noël en famille",        daysAgo: 335, tagId: 1)),
        ]

        func dateFor(daysAgo: Int) -> String {
            let d = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: d)
        }

        var tagLinks: [(Int, Int)] = [] // (txId, tagId)

        func insertTX(_ tx: TX, accountId: Int = 1) {
            let catStr = tx.catId.map { "\($0)" } ?? "NULL"
            let date = dateFor(daysAgo: tx.daysAgo)
            exec(db, """
                INSERT INTO transactions (id, account_id, payee_id, category_id, payment_type_id, information, amount, tx_date)
                VALUES (\(txId), \(accountId), \(tx.payeeId), \(catStr), \(tx.ptId), '\(esc(tx.info))', \(tx.amount), '\(date)');
                """)
            if let tag = tx.tagId { tagLinks.append((txId, tag)) }
            txId += 1
        }

        for month in 0..<14 {
            for tx in monthlyRecurring(offset: month) { insertTX(tx) }
            for tx in variableSpending(offset: month) { insertTX(tx) }
        }
        for (_, tx) in oneOffs { insertTX(tx) }

        // Insert transaction-tag links
        for (tId, tagId) in tagLinks {
            exec(db, "INSERT OR IGNORE INTO transaction_tags (transaction_id, tag_id) VALUES (\(tId), \(tagId));")
        }
    }

    // MARK: - Investments

    private static func seedInvestments(_ db: OpaquePointer) {
        // Investment accounts (depuis v30 : pas de current_value / invested_amount,
        // ces valeurs sont dérivées des positions/ordres et calculées au fetch).
        exec(db, "INSERT OR IGNORE INTO investment_accounts (id, name, broker, currency, account_type, opened_at) VALUES (1, 'PEA Boursorama', 'Boursorama', 'EUR', 'PEA', '2020-03-15');")
        exec(db, "INSERT OR IGNORE INTO investment_accounts (id, name, broker, currency, account_type, opened_at) VALUES (2, 'CTO Degiro', 'Degiro', 'EUR', 'CTO', '2021-06-01');")
        exec(db, "INSERT OR IGNORE INTO investment_accounts (id, name, broker, currency, account_type, opened_at) VALUES (3, 'Crypto Coinbase', 'Coinbase', 'EUR', 'CRYPTO', '2022-01-10');")

        // Positions (depuis v30 : pas de quantity / average_buy_price / purchase_date,
        // ces valeurs sont dérivées des investment_orders ci-dessous).
        // (id, account_id, asset_type, asset_name, ticker, current_value, [synthetic BUY order : qty, unit_price, executed_at])
        let positions: [(Int, Int, String, String, String, Double, Double, Double, String)] = [
            (1, 1, "ETF",    "Amundi MSCI World", "EWLD.PA", 14625.0,  45.0, 250.0,    "2020-03-15"),
            (2, 1, "ETF",    "Lyxor CAC 40",      "CAC.PA",   3795.50, 30.0,  95.0,    "2020-09-10"),
            (3, 2, "STOCK",  "Apple Inc.",        "AAPL",     1820.0,  10.0, 155.0,    "2021-06-01"),
            (4, 2, "STOCK",  "LVMH",              "MC.PA",    2960.0,   4.0, 700.0,    "2022-03-20"),
            (5, 2, "ETF",    "iShares S&P 500",   "CSPX.L",   3060.0,   5.0, 450.0,    "2021-11-15"),
            (6, 3, "CRYPTO", "Bitcoin",           "BTC-EUR",  2800.0,   0.05, 32000.0, "2022-01-10"),
            (7, 3, "CRYPTO", "Ethereum",          "ETH-EUR",   400.0,   0.8,  2500.0,  "2022-05-15")
        ]
        for (id, accId, aType, aName, ticker, curVal, _, _, _) in positions {
            exec(db, "INSERT OR IGNORE INTO investment_positions (id, account_id, asset_type, asset_name, ticker, current_value) VALUES (\(id), \(accId), '\(aType)', '\(aName)', '\(ticker)', \(curVal));")
        }
        // Ordres BUY synthétiques pour matérialiser qty/PRU/firstBuyDate au fetch.
        // 1 ordre par position = équivalent du backfill v28 sur des positions neuves.
        for (posId, _, _, _, _, _, qty, unitPrice, execDate) in positions {
            exec(db, "INSERT OR IGNORE INTO investment_orders (position_id, order_type, quantity, unit_price, fees, executed_at) VALUES (\(posId), 'BUY', \(qty), \(unitPrice), 0, '\(execDate)');")
        }

        // Price history for main ETF (last 90 days) — depuis v35, le cache n'est
        // plus en SQL mais dans Library/Caches via PriceHistoryCache.
        let cal = Calendar.current; let today = Date()
        var price = 310.0
        var fakePoints: [InvestmentPricePoint] = []
        for dayAgo in stride(from: 90, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -dayAgo, to: today) else { continue }
            price = max(250, price + Double.random(in: -4...4.5))
            fakePoints.append(InvestmentPricePoint(
                id: "EWLD.PA-\(d.timeIntervalSince1970)",
                identifier: "EWLD.PA",
                date: d,
                close: price
            ))
        }
        Task { @MainActor in
            PriceHistoryCache.shared.save(identifier: "EWLD.PA", points: fakePoints)
        }
    }

    // MARK: - Tricount

    private static func seedTricount(_ db: OpaquePointer) {
        exec(db, "INSERT OR IGNORE INTO tricount_groups (id, tricount_key, title, currency, my_name, fetched_at) VALUES (1, 'fake-key-barcelone', 'Barcelone 2024', 'EUR', 'Moi', '2024-09-20T18:00:00Z');")
        exec(db, "INSERT OR IGNORE INTO tricount_groups (id, tricount_key, title, currency, my_name, fetched_at) VALUES (2, 'fake-key-coloc', 'Coloc Paris', 'EUR', 'Moi', '2025-01-10T10:00:00Z');")

        // Barcelone entries
        let bcnEntries: [(Int, Int, String, String, Double, String, String)] = [
            (1, 1, "Moi",    "Hôtel 3 nuits",     340.0, "2024-09-15", "NORMAL"),
            (2, 1, "Sophie", "Restaurant plage",   85.0,  "2024-09-16", "NORMAL"),
            (3, 1, "Moi",    "Billets musée Picasso", 42.0, "2024-09-17", "NORMAL"),
            (4, 1, "Lucas",  "Tapas bar",           62.0,  "2024-09-18", "NORMAL"),
            (5, 1, "Moi",    "Transport aéroport",  48.0,  "2024-09-19", "NORMAL"),
        ]
        for (id, gId, who, desc, total, date, type) in bcnEntries {
            exec(db, "INSERT OR IGNORE INTO tricount_entries (id, group_id, source_entry_uuid, source_updated_at, type_transaction, who_paid, total, currency, description, date) VALUES (\(id), \(gId), 'uuid-bcn-\(id)', '2024-09-20T10:00:00Z', '\(type)', '\(who)', \(total), 'EUR', '\(esc(desc))', '\(date)');")
        }
        // Shares for Barcelone (3 members: Moi, Sophie, Lucas)
        var shareId = 1
        for entryId in 1...5 {
            let total: Double = [340.0, 85.0, 42.0, 62.0, 48.0][entryId - 1]
            let share = (total / 3).rounded(toPlaces: 2)
            for member in ["Moi", "Sophie", "Lucas"] {
                exec(db, "INSERT OR IGNORE INTO tricount_shares (id, entry_id, member_name, amount) VALUES (\(shareId), \(entryId), '\(member)', \(share));")
                shareId += 1
            }
        }

        // Coloc entries
        let colocEntries: [(Int, Int, String, String, Double, String)] = [
            (6,  2, "Moi",    "Courses communes",   120.0, "2025-01-05"),
            (7,  2, "Thomas", "Facture EDF",         89.0, "2025-01-08"),
            (8,  2, "Moi",    "Internet fibre",      35.0, "2025-02-01"),
            (9,  2, "Thomas", "Produits ménagers",   45.0, "2025-02-10"),
            (10, 2, "Moi",    "Courses communes",   115.0, "2025-03-03"),
        ]
        for (id, gId, who, desc, total, date) in colocEntries {
            exec(db, "INSERT OR IGNORE INTO tricount_entries (id, group_id, source_entry_uuid, source_updated_at, type_transaction, who_paid, total, currency, description, date) VALUES (\(id), \(gId), 'uuid-coloc-\(id)', '2025-03-10T10:00:00Z', 'NORMAL', '\(who)', \(total), 'EUR', '\(esc(desc))', '\(date)');")
        }
        for entryId in 6...10 {
            let totals: [Int: Double] = [6: 120, 7: 89, 8: 35, 9: 45, 10: 115]
            let total = totals[entryId] ?? 50
            let share = (total / 2).rounded(toPlaces: 2)
            for member in ["Moi", "Thomas"] {
                exec(db, "INSERT OR IGNORE INTO tricount_shares (id, entry_id, member_name, amount) VALUES (\(shareId), \(entryId), '\(member)', \(share));")
                shareId += 1
            }
        }
    }

    // MARK: - Budget

    private static func seedBudget(_ db: OpaquePointer) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let start = fmt.string(from: Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date())
        let now   = fmt.string(from: Date())

        // Budget envelopes (category_id matches sub-categories used in transactions)
        let envelopes: [(Int, String, Int?, Double, String)] = [
            (1, "Alimentation",    10,  500.0, "MONTHLY"),
            (2, "Restaurants",     11,  150.0, "MONTHLY"),
            (3, "Transport",       13,  200.0, "MONTHLY"),
            (4, "Logement",        14, 1100.0, "MONTHLY"),
            (5, "Loisirs",          5,  100.0, "MONTHLY"),
            (6, "Santé",           17,   80.0, "MONTHLY"),
            (7, "Shopping",         6,  150.0, "MONTHLY"),
            (8, "Épargne objectif",nil, 200.0, "MONTHLY"),
        ]
        for (id, name, catId, amount, period) in envelopes {
            let cat = catId.map { "\($0)" } ?? "NULL"
            exec(db, "INSERT OR IGNORE INTO budget_envelopes (id, name, category_id, amount, period, start_date, is_active) VALUES (\(id), '\(name)', \(cat), \(amount), '\(period)', '\(start)', 1);")
        }

        // Recurring patterns
        let patterns: [(Int, String, Double, Int?, Int?, String, Int)] = [
            (1, "Loyer",            -950.0,  14, 10, "MONTHLY", 1),
            (2, "Salaire",          2850.0,  22, nil,"MONTHLY", 28),
            (3, "Netflix",           -15.99, 21, 16, "MONTHLY", 15),
            (4, "Spotify",            -9.99, 21, 17, "MONTHLY", 15),
            (5, "Orange mobile",     -29.99, 15, 12, "MONTHLY", 5),
            (6, "EDF électricité",   -68.50, 16, 11, "MONTHLY", 8),
            (7, "Pass Navigo",        -86.40, 13, 9,  "MONTHLY", 1),
        ]
        for (id, name, avg, catId, payeeId, freq, anchor) in patterns {
            let cat = catId.map { "\($0)" } ?? "NULL"
            let payee = payeeId.map { "\($0)" } ?? "NULL"
            exec(db, "INSERT OR IGNORE INTO recurring_patterns (id, name, amount_avg, amount_tolerance, category_id, payee_id, frequency, anchor_day, is_active, is_manual, created_at, start_date) VALUES (\(id), '\(esc(name))', \(avg), 0.1, \(cat), \(payee), '\(freq)', \(anchor), 1, 1, '\(now)', '\(start)');")
        }

        // Budget previsions (next 3 months)
        let cal = Calendar.current; let fmtP = fmt
        var prevId = 1
        for monthOffset in 0...2 {
            guard let futureMonth = cal.date(byAdding: .month, value: monthOffset, to: Date()) else { continue }
            for (patId, _, amount, _, _, _, anchor) in patterns {
                var comps = cal.dateComponents([.year, .month], from: futureMonth)
                comps.day = anchor
                guard let expDate = cal.date(from: comps) else { continue }
                let dateStr = fmtP.string(from: expDate)
                exec(db, "INSERT OR IGNORE INTO budget_previsions (id, recurring_pattern_id, amount, expected_date, status) VALUES (\(prevId), \(patId), \(amount), '\(dateStr)', 'PENDING');")
                prevId += 1
            }
        }
    }

    // MARK: - Patrimoine

    /// Seed du module Patrimoine — démontre les 3 catégories (assets liés/manuels,
    /// immobilier, prêts) ainsi que les 5 types de prêts pour que l'user voie
    /// immédiatement à quoi ressemble chaque cas.
    private static func seedPatrimoine(_ db: OpaquePointer) {
        let createdAt = "datetime('now')"

        // ── Assets ──────────────────────────────────────────────────
        // Mix de liens vers les comptes seedés (Livret A = account id 2, PEA = invest 1)
        // + cash manuel pour montrer le mode standalone.
        //   Livret A → lié au compte EPARGNE id=2 (solde résolu dynamiquement par VM)
        //   PEA → lié au compte invest id=1
        //   Cash → manuel
        //   Or physique → manuel (cas "actif divers" pas couvert par les comptes)
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_assets
            (name, asset_kind, linked_account_id, linked_investment_account_id,
             manual_value, last_known_value, notes, created_at)
        VALUES
            ('Livret A',         'SAVINGS',    2,    NULL, 0,     8245,  NULL, \(createdAt)),
            ('PEA Boursorama',   'INVESTMENT', NULL, 1,    0,     22420, NULL, \(createdAt)),
            ('Espèces',          'CASH',       NULL, NULL, 350,   350,   'Cash à la maison', \(createdAt)),
            ('Lingot d''or 50g', 'OTHER',      NULL, NULL, 3850,  3850,  'Acheté en 2020', \(createdAt));
        """)

        // ── Biens immobiliers ───────────────────────────────────────
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_real_estate
            (name, purchase_price, purchase_date, current_value, estimated_at, address, notes, created_at)
        VALUES
            ('Appartement Paris 11e', 285000, '2018-10-15', 345000, '2026-01-15', '12 rue de la Roquette\n75011 Paris', NULL, \(createdAt)),
            ('Résidence secondaire Bretagne', 165000, '2022-06-01', 175000, NULL, 'Lieu-dit Kerverhuel\n29170 Fouesnant', 'Maison 4 pièces, jardin 600 m²', \(createdAt));
        """)

        // ── Prêts ───────────────────────────────────────────────────
        // 4 prêts pour démontrer 4 types différents :
        //   1) Amortissable classique sur l'appart Paris (le plus fréquent)
        //   2) In fine sur la Bretagne
        //   3) Différé partiel (étudiant typique)
        //   4) Revolving (réserve d'argent)
        // Pas de DEFERRED_TOTAL en seed — moins courant et déjà couvert par
        // DEFERRED_PARTIAL en démonstration de la logique de différé.

        // Prêt 1 : amortissable, 230 000€ sur 25 ans à 1.85%, démarré nov 2018, assurance 38€/mois
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt immo Paris', 'AMORT', 230000, 0.0185, 300, 0, '2018-11-01', 1, NULL, \(createdAt), 38.50);
        """)

        // Prêt 2 : in fine 120 000€ sur 15 ans à 2.30%, démarré juin 2022, assurance 28€/mois
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt in fine Bretagne', 'IN_FINE', 120000, 0.0230, 180, 0, '2022-06-01', 2, 'Adossé à une assurance-vie qui garantit le remboursement final', \(createdAt), 28.00);
        """)

        // Prêt 3 : différé partiel étudiant, 25 000€ sur 8 ans à 1.20%, différé 24 mois,
        // démarré sept 2020 (a fini son différé, est maintenant en amortissement).
        // Pas d'assurance sur les prêts étudiants typiquement.
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt étudiant', 'DEFERRED_PARTIAL', 25000, 0.0120, 96, 24, '2020-09-01', NULL, 'Différé partiel pendant la dernière année d''école', \(createdAt), 0);
        """)

        // Prêt 4 : revolving (carte renouvelable), capital restant saisi manuellement.
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Réserve carte gold', 'REVOLVING', 1200, 0.1995, 0, 0, '2024-01-15', NULL, 'À rembourser dès que possible (taux élevé)', \(createdAt), 0);
        """)

        seedGoals(db)
    }

    /// Seed des objectifs financiers (table `goals`, migration v39). 4 goals
    /// couvrant les 4 types pour démontrer chaque mode de calcul :
    ///   - SAVINGS  → fonds d'urgence (cible 6000 €)
    ///   - NETWORTH → patrimoine de 500k€
    ///   - DEBT_PAYOFF → rembourser toutes les dettes
    ///   - CUSTOM → cagnotte voyage (saisie manuelle)
    private static func seedGoals(_ db: OpaquePointer) {
        let createdAt = "datetime('now')"
        exec(db, """
        INSERT OR IGNORE INTO goals (name, kind, target_amount, deadline_date, custom_current_amount, notes, created_at)
        VALUES
            ('Fonds d''urgence', 'SAVINGS', 6000, '2026-12-31', 0, '3 mois de dépenses (~2000 €/mois)', \(createdAt)),
            ('Apport immobilier', 'SAVINGS', 25000, '2028-06-30', 0, 'Pour un futur achat', \(createdAt)),
            ('Indépendance financière', 'NETWORTH', 500000, NULL, 0, 'Objectif long terme — pas de deadline', \(createdAt)),
            ('Zéro dette', 'DEBT_PAYOFF', 0, '2030-12-31', 0, 'Rembourser tous les prêts en cours', \(createdAt)),
            ('Voyage Japon 2027', 'CUSTOM', 4500, '2027-04-01', 1200, 'Cagnotte déjà entamée', \(createdAt));
        """)
    }

    /// Variante de `seedPatrimoine` pour la branche "DB existante" : aucun lien
    /// hardcodé vers accounts/investment_accounts (leurs IDs sont inconnus dans
    /// une DB déjà peuplée par l'user). Tous les actifs sont en mode standalone
    /// (valeur manuelle). L'user peut ensuite les relier via le form si besoin.
    private static func seedPatrimoineStandalone(_ db: OpaquePointer) {
        let createdAt = "datetime('now')"

        // ── Assets (tous en manuel) ─────────────────────────────────
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_assets
            (name, asset_kind, linked_account_id, linked_investment_account_id,
             manual_value, last_known_value, notes, created_at)
        VALUES
            ('Livret A',          'SAVINGS',    NULL, NULL, 8245,  8245,  NULL, \(createdAt)),
            ('PEA Boursorama',    'INVESTMENT', NULL, NULL, 22420, 22420, NULL, \(createdAt)),
            ('Espèces',           'CASH',       NULL, NULL, 350,   350,   'Cash à la maison', \(createdAt)),
            ('Lingot d''or 50g',  'OTHER',      NULL, NULL, 3850,  3850,  'Acheté en 2020', \(createdAt));
        """)

        // ── Biens immobiliers (idem que seedPatrimoine, pas de FK risquée) ──
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_real_estate
            (name, purchase_price, purchase_date, current_value, estimated_at, address, notes, created_at)
        VALUES
            ('Appartement Paris 11e', 285000, '2018-10-15', 345000, '2026-01-15', '12 rue de la Roquette\n75011 Paris', NULL, \(createdAt)),
            ('Résidence secondaire Bretagne', 165000, '2022-06-01', 175000, NULL, 'Lieu-dit Kerverhuel\n29170 Fouesnant', 'Maison 4 pièces, jardin 600 m²', \(createdAt));
        """)

        // ── Prêts (linked_real_estate_id reste valide ici car on vient juste
        //   d'insérer les real_estate au-dessus dans la même transaction —
        //   leurs IDs auto-incrémentés dépendent de l'historique de la DB user,
        //   donc on les retrouve par sous-requête sur le nom) ───────────────
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt immo Paris', 'AMORT', 230000, 0.0185, 300, 0, '2018-11-01',
             (SELECT id FROM patrimoine_real_estate WHERE name = 'Appartement Paris 11e' LIMIT 1),
             NULL, \(createdAt), 38.50);
        """)
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt in fine Bretagne', 'IN_FINE', 120000, 0.0230, 180, 0, '2022-06-01',
             (SELECT id FROM patrimoine_real_estate WHERE name = 'Résidence secondaire Bretagne' LIMIT 1),
             'Adossé à une assurance-vie qui garantit le remboursement final', \(createdAt), 28.00);
        """)
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Prêt étudiant', 'DEFERRED_PARTIAL', 25000, 0.0120, 96, 24, '2020-09-01',
             NULL, 'Différé partiel pendant la dernière année d''école', \(createdAt), 0);
        """)
        exec(db, """
        INSERT OR IGNORE INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months, deferral_months,
             start_date, linked_real_estate_id, notes, created_at, insurance_monthly)
        VALUES
            ('Réserve carte gold', 'REVOLVING', 1200, 0.1995, 0, 0, '2024-01-15',
             NULL, 'À rembourser dès que possible (taux élevé)', \(createdAt), 0);
        """)

        seedGoals(db)
    }

    // MARK: - Helpers

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        // 10^places via boucle simple (places est petit, <10 typiquement).
        var d: Double = 1
        for _ in 0..<places { d *= 10 }
        return (self * d).rounded() / d
    }
}

#endif
