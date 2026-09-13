import Foundation

// MARK: - GoalCalculator
//
// A pure (stateless) calculation of `GoalProgress` from a `Goal` and the current
// Patrimoine context (`PatrimoineSnapshot` + an initial debt history for
// debt_payoff goals). No SQLite dependency, no side effect — unit-testable
// and callable from any VM.
//
// **Why not directly in the VM?**
//   - Separation of concerns: the VM handles the collection and the
//     refresh; the calculator handles "how do I compute this".
//   - Testability: each goal kind can be tested with fixed inputs.
//   - Reusability: the projection will reuse the same logic
//     to estimate Goals reached in the future.

enum GoalCalculator {

    /// Computes `GoalProgress` from the given Patrimoine context.
    ///
    /// - Parameters:
    ///   - goal: the goal to evaluate
    ///   - snapshot: the current Patrimoine snapshot (as of today)
    ///   - totalAssetsValue: the value of liquid assets (already resolved from linked accounts)
    ///   - initialDebtForPayoff: the reference debt used to compute the % repaid
    ///     (typically the debt at the time the goal was created, or the MAX debt if
    ///     "since the peak" is preferred). If nil, falls back to `snapshot.totalLiabilities` at
    ///     the current date, which would always give 0% — so this should be avoided.
    ///   - asOf: the evaluation date, default `Date()`. Only used to compute
    ///     `daysRemaining`.
    static func progress(for goal: Goal,
                         snapshot: PatrimoineSnapshot,
                         totalAssetsValue: Double,
                         initialDebtForPayoff: Double? = nil,
                         asOf reference: Date = Date()) -> GoalProgress {

        // 1) Resolving `currentAmount` based on the kind.
        let current: Double
        switch goal.kind {
        case .savings:
            current = max(0, totalAssetsValue)
        case .netWorth:
            current = max(0, snapshot.netWorth)
        case .debtPayoff:
            // current = the REPAID amount = initialDebt − the current debt.
            // Clamped to [0, initialDebt] to avoid negative values if the
            // debt has increased (rare but possible: a new loan after the goal
            // was created).
            let initial = initialDebtForPayoff ?? snapshot.totalLiabilities
            current = max(0, min(initial, initial - snapshot.totalLiabilities))
        case .custom:
            current = max(0, goal.customCurrentAmount)
        }

        // 2) The ratio capped at 1.0. The degenerate target_amount == 0 case → a ratio = 0
        //    to avoid dividing by zero and a misleading "100% reached" display
        //    on a poorly entered goal.
        let ratio: Double = {
            // A debt_payoff with target = 0 = "repay entirely". In that case
            // the ratio is current / initialDebt (not current / target, which would be /0).
            if goal.kind == .debtPayoff && goal.targetAmount == 0 {
                let initial = initialDebtForPayoff ?? snapshot.totalLiabilities
                guard initial > 0 else { return 0 }
                return min(1.0, current / initial)
            }
            guard goal.targetAmount > 0 else { return 0 }
            return min(1.0, current / goal.targetAmount)
        }()

        // 3) Days remaining (uniquement si deadline)
        var daysRemaining: Int? = nil
        var isOverdue = false
        if let deadline = goal.deadlineDate {
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents([.day],
                                           from: cal.startOfDay(for: reference),
                                           to: cal.startOfDay(for: deadline))
            daysRemaining = comps.day
            isOverdue = (comps.day ?? 0) < 0 && ratio < 1.0
        }

        return GoalProgress(
            goal: goal,
            currentAmount: current,
            ratio: ratio,
            daysRemaining: daysRemaining,
            isOverdue: isOverdue
        )
    }

    /// The monthly amount to set aside to reach the goal by the deadline,
    /// at a constant pace. Nil if there's no deadline or the goal is already
    /// reached (nothing to do).
    ///
    /// Serves as an **action indicator** in the goal's row: "You need to
    /// save €320/month to reach this goal by December".
    static func monthlyContributionNeeded(for progress: GoalProgress,
                                          asOf reference: Date = Date()) -> Double? {
        guard let deadline = progress.goal.deadlineDate else { return nil }
        guard !progress.isCompleted else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.month],
                                       from: cal.startOfDay(for: reference),
                                       to: cal.startOfDay(for: deadline))
        let months = max(1, comps.month ?? 1)  // never < 1 month, to avoid /0 + a broken UI
        return progress.amountRemaining / Double(months)
    }
}
