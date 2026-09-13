import Foundation

// MARK: - ProjectionEngine
//
// A pure (stateless) engine that projects net worth month by month over N months
// (60 by default = 5 years). Reuses `LoanCalculator` for amortization and
// `PatrimoineSnapshot` as the starting point.
//
// **Inputs**:
//   - `snapshot`: the current net-worth situation (totalAssets, totalLiabilities)
//   - `totalAssetsLiquid`: the current value of liquid assets (movable assets &
//     cash) — this is WHAT grows with cash flow and returns
//   - `realEstateValue`: the current value of real estate (kept constant in
//     the MVP, real-estate appreciation isn't extrapolated)
//   - `loans`: the list of loans to project (each month LoanCalculator is
//     called at the projected date to get the exact remaining principal)
//   - `netMonthlyCashFlow`: Σ recurring income − Σ recurring expenses, reduced
//     to a monthly amount (see ProjectionInputs.cashFlowFromBudget)
//   - `scenario`: adjusts cashFlow, growth, and repayment acceleration
//
// **Assumed MVP hypotheses**:
//   - Real estate doesn't move (no extrapolated appreciation — too uncertain)
//   - Liquid assets grow uniformly at the scenario's rate (2-5%/year)
//   - Repayment acceleration (the `accelerated` scenario) is modeled
//     as an extra % reduction of the remaining principal each month
//     (an approximation — no amortization simulation with exact present value)
//   - No new loans/assets created along the way
//   - No inflation (the projected netWorth is in constant euros)

/// A net-worth point at a given date.
struct ProjectionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let netWorth: Double
    let totalAssets: Double       // liquide + immobilier
    let totalLiabilities: Double  // Σ capitaux restants
}

/// A projection scenario — adjusts 3 levers: cashFlowMultiplier, annualGrowthRate,
/// and debtAcceleration (an additional reduction of loans' remaining principal).
enum ProjectionScenario: String, CaseIterable, Identifiable {
    case conservative   // Status quo. The current flow, a cautious return, no acceleration.
    case optimistic     // +20% savings, a more ambitious return.
    case accelerated    // The current flow + accelerated loan repayment (~30%).

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conservative: return "Statu quo"
        case .optimistic:   return "Épargne renforcée"
        case .accelerated:  return "Remboursement accéléré"
        }
    }

    var systemIcon: String {
        switch self {
        case .conservative: return "line.diagonal"
        case .optimistic:   return "arrow.up.right.circle.fill"
        case .accelerated:  return "bolt.fill"
        }
    }

    var description: String {
        switch self {
        case .conservative:
            return "Vos flux et rendements actuels prolongés tels quels."
        case .optimistic:
            return "+20 % d'épargne mensuelle et un rendement annuel de 5 %."
        case .accelerated:
            return "Vos prêts sont remboursés ~30 % plus vite (versements complémentaires)."
        }
    }

    /// A coefficient applied to `netMonthlyCashFlow`. >1 increases savings.
    var cashFlowMultiplier: Double {
        switch self {
        case .conservative: return 1.0
        case .optimistic:   return 1.2
        case .accelerated:  return 1.0
        }
    }

    /// The liquid assets' annual return (as a decimal). 0.02 = 2%/year.
    var annualGrowthRate: Double {
        switch self {
        case .conservative: return 0.02
        case .optimistic:   return 0.05
        case .accelerated:  return 0.03
        }
    }

    /// A coefficient applied to loans' remaining principal EVERY MONTH to model
    /// an early repayment. 0.0 = none. 0.003 ≈ -30% of the loan's horizon
    /// (an order of magnitude, an approximation).
    var debtAccelerationPerMonth: Double {
        switch self {
        case .accelerated: return 0.003
        default:           return 0.0
        }
    }
}

enum ProjectionEngine {

