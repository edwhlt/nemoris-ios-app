import Foundation

// MARK: - InvestmentsRecap
//
// Mini summary of financial holdings, for the Dashboard's "Overview" banner.
// Monthly history is NOT stored here — the sparkline stays optional (costly
// on-the-fly computation on the Investments side); the aim here is zero
// overhead.
//
// Lives in the Investments module: it owns the rule "an active account =
// valuation OR cash > 0", and the Dashboard has no business redefining it.
//
// Built **only** from `InvestmentRepository.fetchAccounts()`, which does the
// computation in ONE SELECT with a CTE. Never go through
// `InvestmentsViewModel` for this: its `load()` fires one query per account,
// each position's price history and the sparklines.

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

    /// Aggregates the investment accounts.
    ///
    /// Empty accounts are excluded: live sync can create "ghost" accounts with no
    /// order at all, which would inflate the count without adding anything.
    ///
    /// `totalCurrentValue` **includes cash** (`cashBalance`) — it's the account's
    /// value in the net-worth sense. The Investments module exposes cash
    /// separately via `portfolioTotalCash`; the two figures therefore
    /// legitimately differ, and this asymmetry is intentional.
    static func from(accounts: [InvestmentAccount]) -> InvestmentsRecap {
        let actives = accounts.filter { $0.currentValue > 0 || $0.cashBalance > 0 }
        guard !actives.isEmpty else { return .empty }
        return InvestmentsRecap(
            totalCurrentValue: actives.reduce(0.0) { $0 + $1.currentValue + $1.cashBalance },
            totalInvested: actives.reduce(0.0) { $0 + $1.investedAmount },
            activeAccountCount: actives.count
        )
    }
}
