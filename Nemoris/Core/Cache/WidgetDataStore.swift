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
    var excludedFromAggregates: Bool = false

    init(id: Int, name: String, type: String, monthExpense: Double, monthIncome: Double,
         netBalance: Double, monthlyHistory: [MonthSummary], excludedFromAggregates: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.monthExpense = monthExpense
        self.monthIncome = monthIncome
        self.netBalance = netBalance
        self.monthlyHistory = monthlyHistory
        self.excludedFromAggregates = excludedFromAggregates
    }

    // A manual decode: the synthesized one would fail (missing key) on an App
    // Group cache written by an earlier app version — the widget would reload
    // to an empty/placeholder state until the app's next refresh. v51 adds
    // this field; `decodeIfPresent` falls an old entry back to `false`
    // (not excluded), its behavior before this version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        monthExpense = try c.decode(Double.self, forKey: .monthExpense)
        monthIncome = try c.decode(Double.self, forKey: .monthIncome)
        netBalance = try c.decode(Double.self, forKey: .netBalance)
        monthlyHistory = try c.decode([MonthSummary].self, forKey: .monthlyHistory)
        excludedFromAggregates = try c.decodeIfPresent(Bool.self, forKey: .excludedFromAggregates) ?? false
    }
}

struct AllAccountsData: Codable {
    let accounts: [AccountWidgetData]
    let updatedAt: Date

