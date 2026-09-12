import Foundation

// MARK: - EnvelopeSpendingCalculator
//
// **Pure engine** for the "spent per envelope" calculation — no database, cache or
// network access, so testable outside Xcode (see `Tests/EnvelopeSpendingTests.swift`).
// Same doctrine as `Services/PortfolioEvolutionBuilder.swift`: a single engine
// shared by every level, which can therefore no longer diverge.
//
// **Why it exists**: before this factoring, the calculation lived in FOUR
// incompatible copies, which produced contradictions visible on
// screen (an envelope "over budget" in the AlertsBanner and "healthy" in the
// Budget banner, on the same Dashboard):
//
// | Implementation                              | Sub-categories  | Yearly envelopes     |
// |---------------------------------------------|-----------------|----------------------|
// | AnnualDashboardViewModel.computeBudgetRecap | included        | ignored              |
// | BudgetViewModel.monthlySummary              | included        | amount / 12          |
// | AlertEngine.overspentEnvelopesAlerts        | category only   | ignored              |
// | WidgetDataStore.refreshBudget               | category only   | amount / 12          |
//
// **Rules kept** (`BudgetViewModel`'s, the most complete):
//   1. `allocated` = `period == .yearly ? amount / 12 : amount` — a yearly
//      envelope is turned monthly, otherwise a one-year budget is compared to a month of
//      spending and nothing is ever "over budget".
//   2. Matching includes the category **and its sub-categories** — a
//      "Groceries" envelope must capture "Supermarket" spending.
//   3. Only expenses (`amount < 0`) count, in absolute value.

enum EnvelopeSpendingCalculator {

    /// Computes each envelope's progress over the period covered by
    /// `transactions`.
    ///
    /// - Parameters:
    ///   - envelopes: envelopes to evaluate. **The caller filters `isActive`** — the
    ///     engine doesn't have to decide what's relevant for the calling screen.
    ///   - transactions: the period's transactions, across all accounts.
    ///   - categories: the full reference data (used for the parent/child hierarchy
    ///     and labels).
    ///   - previsions: the period's previsions. Optional — without them,
    ///     `recurringSpent` and `forecasted` are 0, which is enough for callers
    ///     that only show "spent vs. allocated" (Dashboard, alerts, widget).
    ///   - patterns: recurring patterns, needed to link a prevision to
    ///     a category. Optional, same reason.
    static func progresses(
        envelopes: [BudgetEnvelope],
        transactions: [FinanceTransaction],
        categories: [Category],
        previsions: [BudgetPrevision] = [],
        patterns: [RecurringPattern] = []
    ) -> [EnvelopeProgress] {
        guard !envelopes.isEmpty else { return [] }

        // --- Indexes built ONCE ------------------------------------------------
        // The original version re-ran a `filter` over every transaction
        // for every envelope (O(envelopes × transactions)) and a
        // `patterns.first(where:)` per prevision and per envelope.

        let childrenByParent: [Int: [Int]] = Dictionary(
            grouping: categories.compactMap { cat in cat.parentId.map { ($0, cat.id) } },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        let categoryById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var expensesByCategory: [Int: [FinanceTransaction]] = [:]
        for tx in transactions where tx.amount < 0 {
            guard let cid = tx.categoryId else { continue }
            expensesByCategory[cid, default: []].append(tx)
        }

        // Transactions already attached to a confirmed recurring item → the "fixed" share.
        let matchedTxIds = Set(
            previsions.filter { $0.status == .matched }.compactMap(\.actualTransactionId)
        )

        // patternId → categoryId, to link a prevision to an envelope.
        let categoryByPatternId = Dictionary(
            patterns.compactMap { p in p.categoryId.map { (p.id, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let activePrevisions = previsions.filter { $0.status != .skipped && $0.amount < 0 }

        // --- Calcul par enveloppe --------------------------------------------
        return envelopes.map { env in
            let ids = categoryIds(for: env.categoryId, childrenByParent: childrenByParent)

            let envTxs = ids.flatMap { expensesByCategory[$0] ?? [] }
            let spent = envTxs.reduce(0.0) { $0 + abs($1.amount) }
            let recurringSpent = envTxs
                .filter { matchedTxIds.contains($0.id) }
                .reduce(0.0) { $0 + abs($1.amount) }

            let idSet = Set(ids)
            let forecasted = activePrevisions
                .filter { prevision in
                    guard let patternId = prevision.recurringPatternId,
                          let patternCategory = categoryByPatternId[patternId] else { return false }
                    return idSet.contains(patternCategory)
                }
                .reduce(0.0) { $0 + abs($1.amount) }

            let category = env.categoryId.flatMap { categoryById[$0] }
            return EnvelopeProgress(
                envelope: env,
                categoryName: category?.name ?? env.name,
                categoryIcon: category?.displayIcon ?? "tag.fill",
                spent: spent,
                allocated: allocatedMonthly(for: env),
                recurringSpent: recurringSpent,
                forecasted: forecasted
            )
        }
    }

    /// An envelope's monthly amount. A yearly envelope is worth `amount / 12`
    /// for a given month.
    static func allocatedMonthly(for envelope: BudgetEnvelope) -> Double {
        envelope.period == .yearly ? envelope.amount / 12 : envelope.amount
    }

    /// The envelope's category + its direct children. Empty if the envelope isn't
    /// attached to any category (it then shows 0 spent, which is accurate).
    static func categoryIds(for categoryId: Int?, childrenByParent: [Int: [Int]]) -> [Int] {
        guard let id = categoryId else { return [] }
        return [id] + (childrenByParent[id] ?? [])
    }
}

// MARK: - BudgetRecap

/// Summary state of the envelopes over the period — for the Dashboard's
/// "Overview" banner ("11 envelopes · 7 ✓ · 4 ✗").
///
/// Derived from `[EnvelopeProgress]`: the classification lives in `EnvelopeHealth`,
/// never recomputed here.
struct BudgetRecap {
    let totalCount: Int
    let healthyCount: Int
    let warningCount: Int
    let exceededCount: Int

    var hasData: Bool { totalCount > 0 }
    var hasIssue: Bool { warningCount > 0 || exceededCount > 0 }

    static let empty = BudgetRecap(totalCount: 0, healthyCount: 0, warningCount: 0, exceededCount: 0)

    static func from(_ progresses: [EnvelopeProgress]) -> BudgetRecap {
        guard !progresses.isEmpty else { return .empty }
        var healthy = 0, warning = 0, exceeded = 0
        for progress in progresses {
            switch progress.healthState {
            case .healthy:  healthy  += 1
            case .warning:  warning  += 1
            case .exceeded: exceeded += 1
            }
        }
        return BudgetRecap(
            totalCount: progresses.count,
            healthyCount: healthy,
            warningCount: warning,
            exceededCount: exceeded
        )
    }
}
