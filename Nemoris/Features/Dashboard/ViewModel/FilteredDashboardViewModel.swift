import Foundation
import Observation

// MARK: - Shared chart types

enum ChartGranularity: String, CaseIterable {
    case day   = "Jour"
    case week  = "Semaine"
    case month = "Mois"
}

struct PeriodTotal: Identifiable {
    let id: Date        // start of the period
    let income: Double  // ≥ 0
    let expense: Double // ≤ 0
}

struct DailyBalance: Identifiable {
    let id: Date
    let balance: Double
}

@Observable
final class FilteredDashboardViewModel {

    // MARK: - State

    var granularity: ChartGranularity = .month
    var categoryData: [CategoryTotal] = []
    var tagData: [TagTotal] = []
    var dailyBalanceData: [DailyBalance] = []
    var stats: DashboardStats = .empty
    var isLoading = false

    // MARK: - Private storage

    private var allTransactions: [FinanceTransaction] = []
    private let repository: TransactionRepository

    /// The default value targets the app's database: no call site
    /// needs to change. Tests inject a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        repository = TransactionRepository(store: store)
    }

    // MARK: - Computed: data aggregated by granularity (reactive)

    var periodData: [PeriodTotal] {
        let cal = Calendar.current
        let grouped: [Date: [FinanceTransaction]]
        switch granularity {
        case .day:
            grouped = Dictionary(grouping: allTransactions) { cal.startOfDay(for: $0.date) }
        case .week:
            grouped = Dictionary(grouping: allTransactions) {
                cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? cal.startOfDay(for: $0.date)
            }
        case .month:
            grouped = Dictionary(grouping: allTransactions) {
                var c = cal.dateComponents([.year, .month], from: $0.date); c.day = 1
                return cal.date(from: c) ?? cal.startOfDay(for: $0.date)
            }
        }
        return grouped.map { date, txs in
            PeriodTotal(
                id: date,
                income:  txs.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount },
                expense: txs.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
            )
        }.sorted { $0.id < $1.id }
    }

    // MARK: - Public API

    func load(filter: TransactionFilter) {
        isLoading = true
        // The analysis screen (totals/sums): excludes "other" accounts — but
        // only when the aggregate covers "all accounts" (accountId == 0).
        // A specific account explicitly chosen by the user (even an "other" one)
        // shows its analysis normally, since they asked for it themselves.
        allTransactions = repository.fetchAllFilteredTransactions(
            filter: filter,
            excludeInternalTransfers: true,
            excludeOtherAccounts: filter.accountId == 0
        )
        let tagMap = repository.fetchTagsForTransactions(allTransactions.map { $0.id })
        aggregate(transactions: allTransactions, tagMap: tagMap)
        isLoading = false
    }

    // MARK: - In-memory aggregation

    private func aggregate(transactions: [FinanceTransaction], tagMap: [Int: [Tag]]) {
        let cal = Calendar.current

        // Category totals (top 10 by absolute value)
        let byCategory = Dictionary(grouping: transactions) { tx in
            tx.categoryName.isEmpty ? "Non catégorisé" : tx.categoryName
        }
        categoryData = byCategory.map { name, txs in
            CategoryTotal(category: name, parentCategory: nil, total: txs.reduce(0) { $0 + $1.amount })
        }
        .sorted { abs($0.total) > abs($1.total) }
        .prefix(10)
        .map { $0 }

        // Tag totals
        var tagAccum: [Int: (tag: Tag, total: Double)] = [:]
        for (txId, tags) in tagMap {
            guard let tx = transactions.first(where: { $0.id == txId }) else { continue }
            for tag in tags {
                var entry = tagAccum[tag.id] ?? (tag, 0)
                entry.total += tx.amount
                tagAccum[tag.id] = entry
            }
        }
        tagData = tagAccum.values
            .map { TagTotal(tag: $0.tag, total: $0.total) }
            .sorted { abs($0.total) > abs($1.total) }

        // Daily cumulative balance
        let byDay = Dictionary(grouping: transactions) { tx in cal.startOfDay(for: tx.date) }
        var running = 0.0
        dailyBalanceData = byDay.keys.sorted().map { day in
            running += byDay[day]!.reduce(0) { $0 + $1.amount }
            return DailyBalance(id: day, balance: running)
        }

        // Summary stats
        let income  = transactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let expense = transactions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
        stats = DashboardStats(
            totalIncome: income,
            totalExpense: expense,
            transactionCount: transactions.count
        )
    }
}
