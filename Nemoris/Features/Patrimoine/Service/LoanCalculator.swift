import Foundation

// MARK: - LoanCalculator
//
// Pure, stateless logic to compute a loan's remaining principal at a
// given date, depending on its type. No SQLite dependency — input = `PatrimoineLoan`
// + an evaluation date, output = `LoanState`. Unit-testable.
//
// **Formulas** (monthly rate i = annualRate / 12, P = principal, n = durationMonths)
//
//   • AMORT (amortizing at a fixed monthly payment)
//     M = P · i / (1 − (1+i)^(−n))
//     Remaining principal after k months:
//         CR(k) = P · (1+i)^k − M · ((1+i)^k − 1) / i   (i ≠ 0)
//         CR(k) = P · (1 − k/n)                          (i = 0, a 0% loan)
//
//   • IN_FINE (interest only until maturity)
//     M = P · i
//     CR(k) = P if k < n, otherwise 0
//
//   • DEFERRED_TOTAL (full deferral then amortization)
//     During the deferral (k < d): the principal is capitalized, no payment
//         CR(k) = P · (1+i)^k
//         M_diff = 0
//     After the deferral (k ≥ d): classic amortization over (n − d) months
//         P' = P · (1+i)^d
//         M  = P' · i / (1 − (1+i)^(−(n−d)))
//         CR(k) = P' · (1+i)^(k−d) − M · ((1+i)^(k−d) − 1) / i
//
//   • DEFERRED_PARTIAL (interest only during the deferral, then amortization)
//     During the deferral (k < d): only interest is paid
//         CR(k) = P
//         M_diff = P · i
//     After the deferral (k ≥ d): classic amortization over (n − d) months with P
//         M  = P · i / (1 − (1+i)^(−(n−d)))
//         CR(k) = P · (1+i)^(k−d) − M · ((1+i)^(k−d) − 1) / i
//
//   • REVOLVING (revolving credit, principal entered manually)
//     CR = principal (the user updates the Principal field when they repay)
//     M = 0 (no fixed payment — varies with usage)

/// A loan's computed state at a given date. Every amount in EUR (consistent
/// with the rest of the app — no multi-currency in the MVP).
struct LoanState: Equatable {
    /// The remaining principal at the evaluation date. Clamped to `[0, principal]`.
    let remainingCapital: Double
    /// The current monthly payment (interest only during a partial deferral, an
    /// amortization payment afterward, 0 for a total deferral or a revolving loan).
    let monthlyPayment: Double
    /// The total amount of interest paid since the start. Indicative (can be 0 if
    /// REVOLVING or still within a total deferral).
    let interestsPaid: Double
    /// The total principal repaid since the start (= principal − remainingCapital
    /// for amortizing types; 0 for an ongoing REVOLVING/IN_FINE).
    let capitalPaid: Double
    /// The number of months elapsed since `startDate` (capped at `durationMonths`).
    let monthsElapsed: Int
    /// `true` if the evaluation date is before `startDate` (the loan hasn't started yet).
    let isPending: Bool
    /// `true` if the loan's total duration has passed (theoretically repaid).
    let isCompleted: Bool

    /// The percentage of principal repaid (0…1). Used for the UI's progress bar.
    var progressRatio: Double {
        guard remainingCapital + capitalPaid > 0 else { return 0 }
        return capitalPaid / (remainingCapital + capitalPaid)
    }
}

enum LoanCalculator {

