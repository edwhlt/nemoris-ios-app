import Foundation

// MARK: - InsightEngine
//
// A detection engine for "insights" — optimization opportunities detected
// statistically from the user's history. No ML/LLM here: 5 pure, deterministic
// detectors.
//
// This engine now serves TWO purposes: (1) a source of
// "signals" injected into the brief sent to the spending coach
// (`CoachService.transactionsBriefing`), and (2) a fallback shown on the Dashboard
// as long as no AI analysis has run yet (`InsightsCoachCard`, an
// offline-first doctrine). It's no longer the primary recommendation engine.
//
// **Philosophy**: 3 solid, actionable insights are preferred over 20
// vague ones. The thresholds are calibrated to only fire on
// statistically robust signals.

enum InsightEngine {

    /// The analysis period — 180 days = a rolling 6 months. Provides a
    /// solid baseline for drift detection and frequency averaging.
    private static let analysisDays = 180

    /// Generates every relevant insight, sorted by decreasing `compositeScore`.
    /// Capped at 8 insights max — beyond that it becomes noise for the user.
    /// - Parameters:
    ///   - txRepo: the repository, defaulting to the
    ///     app's database. Tests inject it against a temporary database.
    ///   - now: the evaluation date, so the analysis window is
    ///     reproducible instead of depending on the day it runs.
    static func compute(txRepo: TransactionRepository = TransactionRepository(),
                        now: Date = Date()) -> [Insight] {
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(byAdding: .day, value: -analysisDays, to: now) else { return [] }

        let txs = txRepo.fetchTransactionsAllAccounts(from: from, to: now, limit: 10000, offset: 0)
        let allCategories = txRepo.fetchCategories()
        let allTiers = txRepo.fetchTiers()
        let patterns = BudgetRepository.shared.fetchActivePatterns()

        var insights: [Insight] = []
        insights.append(contentsOf: detectDormantSubscriptions(patterns: patterns, txs: txs, allTiers: allTiers))
        insights.append(contentsOf: detectSmallFrequentHabits(txs: txs, allTiers: allTiers))
        insights.append(contentsOf: detectDuplicateSubscriptions(patterns: patterns, allCategories: allCategories))
        insights.append(contentsOf: detectCategoryDrift(txs: txs, allCategories: allCategories, now: now, cal: cal))
        insights.append(contentsOf: detectTopCategoryConcentration(txs: txs, allCategories: allCategories))

        // Filtre par confiance minimale et tri par score
        return insights
            .filter { $0.confidence >= 0.3 }
            .sorted { $0.compositeScore > $1.compositeScore }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - 1. Abonnements dormants

    /// Detects `MONTHLY` or `YEARLY` recurring items whose payee has had no
    /// additional non-recurring transaction in 90+ days — a
    /// classic signal of a subscription paid for but unused (Netflix, Disney+,
    /// apps someone forgot to cancel).
    private static func detectDormantSubscriptions(
        patterns: [RecurringPattern],
        txs: [FinanceTransaction],
        allTiers: [Tiers]
    ) -> [Insight] {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let dormancyThresholdDays = 90

        var result: [Insight] = []
        for pattern in patterns where pattern.isExpense {
            guard let payeeId = pattern.payeeId else { continue }
            // The last transaction ASSOCIATED with the payee (all of them, not just recurring).
            // The MVP has no "is_recurring_match" flag → an approximation: the
            // payee's last transaction is taken. If it's recent (≤ 90 days), the user is
            // considered to be "using" it — no insight. Otherwise it's flagged.
            let payeeTxs = txs.filter { $0.tiersId == payeeId }.sorted { $0.date > $1.date }
            guard let last = payeeTxs.first else { continue }
            let daysSinceLast = cal.dateComponents([.day], from: last.date, to: now).day ?? 0
            guard daysSinceLast >= dormancyThresholdDays else { continue }

            // Annual cost = the monthly payment × 12, or the amount as-is for yearly
            let annualCost: Double = {
                switch pattern.frequency {
                case .monthly:    return abs(pattern.amountAvg) * 12
                case .quarterly:  return abs(pattern.amountAvg) * 4
                case .semiannual: return abs(pattern.amountAvg) * 2
                case .yearly:     return abs(pattern.amountAvg)
                case .weekly:     return abs(pattern.amountAvg) * 52
                case .biweekly:   return abs(pattern.amountAvg) * 26
                case .daily:      return abs(pattern.amountAvg) * 365
                }
            }()

            let payeeName = allTiers.first(where: { $0.id == payeeId })?.name ?? pattern.name
            let monthlyStr = monthlyEquivalent(pattern).formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let annualStr = annualCost.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            result.append(Insight(
                id: "dormant_\(payeeId)",
                kind: .dormantSubscription,
                title:"\(payeeName) — non utilisé depuis \(daysSinceLast) jours",
                detail: "Vous payez \(monthlyStr)/mois pour \(payeeName) mais aucune transaction associée n'apparaît depuis \(daysSinceLast) jours. Envisagez de résilier — \(annualStr) économisés par an.",
                annualImpact: annualCost,
                actionability: 5,  // Unsubscribing = 1 click in Settings → iOS Subscriptions
                confidence: min(1.0, Double(daysSinceLast) / 180.0)  // Plus dormant longtemps → plus confiant
            ))
        }
        return result
    }

    // MARK: - 2. Coffee/snack habits

    /// Detects payees with a "ritual" behavior: a high frequency
    /// (≥ 8 transactions / 90 days) AND a low unit amount
    /// (≤ €10). Typically: a Starbucks coffee, a midday snack, pastries.
    /// The cumulative annual sum can be surprising for the user.
    private static func detectSmallFrequentHabits(
        txs: [FinanceTransaction],
        allTiers: [Tiers]
    ) -> [Insight] {
        let now = Date()
        let last90 = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let recentExpenses = txs.filter { $0.amount < 0 && $0.date >= last90 && $0.tiersId != nil }

        // Group par tiersId
        var byTier: [Int: [FinanceTransaction]] = [:]
        for tx in recentExpenses {
            byTier[tx.tiersId!, default: []].append(tx)
        }

        var result: [Insight] = []
        for (tierId, group) in byTier {
            let count = group.count
            guard count >= 8 else { continue }
            let totalAbs = group.reduce(0.0) { $0 + abs($1.amount) }
            let unitAvg = totalAbs / Double(count)
            guard unitAvg <= 10.0 else { continue }  // Filtre montants > 10 €
            // Projection annuelle
            let annualCost = totalAbs * (365.0 / 90.0)
            // The "halve it" case: how much would be saved by cutting
            // the frequency by 50%
            let potentialSaving = annualCost * 0.5

            let payeeName = allTiers.first(where: { $0.id == tierId })?.name ?? "Inconnu"
            let unitAvgStr = unitAvg.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let annualCostStr = annualCost.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let savingStr = potentialSaving.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            result.append(Insight(
                id: "habit_\(tierId)",
                kind: .smallFrequentHabit,
                title: "\(payeeName) — \(count) achats en 90 j à ~\(unitAvgStr)",
                detail: "Cumulé sur l'année : \(annualCostStr). Réduire la fréquence de moitié → \(savingStr) économisés/an.",
                annualImpact: potentialSaving,
                actionability: 3,  // A habit change — not trivial but achievable
                confidence: min(1.0, Double(count) / 30.0)  // Plus de tx → plus de confiance
            ))
        }
        return result
    }

    // MARK: - 3. Abonnements similaires (doublons)

    /// Detects several active recurring items in the same category (e.g. Netflix +
    /// Disney+ + Apple TV all at once). Not an explicit recommendation
    /// to "cancel the most expensive one" — just a heads-up that the user may have
    /// forgotten how many they have.
    private static func detectDuplicateSubscriptions(
        patterns: [RecurringPattern],
        allCategories: [Category]
    ) -> [Insight] {
        let expensePatterns = patterns.filter { $0.isExpense && $0.categoryId != nil }
        var byCategory: [Int: [RecurringPattern]] = [:]
        for p in expensePatterns {
            byCategory[p.categoryId!, default: []].append(p)
        }

        var result: [Insight] = []
        for (cid, group) in byCategory {
            guard group.count >= 2 else { continue }
            let monthlyTotal = group.reduce(0.0) { $0 + monthlyEquivalent($1) }
            let catName = allCategories.first(where: { $0.id == cid })?.name ?? "Catégorie"
            let names = group.map { $0.name }.joined(separator: ", ")
            let monthlyStr = monthlyTotal.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let annualStr = (monthlyTotal*12).formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            result.append(Insight(
                id: "dup_\(cid)",
                kind: .duplicateSubscriptions,
                title: "\(group.count) abonnements actifs en \(catName)",
                detail: "Vous payez actuellement \(names) — total \(monthlyStr)/mois (\(annualStr)/an). Vérifiez si tous sont vraiment utilisés.",
                annualImpact: monthlyTotal * 12 * 0.3,  // Hypothesis: a 30% reduction is possible
                actionability: 4,
                confidence: 0.7
            ))
        }
        return result
    }

    // MARK: - 4. Category drift

    /// Detects categories whose last month's spending is
    /// significantly (> +25%) above the average of the previous 3 months.
    /// A signal of a recent behavioral drift the user may not have
    /// noticed.
    private static func detectCategoryDrift(
        txs: [FinanceTransaction],
        allCategories: [Category],
        now: Date,
        cal: Calendar
    ) -> [Insight] {
        guard let lastMonthStart = cal.date(byAdding: .day, value: -30, to: now),
              let baselineStart = cal.date(byAdding: .day, value: -120, to: now) else { return [] }

        let recentExpenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }
        // Sum per category over the last month AND over the prior 90-day baseline
        var lastMonth: [Int: Double] = [:]
        var baseline: [Int: Double] = [:]
        for tx in recentExpenses {
            guard let cid = tx.categoryId else { continue }
            if tx.date >= lastMonthStart {
                lastMonth[cid, default: 0] += abs(tx.amount)
            } else if tx.date >= baselineStart {
                baseline[cid, default: 0] += abs(tx.amount)
            }
        }

        var result: [Insight] = []
        for (cid, lastMonthSpent) in lastMonth {
            let baselineSpent = baseline[cid] ?? 0
            let baselineMonthly = baselineSpent / 3.0  // 3 mois baseline
            guard baselineMonthly > 50, lastMonthSpent > baselineMonthly * 1.25 else { continue }
            let increase = lastMonthSpent - baselineMonthly
            let increasePct = increase / baselineMonthly * 100
            let catName = allCategories.first(where: { $0.id == cid })?.name ?? "Catégorie"
            let lastMonthStr = lastMonthSpent.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let baselineStr = baselineMonthly.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            let increaseStr = increase.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            result.append(Insight(
                id: "drift_\(cid)",
                kind: .categoryDrift,
                title: "\(catName) : +\(Int(increasePct)) % vs vos 3 mois précédents",
                detail: "Ce mois-ci : \(lastMonthStr). Moyenne des 3 mois précédents : \(baselineStr). Soit \(increaseStr) de plus. Pic ponctuel ou nouvelle tendance ?",
                annualImpact: increase * 12,  // If the drift persists for 1 year
                actionability: 2,  // Identifying the cause requires the user's own analysis
                confidence: min(1.0, baselineMonthly / 200.0)
            ))
        }
        return result
    }

