import Foundation
import Observation

// MARK: - Investments recap (dashboard hero bandeau)

/// Mini-récap patrimoine financier pour le bloc Investissements du Dashboard.
/// On ne stocke PAS l'historique mensuel ici — la sparkline reste en option
/// (calcul coûteux on-the-fly côté Investments) ; ici on vise zéro overhead.
struct InvestmentsRecap {
    let totalCurrentValue: Double
    let totalInvested: Double
    let activeAccountCount: Int

    var pnlAbsolute: Double { totalCurrentValue - totalInvested }
    var pnlPercent: Double {
        guard totalInvested > 0 else { return 0 }
        return (totalCurrentValue - totalInvested) / totalInvested * 100
    }
    var hasData: Bool { activeAccountCount > 0 }

    static let empty = InvestmentsRecap(totalCurrentValue: 0, totalInvested: 0, activeAccountCount: 0)
}

// MARK: - Patrimoine recap (dashboard hero bandeau)

/// Mini-récap patrimoine pour le bandeau Patrimoine du Dashboard. Symétrique
/// d'`InvestmentsRecap` côté Investissements. Calculé en mémoire à partir des
/// 3 collections Patrimoine (assets résolus + immobilier + capital restant dû
/// des prêts via `LoanCalculator`).
struct PatrimoineRecap {
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let itemsCount: Int

    var hasData: Bool { itemsCount > 0 }

    static let empty = PatrimoineRecap(netWorth: 0, totalAssets: 0, totalLiabilities: 0, itemsCount: 0)
}

// MARK: - Budget recap (état des enveloppes du mois)

/// État synthétique des enveloppes budgétaires sur le mois en cours.
/// Pour le bandeau Dashboard "X enveloppes sur la bonne voie · Y dépassées".
struct BudgetRecap {
    /// Nombre total d'enveloppes actives.
    let totalCount: Int
    /// Enveloppes dont la dépense du mois est < 80 % du budget (vert).
    let healthyCount: Int
    /// Enveloppes entre 80 % et 100 % (ambre — attention).
    let warningCount: Int
    /// Enveloppes au-delà de 100 % (rouge — dépassées).
    let exceededCount: Int

    var hasData: Bool { totalCount > 0 }
    var hasIssue: Bool { warningCount > 0 || exceededCount > 0 }

    static let empty = BudgetRecap(totalCount: 0, healthyCount: 0, warningCount: 0, exceededCount: 0)
}

@Observable
final class AnnualDashboardViewModel {

    // MARK: - State

    var selectedYear: Int = Calendar.current.component(.year, from: Date())

    var monthlyData: [MonthlyTotals] = []
    var categoryData: [CategoryTotal] = []
    var tagData: [TagTotal] = []
    var stats: DashboardStats = .empty
    /// Stats de l'année précédente — sert à montrer une **variation visuelle** dans le hero
    /// éditorial du Dashboard. Plus impactant qu'un simple chiffre brut.
    var previousYearStats: DashboardStats = .empty
    /// Récap patrimoine — somme courante + investie sur l'ensemble des comptes Investments.
    /// Calculé via `InvestmentRepository.fetchAccounts()` (1 seul SELECT GROUP BY).
    var investmentsRecap: InvestmentsRecap = .empty
    /// Récap patrimoine net (actifs liquides + immobilier − prêts). Calculé en mémoire
    /// à partir de `PatrimoineRepository` + `LoanCalculator`. Coût négligeable.
    var patrimoineRecap: PatrimoineRecap = .empty
    /// Récap enveloppes Budget — état du mois en cours (vert / ambre / rouge).
    /// Visible dans un bandeau Dashboard si l'user a au moins 1 enveloppe active.
    var budgetRecap: BudgetRecap = .empty
    /// Alertes intelligentes (goals en retard, enveloppes dépassées, liens rompus).
    /// Recalculées à chaque `load()` — pas de persistance, c'est volontaire.
    var alerts: [Alert] = []
    /// Insights générés par le `InsightEngine` (couches statistiques). Top 8.
    var insights: [Insight] = []
    var isLoading = false

    /// Selected month filter ("yyyy-MM"), nil = whole year
    var selectedMonth: String? = nil

    // MARK: - Private

