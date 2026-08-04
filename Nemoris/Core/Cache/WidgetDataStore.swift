import Foundation
import SQLite3
import WidgetKit

// MARK: - Models

struct MonthSummary: Codable, Identifiable {
    let month: String   // "2026-05"
    let expense: Double
    let income: Double

    var id: String { month }

    var shortMonth: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        let symbols = ["Jan","Fév","Mar","Avr","Mai","Jun","Jul","Aoû","Sep","Oct","Nov","Déc"]
        return m >= 1 && m <= 12 ? symbols[m - 1] : month
    }
}

struct WidgetSnapshot: Codable {
    let monthExpense: Double
    let monthIncome: Double
    let netBalance: Double
    let accountName: String
    let monthlyHistory: [MonthSummary]
    let updatedAt: Date

    static let placeholder = WidgetSnapshot(
        monthExpense: 1_234.56,
        monthIncome: 2_500.00,
        netBalance: 1_265.44,
        accountName: "Compte courant",
        monthlyHistory: [
            MonthSummary(month: "2025-12", expense: 1100, income: 2200),
            MonthSummary(month: "2026-01", expense:  980, income: 2100),
            MonthSummary(month: "2026-02", expense: 1340, income: 2400),
            MonthSummary(month: "2026-03", expense:  890, income: 2050),
            MonthSummary(month: "2026-04", expense: 1567, income: 2600),
            MonthSummary(month: "2026-05", expense: 1234, income: 2500),
        ],
        updatedAt: Date()
    )
}

struct AccountWidgetData: Codable {
    let id: Int
    let name: String
    let type: String
    let monthExpense: Double
    let monthIncome: Double
    let netBalance: Double
    let monthlyHistory: [MonthSummary]
}

struct AllAccountsData: Codable {
    let accounts: [AccountWidgetData]
    let updatedAt: Date

    var combined: AccountWidgetData {
        let totalExpense = accounts.reduce(0) { $0 + $1.monthExpense }
        let totalIncome  = accounts.reduce(0) { $0 + $1.monthIncome }
        let allMonths = Dictionary(grouping: accounts.flatMap(\.monthlyHistory), by: \.month)
        let history = allMonths.map { month, entries in
            MonthSummary(
                month: month,
                expense: entries.reduce(0) { $0 + $1.expense },
                income:  entries.reduce(0) { $0 + $1.income }
            )
        }.sorted { $0.month < $1.month }
        return AccountWidgetData(
            id: -1, name: "Tous les comptes", type: "ALL",
            monthExpense: totalExpense, monthIncome: totalIncome,
            netBalance: totalIncome - totalExpense,
            monthlyHistory: history
        )
    }
}

struct BudgetWidgetData: Codable {
    let forecastedExpenses: Double
    let actualExpenses: Double
    let variance: Double
    let envelopes: [EnvelopeWidgetItem]
    let updatedAt: Date

    var isOverBudget: Bool { variance > 0 }

    static let placeholder = BudgetWidgetData(
        forecastedExpenses: 2_000, actualExpenses: 1_234, variance: -766,
        envelopes: [
            EnvelopeWidgetItem(name: "Alimentation", spent: 450, allocated: 600),
            EnvelopeWidgetItem(name: "Loisirs", spent: 220, allocated: 200),
        ],
        updatedAt: Date()
    )
}

struct EnvelopeWidgetItem: Codable {
    let name: String
    let spent: Double
    let allocated: Double
    var ratio: Double { allocated > 0 ? min(spent / allocated, 1.0) : 0 }
    var isOver: Bool { spent > allocated }
}

// MARK: - WidgetDataStore

/// Bridges the main app's SQLite data to widget and shortcut extensions via a shared App Group.
enum WidgetDataStore {
    static let appGroupID     = "group.fr.hedwin.nemoris"
    static let snapshotKey    = "nemoris.widgetSnapshot"
    static let allAccountsKey = "nemoris.allAccountsData"
    static let budgetKey      = "nemoris.budgetWidgetData"
    // (pendingCSVKey supprimée 2026-07-22 — flux mort depuis l'import V3.
    //  Le dépôt de CSV passe par PendingImportInbox kind .transactions.)

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Public API