    // MARK: - 5. Top-category concentration

    /// Computes the top-1 category's share of total spending over the period.
    /// If > 30%, an informational insight is generated (not really actionable
    /// but illuminating — the user often underestimates this item).
    private static func detectTopCategoryConcentration(
        txs: [FinanceTransaction],
        allCategories: [Category]
    ) -> [Insight] {
        let expenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }
        var byCat: [Int: Double] = [:]
        for tx in expenses {
            byCat[tx.categoryId!, default: 0] += abs(tx.amount)
        }
        let total = byCat.values.reduce(0, +)
        guard total > 0 else { return [] }
        let top = byCat.max { $0.value < $1.value }
        guard let (topCid, topAmount) = top else { return [] }
        let share = topAmount / total
        guard share > 0.30 else { return [] }
        let catName = allCategories.first(where: { $0.id == topCid })?.name ?? "Catégorie"
        let topAmountStr = topAmount.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
        return [Insight(
            id: "top_\(topCid)",
            kind: .topCategoryConcentration,
            title: "\(catName) = \(Int(share * 100)) % de vos dépenses",
            detail: "Sur les 6 derniers mois, vous avez dépensé \(topAmountStr) en \(catName) — \(Int(share * 100)) % de votre total. C'est votre principal poste : un ajustement même modeste ici a un impact disproportionné.",
            annualImpact: 0,  // Informational, no quantified action
            actionability: 1,
            confidence: 0.8
        )]
    }

    // MARK: - Helpers

    private static func monthlyEquivalent(_ p: RecurringPattern) -> Double {
        let abs_amount = abs(p.amountAvg)
        switch p.frequency {
        case .daily:      return abs_amount * 30.42
        case .weekly:     return abs_amount * 4.33
        case .biweekly:   return abs_amount * 2.17
        case .monthly:    return abs_amount
        case .quarterly:  return abs_amount / 3.0
        case .semiannual: return abs_amount / 6.0
        case .yearly:     return abs_amount / 12.0
        }
    }
}
