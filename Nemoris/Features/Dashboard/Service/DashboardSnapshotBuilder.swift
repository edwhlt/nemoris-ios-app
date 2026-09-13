import Foundation

// MARK: - DashboardSnapshotBuilder
//
// Assembles a `DashboardSnapshot` from the database. This is the layer that READS;
// the computations themselves are delegated to the pure engines shared with the
// modules' own screens (`EnvelopeSpendingCalculator`, `PatrimoineSnapshotBuilder`, `AlertEngine`,
// `InsightEngine`), so the Dashboard can no longer diverge from them.
//
// **Everything is `nonisolated`**: this code runs in a `Task.detached`, never on the
// main thread. It's safe because the repositories are stateless `struct`s and
// each method opens its own SQLite connection (no shared connection).
// Before, `AnnualDashboardViewModel.load()` was entirely synchronous on the main
// thread: ~15 queries, one of them a 180-day scan that could reach 10,000 rows.

enum DashboardSnapshotBuilder {

    /// Raw data for one pass. Each field is filled in **at most once**.
    private struct Sources {
        var yearMonthly: [MonthlyTotals] = []
        var previousYearMonthly: [MonthlyTotals] = []
        var categoryTotals: [CategoryTotal] = []
        var tagTotals: [TagTotal] = []
        var activeEnvelopes: [BudgetEnvelope] = []
        var monthTransactions: [FinanceTransaction] = []
        var categories: [Category] = []
        var investmentAccounts: [InvestmentAccount] = []
        var bankAccounts: [Account] = []
        var bankBalances: [Int: Double] = [:]
        var assets: [PatrimoineAsset] = []
        var realEstates: [PatrimoineRealEstate] = []
        var loans: [PatrimoineLoan] = []
        var goals: [Goal] = []
    }

    /// Computes the requested aggregates. Dependencies between aggregates are assumed
    /// to already be resolved by `DashboardAggregate.expanded(_:)` on the caller's side.
    /// `store` defaults to the app's database:
    /// no call site needs to change. Tests inject a temporary database.
    nonisolated static func build(units: Set<DashboardAggregate>, period: DashboardPeriod,
                                  store: SQLiteStore = SQLiteStore()) -> DashboardSnapshot {
        guard !units.isEmpty else { return DashboardSnapshot() }

        let needed = units.reduce(into: Set<DashboardSource>()) { $0.formUnion($1.sources) }
        let sources = fetchSources(needed, period: period, store: store)

        var snapshot = DashboardSnapshot()
        for unit in DashboardAggregate.evaluationOrder where units.contains(unit) {
            apply(unit, sources: sources, store: store, into: &snapshot)
        }
        return snapshot
    }

    // MARK: - Reading

    private nonisolated static func fetchSources(_ needed: Set<DashboardSource>, period: DashboardPeriod,
                                                 store: SQLiteStore) -> Sources {
        var s = Sources()
        let transactions = TransactionRepository(store: store)

        if needed.contains(.yearMonthlyTotals) {
            s.yearMonthly = transactions.fetchMonthlyTotals(from: period.yearFrom, to: period.yearTo)
        }
        if needed.contains(.previousYearMonthlyTotals),
           let from = period.previousYearFrom, let to = period.previousYearTo {
            s.previousYearMonthly = transactions.fetchMonthlyTotals(from: from, to: to)
        }
        if needed.contains(.categoryTotals) {
            s.categoryTotals = transactions.fetchCategoryTotals(from: period.filterFrom, to: period.filterTo)
        }
        if needed.contains(.tagTotals) {
            s.tagTotals = transactions.fetchTagTotals(from: period.filterFrom, to: period.filterTo)
        }

        if needed.contains(.activeEnvelopes) {
            s.activeEnvelopes = BudgetRepository.shared.fetchEnvelopes().filter { $0.isActive }
        }
        // With no active envelope, nobody needs the month's transactions or the
        // category reference data: a pointless 5000-row load is avoided.
        if !s.activeEnvelopes.isEmpty {
            if needed.contains(.monthTransactions) {
                s.monthTransactions = fetchCurrentMonthTransactions(using: transactions)
            }
            if needed.contains(.categories) {
                s.categories = transactions.fetchCategories()
            }
        }

        if needed.contains(.investmentAccounts) {
            s.investmentAccounts = InvestmentRepository(store: store).fetchAccounts()
        }
        if needed.contains(.bankAccounts) {
            s.bankAccounts = transactions.fetchAccounts()
        }

        let patrimoine = PatrimoineRepository(store: store)
        if needed.contains(.patrimoineAssets)     { s.assets = patrimoine.fetchAssets() }
        if needed.contains(.patrimoineRealEstate) { s.realEstates = patrimoine.fetchRealEstate() }
        if needed.contains(.patrimoineLoans)      { s.loans = patrimoine.fetchLoans() }

        // Derived: after assets + bankAccounts. A `fetchAccountBalance` is a SUM
        // over the whole transactions table → only for the accounts actually
        // linked to an asset, and that still exist.
        if needed.contains(.bankBalances), !s.assets.isEmpty {
            let existing = Set(s.bankAccounts.map(\.id))
            for id in PatrimoineSnapshotBuilder.linkedBankAccountIds(in: s.assets) where existing.contains(id) {
                s.bankBalances[id] = transactions.fetchAccountBalance(accountId: id, upToDate: nil)
            }
        }

        if needed.contains(.goals) {
            s.goals = GoalRepository(store: store).fetchGoals()
        }
        return s
    }