    private let repository = TransactionRepository()
    private let investmentRepository = InvestmentRepository()
    private let patrimoineRepository = PatrimoineRepository()
    private let transactionRepository = TransactionRepository()

    // MARK: - Year range helpers

    var yearFrom: Date {
        Calendar.current.date(from: DateComponents(year: selectedYear, month: 1, day: 1)) ?? Date()
    }

    var yearTo: Date {
        Calendar.current.date(from: DateComponents(year: selectedYear, month: 12, day: 31)) ?? Date()
    }

    private var filterFrom: Date {
        guard let m = selectedMonth, let d = dashboardMonthParser.date(from: m) else { return yearFrom }
        return d
    }

    private var filterTo: Date {
        guard let m = selectedMonth, let d = dashboardMonthParser.date(from: m) else { return yearTo }
        let cal = Calendar.current
        return cal.date(byAdding: DateComponents(month: 1, day: -1), to: d) ?? d
    }

    var selectedMonthLabel: String? {
        guard let m = selectedMonth, let d = dashboardMonthParser.date(from: m) else { return nil }
        return d.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Public API

    func selectYear(_ year: Int) {
        selectedYear = year
        selectedMonth = nil
        load()
    }

    func load() {
        isLoading = true
        // Tous comptes confondus (accountId = nil), virements internes exclus
        monthlyData  = repository.fetchMonthlyTotals(from: yearFrom, to: yearTo)
        categoryData = repository.fetchCategoryTotals(from: filterFrom, to: filterTo)
        tagData      = repository.fetchTagTotals(from: filterFrom, to: filterTo)
        let income  = monthlyData.reduce(0) { $0 + $1.income }
        let expense = monthlyData.reduce(0) { $0 + $1.expense }
        stats = DashboardStats(totalIncome: income, totalExpense: expense, transactionCount: 0)

        // Variation vs N-1 : on rejoue le même calcul sur l'année précédente. 1 seul SELECT
        // SQLite (fetchMonthlyTotals) — coût négligeable, et ça donne au hero du Dashboard
        // un signal "rétrocompétitif" très lisible.
        let cal = Calendar.current
        if let prevFrom = cal.date(from: DateComponents(year: selectedYear - 1, month: 1, day: 1)),
           let prevTo   = cal.date(from: DateComponents(year: selectedYear - 1, month: 12, day: 31)) {
            let prevMonthly = repository.fetchMonthlyTotals(from: prevFrom, to: prevTo)
            let prevIncome  = prevMonthly.reduce(0) { $0 + $1.income }
            let prevExpense = prevMonthly.reduce(0) { $0 + $1.expense }
            previousYearStats = DashboardStats(totalIncome: prevIncome, totalExpense: prevExpense, transactionCount: 0)
        } else {
            previousYearStats = .empty
        }

        // Récap investissements : tous les comptes Investments en 1 fetch (SQL GROUP BY).
        // On exclut les comptes vides (currentValue == 0) pour éviter d'inflater le compteur
        // avec des comptes "fantômes" créés par live sync sans aucun ordre.
        let invAccounts = investmentRepository.fetchAccounts()
        let actives = invAccounts.filter { $0.currentValue > 0 || $0.cashBalance > 0 }
        let totalCurrent = actives.reduce(0.0) { $0 + $1.currentValue + $1.cashBalance }
        let totalInvested = actives.reduce(0.0) { $0 + $1.investedAmount }
        investmentsRecap = InvestmentsRecap(
            totalCurrentValue: totalCurrent,
            totalInvested: totalInvested,
            activeAccountCount: actives.count
        )

        // Récap patrimoine — on résout les valeurs des assets linked (via les
        // comptes existants déjà chargés), on somme l'immobilier et les capitaux
        // restants dus des prêts via LoanCalculator. Tout en mémoire, <5 ms typique.
        patrimoineRecap = computePatrimoineRecap()

        // Récap budget — état des enveloppes du mois en cours.
        budgetRecap = computeBudgetRecap()

        // Alertes intelligentes — recalculées à chaque load (pas de cache).
        // Le moteur agrège goals en retard, enveloppes dépassées, liens rompus.
        alerts = AlertEngine.compute()

        // Insights coach — détecte les opportunités d'optimisation statistiquement.
        // Coût ~50ms sur grosse base (scan 6 mois) — acceptable au load.
        insights = InsightEngine.compute()

        isLoading = false
    }

    /// Calcule l'état des enveloppes sur le mois en cours. Pour chaque enveloppe
    /// active, on somme les dépenses de sa catégorie (et sous-catégories) sur
    /// la période 1er du mois → aujourd'hui, et on classe en healthy/warning/exceeded.
    private func computeBudgetRecap() -> BudgetRecap {
        let envelopes = BudgetRepository.shared.fetchEnvelopes().filter { $0.isActive }
        guard !envelopes.isEmpty else { return .empty }

        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let monthStart = cal.date(from: comps) else { return .empty }

        let txs = repository.fetchTransactionsAllAccounts(
            from: monthStart, to: now, limit: 5000, offset: 0
        )

        // Pré-calcul des sous-catégories pour matcher les dépenses par parente
        let allCats = repository.fetchCategories()
        let childrenByParent: [Int: [Int]] = Dictionary(grouping: allCats, by: { $0.parentId ?? 0 })
            .mapValues { $0.map(\.id) }

        var healthy = 0
        var warning = 0
        var exceeded = 0
        for env in envelopes {
            guard let cid = env.categoryId else { continue }
            // IDs candidates : la cat elle-même + ses sous-cats
            var ids: Set<Int> = [cid]
            if let kids = childrenByParent[cid] { ids.formUnion(kids) }
            let spent = txs
                .filter { $0.amount < 0 && ids.contains($0.categoryId ?? -1) }
                .reduce(0.0) { $0 + abs($1.amount) }
            let ratio = env.amount > 0 ? spent / env.amount : 0
            if ratio > 1.0 { exceeded += 1 }
            else if ratio >= 0.8 { warning += 1 }
            else { healthy += 1 }
        }
        return BudgetRecap(
            totalCount: envelopes.count,
            healthyCount: healthy,
            warningCount: warning,
            exceededCount: exceeded
        )
    }

    /// Calcule le snapshot patrimoine net pour le bandeau. Résolution identique au
    /// `PatrimoineViewModel` mais inlinée ici pour ne pas instancier 2 VMs.
    private func computePatrimoineRecap() -> PatrimoineRecap {
        let assets = patrimoineRepository.fetchAssets()
        let realEstates = patrimoineRepository.fetchRealEstate()
        let loans = patrimoineRepository.fetchLoans()
        guard !assets.isEmpty || !realEstates.isEmpty || !loans.isEmpty else {
            return .empty
        }

        // Caches pour la résolution des assets liés.
        let bankAccounts = transactionRepository.fetchAccounts()
        let investAccounts = investmentRepository.fetchAccounts()

        // Σ assets résolus (linked → balance fraîche, manual → manualValue, broken → lastKnown).
        let assetsTotal = assets.reduce(0.0) { acc, asset in
            if let bankId = asset.linkedAccountId,
               bankAccounts.contains(where: { $0.id == bankId }) {
                return acc + transactionRepository.fetchAccountBalance(accountId: bankId, upToDate: nil)
            }
            if let invId = asset.linkedInvestmentAccountId,
               let inv = investAccounts.first(where: { $0.id == invId }) {
                return acc + inv.currentValue + inv.cashBalance
            }
            if asset.isLinked {
                return acc + asset.lastKnownValue  // lien rompu → fallback
            }
            return acc + asset.manualValue
        }
        let realEstateTotal = realEstates.reduce(0.0) { $0 + $1.currentValue }
        let loansTotal = loans.reduce(0.0) { $0 + LoanCalculator.compute(loan: $1).remainingCapital }

        let totalAssets = assetsTotal + realEstateTotal
        return PatrimoineRecap(
            netWorth: totalAssets - loansTotal,
            totalAssets: totalAssets,
            totalLiabilities: loansTotal,
            itemsCount: assets.count + realEstates.count + loans.count
        )
    }

    /// Called when user taps a month bar – toggles selection and refreshes category/tag data.
    func toggleMonth(_ month: String) {
        selectedMonth = (selectedMonth == month) ? nil : month
        categoryData = repository.fetchCategoryTotals(from: filterFrom, to: filterTo)
        tagData      = repository.fetchTagTotals(from: filterFrom, to: filterTo)
    }
}
