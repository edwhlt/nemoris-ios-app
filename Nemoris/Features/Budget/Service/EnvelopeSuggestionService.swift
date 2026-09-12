import Foundation

// MARK: - EnvelopeSuggestionService
//
// Suggests budget envelopes from the user's history.
// The algorithm: looks at the last 90 days, groups expenses by
// category, computes the monthly average and suggests a budget of
// `average × 1.10` (rounded up to the nearest ten) — a light overhead so the
// user isn't "over budget" from the very first month.
//
// **Already-covered-category filter**: if an envelope already exists for
// a category, it isn't suggested again (avoids duplicates). It can be
// overridden via the regular form if the user wants to adjust it.
//
// **Relevance criteria**:
//   - At least 3 transactions in the last 90 days (a solid signal)
//   - At least €30 of cumulative spending (filters out marginal categories)
//   - A non-`nil` category (uncategorized is ignored)

struct EnvelopeSuggestion: Identifiable, Hashable {
    var id: Int { categoryId }
    let categoryId: Int
    let categoryName: String
    let categoryIcon: String
    /// Observed monthly average (in positive euros).
    let averageMonthly: Double
    /// Amount suggested for the envelope (average rounded up to the nearest ten + 10% overhead).
    let suggestedBudget: Double
    /// Number of transactions over the analysis period — useful to show
    /// the suggestion's statistical robustness ("18 purchases over 3 months").
    let transactionCount: Int
}

enum EnvelopeSuggestionService {

    /// Analysis period — 90 days = a rolling 3 months. Long enough to
    /// smooth out a single month's seasonal swings but short enough to
    /// stay responsive to recent lifestyle changes.
    private static let analysisDays = 90

    /// Relevance thresholds — below these values, the category is too
    /// marginal to deserve an envelope.
    private static let minTransactions = 3
    private static let minTotalSpent: Double = 30

    /// Computes suggestions from the current history. Categories
    /// already covered by an existing envelope are excluded from the result.
    /// - Parameters:
    ///   - txRepo: the transaction repository. The default value targets the
    ///     app's database; tests inject it against a
    ///     temporary database, as with the repositories themselves.
    ///   - now: the evaluation date, so the 90-day analysis window
    ///     is reproducible instead of depending on the day it runs.
    static func computeSuggestions(
        existingEnvelopes: [BudgetEnvelope],
        allCategories: [Category],
        txRepo: TransactionRepository = TransactionRepository(),
        now: Date = Date()
    ) -> [EnvelopeSuggestion] {
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(byAdding: .day, value: -analysisDays, to: now) else { return [] }

        // Fetch the transactions over the period — every category, expenses only
        // (amount < 0). Capped at 5000 for large histories (unlikely to
        // exceed that over 90 days).
        let txs = txRepo.fetchTransactionsAllAccounts(from: from, to: now, limit: 5000, offset: 0)
        let expenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }

        // Categories already covered (a set for O(1) exclusion)
        let coveredCategoryIds = Set(existingEnvelopes.compactMap { $0.categoryId })

        // Groupement par categoryId
        var byCategoryId: [Int: (count: Int, total: Double)] = [:]
        for tx in expenses {
            guard let cid = tx.categoryId, !coveredCategoryIds.contains(cid) else { continue }
            let current = byCategoryId[cid] ?? (count: 0, total: 0)
            byCategoryId[cid] = (count: current.count + 1, total: current.total + abs(tx.amount))
        }

        // Converts to suggestions and applies the thresholds
        let categoryById = Dictionary(uniqueKeysWithValues: allCategories.map { ($0.id, $0) })
        let monthlyFactor = 30.0 / Double(analysisDays)  // 90j → mensuel
        var suggestions: [EnvelopeSuggestion] = []
        for (cid, stats) in byCategoryId {
            guard stats.count >= minTransactions, stats.total >= minTotalSpent else { continue }
            guard let cat = categoryById[cid] else { continue }
            let avgMonthly = stats.total * monthlyFactor
            // Rounded up to the nearest ten + 10% overhead — gives a
            // realistic target, but not so tight the user is over budget
            // from the very first month.
            // ⚠️ Rounded to the nearest cent BEFORE rounding up to the ten. In
            // floating point, 100 × 1.10 equals 110.00000000000001: a direct ceil
            // would push it to 120, i.e. 20% margin instead of the intended 10%. The
            // case happens exactly on round averages — 100, 200 — i.e.
            // the most common ones.
            let budgetRaw = (avgMonthly * 1.10 * 100).rounded() / 100
            let budgetRounded = ceil(budgetRaw / 10.0) * 10.0

            suggestions.append(EnvelopeSuggestion(
                categoryId: cid,
                categoryName: cat.name,
                categoryIcon: cat.displayIcon,
                averageMonthly: avgMonthly,
                suggestedBudget: budgetRounded,
                transactionCount: stats.count
            ))
        }

        // Sorted by decreasing suggested amount (the most impactful first)
        return suggestions.sorted { $0.suggestedBudget > $1.suggestedBudget }
    }
}