    /// This month's transactions (the 1st of the month → now), all accounts.
    private nonisolated static func fetchCurrentMonthTransactions(
        using repository: TransactionRepository
    ) -> [FinanceTransaction] {
        let calendar = Calendar.current
        let now = Date()
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else {
            return []
        }
        return repository.fetchTransactionsAllAccounts(from: monthStart, to: now, limit: 5000, offset: 0)
    }

    // MARK: - Computation

    private nonisolated static func apply(
        _ unit: DashboardAggregate,
        sources: Sources,
        store: SQLiteStore,
        into snapshot: inout DashboardSnapshot
    ) {
        switch unit {
        case .yearSeries:
            snapshot.monthlySeries = sources.yearMonthly
            snapshot.stats = totals(from: sources.yearMonthly)
            snapshot.previousYearStats = sources.previousYearMonthly.isEmpty
                ? .empty
                : totals(from: sources.previousYearMonthly)

        case .categoryBreakdown:
            snapshot.categoryTotals = sources.categoryTotals

        case .tagBreakdown:
            snapshot.tagTotals = sources.tagTotals

        case .budgetEnvelopes:
            let progresses = EnvelopeSpendingCalculator.progresses(
                envelopes: sources.activeEnvelopes,
                transactions: sources.monthTransactions,
                categories: sources.categories
            )
            snapshot.envelopeProgresses = progresses
            snapshot.budget = BudgetRecap.from(progresses)

        case .investments:
            snapshot.investments = InvestmentsRecap.from(accounts: sources.investmentAccounts)

        case .patrimoine:
            snapshot.patrimoine = patrimoineSnapshot(from: sources)

        case .alerts:
            snapshot.alerts = AlertEngine.compute(AlertContext(
                envelopeProgresses: snapshot.envelopeProgresses ?? [],
                goals: sources.goals,
                assets: sources.assets,
                bankAccountIds: Set(sources.bankAccounts.map(\.id)),
                investmentAccountIds: Set(sources.investmentAccounts.map(\.id))
            ))

        case .insights:
            snapshot.insights = InsightEngine.compute()

        case .pendingApplePay:
            let pending = PendingApplePayRepository(store: store).fetchEntries(status: .pending)
            snapshot.pendingApplePayCount = pending.count
            snapshot.pendingApplePayTotal = pending.reduce(0) { $0 + abs($1.amount) }
        }
    }

    private nonisolated static func totals(from monthly: [MonthlyTotals]) -> DashboardStats {
        DashboardStats(
            totalIncome: monthly.reduce(0) { $0 + $1.income },
            totalExpense: monthly.reduce(0) { $0 + $1.expense },
            transactionCount: 0
        )
    }

    private nonisolated static func patrimoineSnapshot(from sources: Sources) -> PatrimoineSnapshot {
        guard !sources.assets.isEmpty || !sources.realEstates.isEmpty || !sources.loans.isEmpty else {
            return .empty
        }
        let (values, _) = PatrimoineSnapshotBuilder.resolveValues(
            assets: sources.assets,
            existingBankAccountIds: Set(sources.bankAccounts.map(\.id)),
            bankBalances: sources.bankBalances,
            investmentAccounts: sources.investmentAccounts
        )
        var loanStates: [Int: LoanState] = [:]
        for loan in sources.loans { loanStates[loan.id] = LoanCalculator.compute(loan: loan) }

        return PatrimoineSnapshotBuilder.snapshot(
            assets: sources.assets,
            realEstates: sources.realEstates,
            loans: sources.loans,
            resolvedValues: values,
            loanStates: loanStates
        )
    }
}