    var combined: AccountWidgetData {
        // An "other" account keeps its own entry (individually selectable
        // in the widget) but doesn't enter "All accounts".
        let accounts = self.accounts.filter { !$0.excludedFromAggregates }
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

/// A portfolio's variation (abs + %) over a given range, computed with the
/// SAME engine as the in-app chart (`PortfolioEvolutionBuilder` + `InvestmentHeroCard`,
/// see `WidgetDataStore.refreshInvestments`) — never a second gain calculation.
struct InvestmentRangeSnapshot: Codable {
    let pnlAbsolute: Double
    let pnlPercent: Double
}

/// Keys of the `InvestmentsWidgetData.rangePnl` dictionary. Shared with the
/// widget extension's mirror (`AppIntent.swift`) by their raw VALUE
/// ("1D"/"1W"/"1M"), not a shared type — the two targets don't share
/// a Swift module.
enum InvestmentWidgetRangeKey {
    static let oneDay   = "1J"
    static let oneWeek  = "1S"
    static let oneMonth = "1M"
}

struct InvestmentsWidgetData: Codable {
    let totalValue: Double
    /// The TOTAL unrealized gain since purchase (acquisition cost vs. the
    /// current value) — kept as the default/fallback display value
    /// when the range selected in the widget has no price history.
    let pnlAbsolute: Double
    let pnlPercent: Double
    let accountCount: Int
    let updatedAt: Date
    /// The 1D/1W/1M variation (`InvestmentWidgetRangeKey` keys). A range with
    /// no usable price history is absent from the dictionary rather than
    /// present with a misleading zero.
    var rangePnl: [String: InvestmentRangeSnapshot] = [:]

    var hasData: Bool { accountCount > 0 }

    func pnl(forRangeKey key: String) -> InvestmentRangeSnapshot? { rangePnl[key] }

    static let empty = InvestmentsWidgetData(totalValue: 0, pnlAbsolute: 0, pnlPercent: 0, accountCount: 0, updatedAt: Date())
    static let placeholder = InvestmentsWidgetData(
        totalValue: 18_450, pnlAbsolute: 1_230, pnlPercent: 7.1, accountCount: 2, updatedAt: Date(),
        rangePnl: [
            InvestmentWidgetRangeKey.oneDay:   InvestmentRangeSnapshot(pnlAbsolute: 42, pnlPercent: 0.2),
            InvestmentWidgetRangeKey.oneWeek:  InvestmentRangeSnapshot(pnlAbsolute: 210, pnlPercent: 1.1),
            InvestmentWidgetRangeKey.oneMonth: InvestmentRangeSnapshot(pnlAbsolute: 640, pnlPercent: 3.6),
        ]
    )
}

struct PatrimoineWidgetData: Codable {
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let itemsCount: Int
    let updatedAt: Date

    var hasData: Bool { itemsCount > 0 }

    static let empty = PatrimoineWidgetData(netWorth: 0, totalAssets: 0, totalLiabilities: 0, itemsCount: 0, updatedAt: Date())
    static let placeholder = PatrimoineWidgetData(netWorth: 182_400, totalAssets: 214_000, totalLiabilities: 31_600, itemsCount: 5, updatedAt: Date())
}

struct TricountGroupWidgetItem: Codable {
    let id: Int
    let title: String
    let currency: String
    /// Positive = the group owes me; negative = I owe the group.
    let netBalance: Double
}

struct TricountWidgetData: Codable {
    let groups: [TricountGroupWidgetItem]
    let updatedAt: Date

    static let empty = TricountWidgetData(groups: [], updatedAt: Date())
    static let placeholder = TricountWidgetData(
        groups: [
            TricountGroupWidgetItem(id: 1, title: "Colocation", currency: "EUR", netBalance: 42.50),
            TricountGroupWidgetItem(id: 2, title: "Vacances Portugal", currency: "EUR", netBalance: -18.20),
        ],
        updatedAt: Date()
    )
}

// MARK: - WidgetDataStore

/// Bridges the main app's SQLite data to widget and shortcut extensions via a shared App Group.
enum WidgetDataStore {
    static let appGroupID     = "group.fr.hedwin.nemoris"
    static let snapshotKey    = "nemoris.widgetSnapshot"
    static let allAccountsKey = "nemoris.allAccountsData"
    static let budgetKey      = "nemoris.budgetWidgetData"
    static let investmentsKey = "nemoris.investmentsWidgetData"
    static let patrimoineKey  = "nemoris.patrimoineWidgetData"
    static let tricountKey    = "nemoris.tricountWidgetData"
    // (pendingCSVKey removed 2026-07-22 — a dead flow since the V3 import.
    //  Dropping a CSV now goes through PendingImportInbox kind .transactions.)

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Public API

    /// Query the DB and push fresh snapshots for all accounts to the shared container.
    /// Call from a background task — performs synchronous SQLite reads, and hops onto
    /// `@MainActor` internally for `refreshInvestments()` (the price cache is).
    static func refresh(preferredAccountId: Int? = nil) async {
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
            // An "other" account keeps its individual entry (`accountDataList`,
            // selectable in the widget) but its transactions do NOT enter
            // `allTxns` — the source for the aggregated budget below.
            if !account.excludedFromAggregates {
                allTxns.append(contentsOf: txns)
            }
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
                monthlyHistory: fetchHistory(accountId: account.id),
                excludedFromAggregates: account.excludedFromAggregates
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
        await refreshInvestments()
        refreshPatrimoine()
        refreshTricount()
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

    // MARK: - Investments

    /// Reuses `InvestmentsRecap`, already shared with the Dashboard — the same
    /// figure as the module, never a diverging calculation on top.
    ///
    /// The widget can also show the 1D/1W/1M variation (chosen by
    /// the user via "Edit Widget"): computed with the SAME engine
    /// as the in-app `InvestmentHeroCard` — `PortfolioEvolutionBuilder` + positions'
    /// current value as the basis, never a second gain calculation
    /// (the doctrine against diverging calculations).
    @MainActor
    private static func refreshInvestments() async {
        let repository = InvestmentRepository()
        let accounts = repository.fetchAccounts()
        let recap = InvestmentsRecap.from(accounts: accounts)
        let allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }

        var rangePnl: [String: InvestmentRangeSnapshot] = [:]
        if !allPositions.isEmpty {
            for (key, range) in [
                (InvestmentWidgetRangeKey.oneDay, InvestmentTimeRange.oneDay),
                (InvestmentWidgetRangeKey.oneWeek, InvestmentTimeRange.oneWeek),
                (InvestmentWidgetRangeKey.oneMonth, InvestmentTimeRange.oneMonth),
            ] {
                // The same guard as the in-app hero card: on 1D with NO
                // intraday quote at all, don't fabricate a curve from
                // daily closes — the range simply stays absent from the dict.
                if range == .oneDay,
                   allPositions.allSatisfy({ PositionHistoryResolver.intradaySeries(for: $0).isEmpty }) {
                    continue
                }
                let inputs = allPositions.map { position in
                    PortfolioSeriesInput(
                        positionId: position.id,
                        quantity: position.quantity,
                        history: PositionHistoryResolver.seriesHistory(for: position, range: range)
                    )
                }
                let result = PortfolioEvolutionBuilder.build(inputs: inputs, range: range)
                guard let start = result.points.first, start.value != 0 else { continue }
                // ⚠️ The comparison basis is restricted to positions ACTUALLY
                // priced by the builder (the same positions as `start.value`,
                // via `pricedPositionIds`) — a position with no history for
                // this range (e.g. 1D with no intraday quote while
                // other positions have one) used to be counted in the
                // current value but absent from the starting point, artificially
                // inflating the % (the same bug already fixed on the
                // in-app `InvestmentHeroCard` side via `variationBasisValue`).
                let currentPricedValue = allPositions
                    .filter { result.pricedPositionIds.contains($0.id) }
                    .reduce(0.0) { $0 + $1.currentValue }
                let delta = currentPricedValue - start.value
                rangePnl[key] = InvestmentRangeSnapshot(
                    pnlAbsolute: delta,
                    pnlPercent: delta / start.value * 100
                )
            }
        }

        let data = InvestmentsWidgetData(
            totalValue: recap.totalCurrentValue,
            pnlAbsolute: recap.pnlAbsolute,
            pnlPercent: recap.pnlPercent,
            accountCount: recap.activeAccountCount,
            updatedAt: Date(),
            rangePnl: rangePnl
        )
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: investmentsKey)
    }

    // MARK: - Patrimoine

    /// Reuses `PatrimoineSnapshotBuilder`, the same pure engine as the Dashboard and
    /// `PatrimoineViewModel` — not a 4th net-worth calculation.
    private static func refreshPatrimoine() {
        let patrimoineRepo = PatrimoineRepository()
        let assets = patrimoineRepo.fetchAssets()
        let realEstates = patrimoineRepo.fetchRealEstate()
        let loans = patrimoineRepo.fetchLoans()

        guard !assets.isEmpty || !realEstates.isEmpty || !loans.isEmpty else {
            guard let defaults = UserDefaults(suiteName: appGroupID),
                  let encoded = try? JSONEncoder().encode(PatrimoineWidgetData.empty) else { return }
            defaults.set(encoded, forKey: patrimoineKey)
            return
        }

        let txRepo = TransactionRepository()
        let bankAccounts = txRepo.fetchAccounts()
        let investmentAccounts = InvestmentRepository().fetchAccounts()
        let existingBankIds = Set(bankAccounts.map(\.id))

        var bankBalances: [Int: Double] = [:]
        for id in PatrimoineSnapshotBuilder.linkedBankAccountIds(in: assets) where existingBankIds.contains(id) {
            bankBalances[id] = txRepo.fetchAccountBalance(accountId: id, upToDate: nil)
        }

        let (values, _) = PatrimoineSnapshotBuilder.resolveValues(
            assets: assets,
            existingBankAccountIds: existingBankIds,
            bankBalances: bankBalances,
            investmentAccounts: investmentAccounts
        )
        var loanStates: [Int: LoanState] = [:]
        for loan in loans { loanStates[loan.id] = LoanCalculator.compute(loan: loan) }

        let snapshot = PatrimoineSnapshotBuilder.snapshot(
            assets: assets,
            realEstates: realEstates,
            loans: loans,
            resolvedValues: values,
            loanStates: loanStates
        )
        let data = PatrimoineWidgetData(
            netWorth: snapshot.netWorth,
            totalAssets: snapshot.totalAssets,
            totalLiabilities: snapshot.totalLiabilities,
            itemsCount: snapshot.itemsCount,
            updatedAt: Date()
        )
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: patrimoineKey)
    }

    // MARK: - Tricount

    /// Reuses `TricountRepository.computeBalances` (the same logic as
    /// `TricountDetailView`) — a group's net balance is the sum of individual
    /// balances (`theyOwe - iOwe`), positive = the group owes me.
    private static func refreshTricount() {
        let repo = TricountRepository()
        let groups = repo.fetchGroups()
        var items: [TricountGroupWidgetItem] = []
        for group in groups {
            let entries = repo.fetchEntries(groupId: group.id)
            let shares = repo.fetchShares(groupId: group.id)
            let balances = repo.computeBalances(entries: entries, shares: shares, myName: group.myName)
            let net = balances.reduce(0.0) { $0 + $1.net }
            items.append(TricountGroupWidgetItem(id: group.id, title: group.title, currency: group.currency, netBalance: net))
        }
        let data = TricountWidgetData(groups: items, updatedAt: Date())
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: tricountKey)
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

        // The engine shared with the app — until now the widget showed
        // amounts different from the Dashboard's (it ignored sub-categories).
        // ⚠️ The encoded `BudgetWidgetData` shape doesn't change: it's the contract
        // the widget extension decodes via the App Group.
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