    /// Query the DB and push fresh snapshots for all accounts to the shared container.
    /// Call on a background thread — performs synchronous SQLite reads.
    static func refresh(preferredAccountId: Int? = nil) {
        let repo = TransactionRepository()
        let accounts = repo.fetchAccounts()
        guard !accounts.isEmpty else { return }

        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        // Build per-account data
        var accountDataList: [AccountWidgetData] = []
        var allTxns: [FinanceTransaction] = []
        for account in accounts {
            let txns = repo.fetchTransactions(accountId: account.id, from: monthStart, to: now, limit: 100_000)
            allTxns.append(contentsOf: txns)
            var expense = 0.0
            var income  = 0.0
            for tx in txns {
                if tx.amount < 0 { expense += abs(tx.amount) }
                else if tx.amount > 0 { income += tx.amount }
            }
            accountDataList.append(AccountWidgetData(
                id: account.id,
                name: account.name,
                type: account.type,
                monthExpense: expense,
                monthIncome: income,
                netBalance: income - expense,
                monthlyHistory: fetchHistory(accountId: account.id)
            ))
        }

        let allData = AllAccountsData(accounts: accountDataList, updatedAt: now)

        // Also write legacy WidgetSnapshot for backward-compat (uses preferred/first account)
        let preferred: AccountWidgetData
        if let id = preferredAccountId, let found = accountDataList.first(where: { $0.id == id }) {
            preferred = found
        } else {
            preferred = accountDataList[0]
        }
        let snapshot = WidgetSnapshot(
            monthExpense: preferred.monthExpense,
            monthIncome: preferred.monthIncome,
            netBalance: preferred.netBalance,
            accountName: preferred.name,
            monthlyHistory: preferred.monthlyHistory,
            updatedAt: now
        )

        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(allData) {
            defaults.set(data, forKey: allAccountsKey)
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
        refreshBudget(allTxns: allTxns)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Read the last written snapshot. Returns the placeholder if no data yet.
    static func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .placeholder
        }
        return snapshot
    }

    /// Read all accounts data. Returns a placeholder if no data yet.
    static func loadAll() -> AllAccountsData {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: allAccountsKey),
              let all = try? JSONDecoder().decode(AllAccountsData.self, from: data) else {
            return AllAccountsData(
                accounts: [AccountWidgetData(
                    id: 1, name: "Compte courant", type: "COURANT",
                    monthExpense: 1_234.56, monthIncome: 2_500.00, netBalance: 1_265.44,
                    monthlyHistory: [
                        MonthSummary(month: "2025-12", expense: 1100, income: 2200),
                        MonthSummary(month: "2026-01", expense:  980, income: 2100),
                        MonthSummary(month: "2026-02", expense: 1340, income: 2400),
                        MonthSummary(month: "2026-03", expense:  890, income: 2050),
                        MonthSummary(month: "2026-04", expense: 1567, income: 2600),
                        MonthSummary(month: "2026-05", expense: 1234, income: 2500),
                    ]
                )],
                updatedAt: Date()
            )
        }
        return all
    }

    /// Read the last budget snapshot. Returns a placeholder if no data yet.
    static func loadBudget() -> BudgetWidgetData {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: budgetKey),
              let budget = try? JSONDecoder().decode(BudgetWidgetData.self, from: data) else {
            return .placeholder
        }
        return budget
    }

    // MARK: - Budget

    private static func refreshBudget(allTxns: [FinanceTransaction]) {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let previsions = BudgetRepository.shared.fetchPrevisions(from: monthStart, to: now)
        let forecasted = previsions
            .filter { $0.amount < 0 && $0.status != .skipped }
            .reduce(0) { $0 + abs($1.amount) }

        let actual = allTxns.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }

        // Moteur partagé avec l'app — le widget affichait jusqu'ici des montants
        // différents de ceux du Dashboard (il ignorait les sous-catégories).
        // ⚠️ La forme encodée `BudgetWidgetData` ne bouge pas : c'est le contrat
        // décodé par l'extension widget via l'App Group.
        let envelopes = BudgetRepository.shared.fetchEnvelopes()
            .filter { $0.isActive && $0.categoryId != nil }
        let envelopeItems = EnvelopeSpendingCalculator.progresses(
            envelopes: Array(envelopes.prefix(4)),
            transactions: allTxns,
            categories: TransactionRepository().fetchCategories()
        ).map {
            EnvelopeWidgetItem(name: $0.envelope.name, spent: $0.spent, allocated: $0.allocated)
        }

        let budgetData = BudgetWidgetData(
            forecastedExpenses: forecasted,
            actualExpenses: actual,
            variance: actual - forecasted,
            envelopes: envelopeItems,
            updatedAt: now
        )
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(budgetData) else { return }
        defaults.set(data, forKey: budgetKey)
    }

    // MARK: - Private

    private static func fetchHistory(accountId: Int) -> [MonthSummary] {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return [] }

        var db: OpaquePointer?
        let url = DatabaseManager.shared.sqliteURL()
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let sixMonthsAgo = cal.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let sql = """
        SELECT strftime('%Y-%m', tx_date),
               SUM(CASE WHEN amount < 0 THEN ABS(amount) ELSE 0.0 END),
               SUM(CASE WHEN amount > 0 THEN amount ELSE 0.0 END)
        FROM transactions
        WHERE account_id = ? AND tx_date >= ?
        GROUP BY strftime('%Y-%m', tx_date)
        ORDER BY 1 ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(accountId))
        sqlite3_bind_text(stmt, 2, fmt.string(from: sixMonthsAgo), -1, SQLITE_TRANSIENT)

        var results: [MonthSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            results.append(MonthSummary(
                month: String(cString: cStr),
                expense: sqlite3_column_double(stmt, 1),
                income: sqlite3_column_double(stmt, 2)
            ))
        }
        return results
    }
}