    /// Computes `loan`'s state at date `asOf` (default: now).
    static func compute(loan: PatrimoineLoan, asOf reference: Date = Date()) -> LoanState {
        let calendar = Calendar(identifier: .gregorian)
        // Months elapsed since the start (an integer — the fraction of a month is ignored).
        let comps = calendar.dateComponents([.month], from: loan.startDate, to: reference)
        let rawMonths = comps.month ?? 0
        let isPending = rawMonths < 0
        let n = loan.durationMonths
        let d = max(0, loan.deferralMonths)
        let totalDuration = (loan.loanType == .deferredTotal || loan.loanType == .deferredPartial)
            ? n + 0  // n already includes the deferral in our conventions
            : n
        let monthsElapsed = max(0, min(rawMonths, totalDuration))
        let isCompleted = rawMonths >= totalDuration

        // REVOLVING: no math. Principal = the entered value (kept up to date by the user).
        if loan.loanType == .revolving {
            return LoanState(
                remainingCapital: loan.principal,
                monthlyPayment: 0,
                interestsPaid: 0,
                capitalPaid: 0,
                monthsElapsed: monthsElapsed,
                isPending: isPending,
                isCompleted: false  // a revolving loan is never "finished" by construction
            )
        }

        // If not started yet → the full principal, no amortization.
        if isPending {
            let initialMonthly = initialMonthlyPayment(loan: loan)
            return LoanState(
                remainingCapital: loan.principal,
                monthlyPayment: initialMonthly,
                interestsPaid: 0,
                capitalPaid: 0,
                monthsElapsed: 0,
                isPending: true,
                isCompleted: false
            )
        }

        // If finished → everything repaid (except IN_FINE, which repays in one block at n).
        if isCompleted {
            return LoanState(
                remainingCapital: 0,
                monthlyPayment: 0,
                interestsPaid: totalInterestsAtCompletion(loan: loan),
                capitalPaid: loan.principal,
                monthsElapsed: totalDuration,
                isPending: false,
                isCompleted: true
            )
        }

        let i = loan.annualRate / 12.0
        let k = monthsElapsed
        let P = loan.principal

        switch loan.loanType {

        case .revolving:
            // Already handled at the top of the function, the compiler requires this branch.
            return LoanState(remainingCapital: P, monthlyPayment: 0, interestsPaid: 0,
                             capitalPaid: 0, monthsElapsed: 0, isPending: false, isCompleted: false)

        case .amortizing:
            return amortizingState(P: P, i: i, n: n, k: k)

        case .inFine:
            // Constant principal until maturity, interest-only paid every month.
            let monthly = P * i
            let interests = monthly * Double(k)
            return LoanState(
                remainingCapital: P,
                monthlyPayment: monthly,
                interestsPaid: interests,
                capitalPaid: 0,
                monthsElapsed: k,
                isPending: false,
                isCompleted: false
            )

        case .deferredTotal:
            // During the deferral: interest is capitalized, M = 0.
            // Afterward: classic amortization over (n − d) months with a new principal P'.
            if k < d {
                let capitalized = P * pow(1 + i, Double(k))
                return LoanState(
                    remainingCapital: capitalized,
                    monthlyPayment: 0,
                    interestsPaid: capitalized - P,  // interest capitalized but not paid
                    capitalPaid: 0,
                    monthsElapsed: k,
                    isPending: false,
                    isCompleted: false
                )
            }
            let pPrime = P * pow(1 + i, Double(d))
            let nPrime = n - d
            return amortizingState(P: pPrime, i: i, n: nPrime, k: k - d, prePaidInterests: pPrime - P)

        case .deferredPartial:
            // During the deferral: a constant principal, the payment = interest only.
            // Afterward: classic amortization over (n − d) months with P (unchanged).
            if k < d {
                let monthly = P * i
                return LoanState(
                    remainingCapital: P,
                    monthlyPayment: monthly,
                    interestsPaid: monthly * Double(k),
                    capitalPaid: 0,
                    monthsElapsed: k,
                    isPending: false,
                    isCompleted: false
                )
            }
            let nPrime = n - d
            return amortizingState(
                P: P,
                i: i,
                n: nPrime,
                k: k - d,
                prePaidInterests: P * i * Double(d)
            )
        }
    }

    // MARK: - Private helpers

