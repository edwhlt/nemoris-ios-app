import Foundation

// MARK: - DashboardSnapshotBuilder
//
// Assemble un `DashboardSnapshot` à partir de la base. C'est la couche qui LIT ;
// les calculs eux-mêmes sont délégués aux moteurs purs partagés avec les modules
// (`EnvelopeSpendingCalculator`, `PatrimoineSnapshotBuilder`, `AlertEngine`,
// `InsightEngine`), pour que le Dashboard ne puisse plus diverger de leurs écrans.
//
// **Tout est `nonisolated`** : ce code tourne dans un `Task.detached`, jamais sur le
// main thread. C'est sûr parce que les repositories sont des `struct` sans état et
// que chaque méthode ouvre sa propre connexion SQLite (aucune connexion partagée).
// Avant, `AnnualDashboardViewModel.load()` était intégralement synchrone sur le main
// thread : ~15 requêtes, dont un scan de 180 jours pouvant atteindre 10 000 lignes.

enum DashboardSnapshotBuilder {

    /// Données brutes d'une passe. Chaque champ est rempli **au plus une fois**.
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

    /// Calcule les agrégats demandés. Les dépendances entre agrégats sont supposées
    /// déjà résolues par `DashboardAggregate.expanded(_:)` côté appelant.
    /// `store` a une valeur par défaut visant la base de l'application :
    /// aucun site d'appel ne change. Les tests injectent une base temporaire.
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

    // MARK: - Lecture

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
        // Sans enveloppe active, personne n'a besoin des transactions du mois ni du
        // référentiel catégories : on évite un chargement de 5000 lignes pour rien.
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

        // Dérivée : après assets + bankAccounts. Un `fetchAccountBalance` est un SUM
        // sur toute la table transactions → uniquement pour les comptes réellement
        // liés à un asset, et qui existent encore.
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

    /// Transactions du mois en cours (1er du mois → maintenant), tous comptes.
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

    // MARK: - Calcul

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