    /// Projects net worth month by month over `months` months.
    /// The first point (index 0) corresponds to **today** (the snapshot as-is).
    static func project(
        snapshot: PatrimoineSnapshot,
        totalAssetsLiquid: Double,
        realEstateValue: Double,
        loans: [PatrimoineLoan],
        netMonthlyCashFlow: Double,
        scenario: ProjectionScenario,
        months: Int = 60,
        startDate: Date = Date()
    ) -> [ProjectionPoint] {

        let monthlyGrowthFactor = pow(1 + scenario.annualGrowthRate, 1.0 / 12.0)
        let adjustedCashFlow = netMonthlyCashFlow * scenario.cashFlowMultiplier
        let debtAccelFactor = 1.0 - scenario.debtAccelerationPerMonth  // <1 = on retire X% supp / mois

        var points: [ProjectionPoint] = []
        let cal = Calendar(identifier: .gregorian)

        // Liquid capital, which evolves month by month.
        var currentLiquid = totalAssetsLiquid
        // "Extra" capital repaid via the acceleration (cumulative). It's
        // subtracted from the remaining principal via LoanCalculator to have a
        // visible effect on the debt curve.
        var cumulativeExtraDebtPaid: Double = 0

        for monthOffset in 0...months {
            let date = cal.date(byAdding: .month, value: monthOffset, to: startDate) ?? startDate

            // 1) Cash flow + liquid assets' growth.
            // NO clamping to 0: `currentLiquid` is let go into
            // negative territory if the cashFlow requires it. That's more honest — it
            // conveys the ongoing overdraft the user would have if nothing changes. For
            // growth, the factor isn't applied while negative
            // (an overdraft doesn't "yield" — on the contrary, overdraft fees cost money, but
            // that isn't modeled in the MVP, so it's kept neutral).
            if monthOffset > 0 {
                currentLiquid += adjustedCashFlow
                if currentLiquid > 0 {
                    currentLiquid *= monthlyGrowthFactor
                }
            }

            // 2) Debt projected at this date — the sum of remaining principals
            //    per LoanCalculator at `date`. An extra cumulative
            //    acceleration effect is also applied to the total.
            let projectedLiabilitiesRaw = loans.reduce(0.0) { acc, loan in
                let state = LoanCalculator.compute(loan: loan, asOf: date)
                return acc + state.remainingCapital
            }
            // Acceleration: the already-cumulated "extra repaid" share is removed.
            // Composes multiplicatively each month via debtAccelFactor.
            if monthOffset > 0 {
                // Each month, an "extra installment" proportional to the
                // current remaining principal is added. So cumulativeExtraDebtPaid grows
                // but is bounded by the remaining debt.
                let extraThisMonth = max(0, projectedLiabilitiesRaw - cumulativeExtraDebtPaid)
                                     * scenario.debtAccelerationPerMonth
                cumulativeExtraDebtPaid += extraThisMonth
            }
            let projectedLiabilities = max(0, projectedLiabilitiesRaw - cumulativeExtraDebtPaid)
            _ = debtAccelFactor  // kept for the reasoning's readability

            // 3) Compose the snapshot
            let totalAssets = currentLiquid + realEstateValue
            let netWorth = totalAssets - projectedLiabilities

            points.append(ProjectionPoint(
                date: date,
                netWorth: netWorth,
                totalAssets: totalAssets,
                totalLiabilities: projectedLiabilities
            ))
        }

        return points
    }
}

// MARK: - ProjectionInputs helper (fetching cash flow from Budget)

enum ProjectionInputs {

    /// Computes the net monthly cash flow (Σ income − Σ expenses) from
    /// active Budget recurring items. Converts each pattern to a monthly equivalent
    /// based on its frequency (weekly ×4.33, monthly ×1, quarterly ÷3, yearly ÷12).
    ///
    /// Returns 0 if Budget isn't enabled / there are no recurring items — the projection
    /// then becomes a plain debt curve with no asset growth.
    static func netMonthlyCashFlowFromBudget() -> Double {
        // 1. Recurring items (rent, salary, subscriptions) — already signed.
        let patterns = BudgetRepository.shared.fetchActivePatterns()
        let recurringNet = patterns.reduce(0.0) { acc, p in
            acc + monthlyEquivalent(amount: p.amountAvg, frequency: p.frequency)
        }
        // 2. Envelopes — count as planned expenses. They're
        //    added to cashFlow AS A NEGATIVE. If a category is
        //    covered both by a recurring item (a fixed amount) AND an
        //    envelope (a variable budget), double counting is avoided by
        //    subtracting only the delta: env.amount - the recurring item for that category.
        //
        //    A pragmatic MVP strategy: only envelopes whose category
        //    has NO recurring item are subtracted — the others are already
        //    covered by recurringNet. Precision is good enough for the projection.
        let envelopes = BudgetRepository.shared.fetchEnvelopes().filter { $0.isActive }
        let recurringCategoryIds = Set(patterns.compactMap { $0.categoryId })
        let envelopesNet = envelopes
            .filter { env in
                guard let cid = env.categoryId else { return true }
                return !recurringCategoryIds.contains(cid)
            }
            .reduce(0.0) { acc, env in
                // env.amount is always positive (= the allocated budget). It's subtracted
                // to count as an estimated monthly expense.
                acc - envelopeMonthlyEquivalent(amount: env.amount, period: env.period)
            }
        return recurringNet + envelopesNet
    }

    private static func envelopeMonthlyEquivalent(amount: Double, period: BudgetPeriod) -> Double {
        switch period {
        case .monthly: return amount
        case .yearly:  return amount / 12.0
        }
    }

    private static func monthlyEquivalent(amount: Double, frequency: RecurrenceFrequency) -> Double {
        switch frequency {
        case .daily:      return amount * 30.42  // 365.25 / 12
        case .weekly:     return amount * 4.33   // 52 / 12
        case .biweekly:   return amount * 2.17   // 26 / 12
        case .monthly:    return amount
        case .quarterly:  return amount / 3.0
        case .semiannual: return amount / 6.0
        case .yearly:     return amount / 12.0
        }
    }
}