    /// Computes a classic fixed-payment amortization state at month k (over n months).
    /// `prePaidInterests` adds interest already paid or capitalized (a deferral).
    private static func amortizingState(P: Double, i: Double, n: Int, k: Int,
                                        prePaidInterests: Double = 0) -> LoanState {
        guard P > 0, n > 0 else {
            return LoanState(remainingCapital: 0, monthlyPayment: 0, interestsPaid: prePaidInterests,
                             capitalPaid: 0, monthsElapsed: k, isPending: false, isCompleted: true)
        }

        // Special case: a zero rate → the payment = P/n, the principal decreases linearly.
        if i == 0 {
            let monthly = P / Double(n)
            let capitalPaid = monthly * Double(k)
            let remaining = max(0, P - capitalPaid)
            return LoanState(
                remainingCapital: remaining,
                monthlyPayment: monthly,
                interestsPaid: prePaidInterests,
                capitalPaid: capitalPaid,
                monthsElapsed: k,
                isPending: false,
                isCompleted: remaining == 0
            )
        }

        let factor = pow(1 + i, Double(n))
        let monthly = P * i * factor / (factor - 1)

        let growth = pow(1 + i, Double(k))
        // CR(k) = P · (1+i)^k − M · ((1+i)^k − 1) / i
        var remaining = P * growth - monthly * (growth - 1) / i
        if remaining < 0.005 { remaining = 0 }
        if remaining > P { remaining = P }

        let capitalPaid = max(0, P - remaining)
        let totalPaid = monthly * Double(k)
        let interestsThisPhase = max(0, totalPaid - capitalPaid)

        return LoanState(
            remainingCapital: remaining,
            monthlyPayment: monthly,
            interestsPaid: prePaidInterests + interestsThisPhase,
            capitalPaid: capitalPaid,
            monthsElapsed: k,
            isPending: false,
            isCompleted: remaining == 0
        )
    }

    /// The payment at the loan's start (month 1) — useful to show an
    /// indicative amount in the form when there's no history yet.
    /// (`deferralMonths` isn't read anywhere here: for DEFERRED_TOTAL the
    /// initial payment is 0 by construction, and for DEFERRED_PARTIAL
    /// interest-only on the unchanged P is returned — no need for the number of months.)
    private static func initialMonthlyPayment(loan: PatrimoineLoan) -> Double {
        let i = loan.annualRate / 12.0
        let n = loan.durationMonths
        let P = loan.principal
        switch loan.loanType {
        case .revolving:
            return 0
        case .amortizing:
            return classicMonthly(P: P, i: i, n: n)
        case .inFine:
            return P * i
        case .deferredTotal:
            // Month 1: no payment (still within the deferral).
            return 0
        case .deferredPartial:
            return P * i  // interest only
        }
    }

    private static func classicMonthly(P: Double, i: Double, n: Int) -> Double {
        guard P > 0, n > 0 else { return 0 }
        if i == 0 { return P / Double(n) }
        let factor = pow(1 + i, Double(n))
        return P * i * factor / (factor - 1)
    }

    /// The total interest paid over the whole duration — used when the loan is
    /// finished to show a consistent total instead of 0.
    private static func totalInterestsAtCompletion(loan: PatrimoineLoan) -> Double {
        let i = loan.annualRate / 12.0
        let n = loan.durationMonths
        let d = max(0, loan.deferralMonths)
        let P = loan.principal
        switch loan.loanType {
        case .revolving:
            return 0
        case .amortizing:
            let M = classicMonthly(P: P, i: i, n: n)
            return max(0, M * Double(n) - P)
        case .inFine:
            return P * i * Double(n)
        case .deferredTotal:
            let pPrime = P * pow(1 + i, Double(d))
            let M = classicMonthly(P: pPrime, i: i, n: n - d)
            // Interest = interest capitalized during the deferral + interest paid afterward
            return (pPrime - P) + max(0, M * Double(n - d) - pPrime)
        case .deferredPartial:
            let M = classicMonthly(P: P, i: i, n: n - d)
            return P * i * Double(d) + max(0, M * Double(n - d) - P)
        }
    }
}
