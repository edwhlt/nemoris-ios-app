import Foundation

// MARK: - TaxReportEngine
//
// Computes annual tax figures for the French tax return.
//
// **MVP — 3 sections**:
//   1. **CTO securities capital gains (box 3VG / 3UA)** — a strict FIFO
//      calculation of the year's sales, gain/loss per disposal + the annual total
//   2. **PEA tracking** — "PEA < 5 years (a taxable withdrawal)" alerts, the
//      current valuation, an estimated total amount paid in
//   3. **Property income (box 4BA / micro-foncier 4BE)** — the sum of
//      transactions categorized "Property income" (filtered on the Income
//      category + a label containing "Rent" as a fallback heuristic)
//
// **Assumed limitations**:
//   - No handling of carry-forward losses (box 3VH) — the user offsets them
//     themselves via the exports.
//   - No crypto tax handling (BIC/BNC vs. box 3AN — complex).
//   - No PEA allowance calculation based on withdrawal seniority.
//   - No CSG/CRDS handling (the user's default 17.2% is shown as info).
//
// The goal is to pre-fill 90% of the work — the user checks and transfers
// the figures onto their tax return.

struct TaxReportYear {
    let year: Int
    let ctoGains: [CTOGainEntry]
    let peaSnapshots: [PEASnapshotEntry]
    let propertyIncome: PropertyIncomeSummary
    let generatedAt: Date

    /// The year's net sum of CTO capital gains (gain - loss).
    var ctoNetGain: Double {
        ctoGains.reduce(0) { $0 + $1.gain }
    }

    /// True if there's data to report (otherwise the report is pointless).
    var hasData: Bool {
        !ctoGains.isEmpty || !peaSnapshots.isEmpty || propertyIncome.totalAmount > 0
    }
}

/// One row = a partial/full sale of a position, matched FIFO against
/// one or more earlier purchases.
struct CTOGainEntry: Identifiable, Hashable {
    var id: String { "\(positionId)_\(soldAt.timeIntervalSince1970)" }
    let positionId: Int
    let assetName: String
    let ticker: String
    let accountName: String
    /// The quantity sold (positive).
    let quantity: Double
    /// The unit sale price (€).
    let unitSalePrice: Double
    /// The FIFO weighted-average cost of the sold lots (€/unit).
    let weightedBuyPrice: Double
    /// The sale's date.
    let soldAt: Date
    /// Fees charged on this disposal (sale only — purchase fees are
    /// already baked into the weighted-average cost).
    let saleFees: Double

    /// The gross gain/loss on the disposal = (sale_price - weighted_buy_price) * qty - sale_fees
    var gain: Double {
        (unitSalePrice - weightedBuyPrice) * quantity - saleFees
    }

    /// The disposal's amount = unitSalePrice × quantity.
    var saleAmount: Double { unitSalePrice * quantity }
}

/// A PEA account's snapshot at year-end (informational — for a withdrawal decision).
struct PEASnapshotEntry: Identifiable, Hashable {
    var id: Int { accountId }
    let accountId: Int
    let accountName: String
    let openedAt: Date
    let currentValue: Double
    let totalInvested: Double
    /// Years since the PEA was opened. Determines the withdrawal's tax treatment:
    /// <5 years = closure + taxation, ≥5 years = withdrawals possible, ≥8 years = annuity
    /// payouts possible.
    var ageYears: Int {
        Calendar.current.dateComponents([.year], from: openedAt, to: Date()).year ?? 0
    }

    /// A tax warning based on age.
    var taxStatusLabel: LocalizedStringResource {
        if ageYears < 5 { return "Retrait avant 5 ans : clôture obligatoire + IR" }
        if ageYears < 8 { return "Retraits possibles (5-8 ans, sans clôture)" }
        return "8 ans+ : retraits/rentes exonérés (hors prélèvements sociaux)"
    }
}

/// A recap of the year's property income — the sum of transactions categorized
/// "Rent received" / "Property income".
struct PropertyIncomeSummary {
    let year: Int
    let totalAmount: Double
    let entriesCount: Int

    /// Beyond €15,000 → the actual-expenses regime is mandatory; below → the micro-foncier
    /// regime is possible (a 30% allowance). The user is informed.
    var suggestedRegime: String {
        totalAmount > 15000
            ? "Régime réel obligatoire (> 15 000 €)"
            : "Micro-foncier possible (abattement 30 %)"
    }
}

enum TaxReportEngine {

    /// Generates the tax report for a given year.
    /// - Parameters:
    ///   - invRepo, txRepo: repositories, defaulting to the
    ///     app's database. Tests inject them against a temporary database — a
    ///     capital gain's FIFO calculation can't be verified otherwise.
    static func generate(year: Int,
                         invRepo: InvestmentRepository = InvestmentRepository(),
                         txRepo: TransactionRepository = TransactionRepository()) -> TaxReportYear {
        let cal = Calendar(identifier: .gregorian)
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd   = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        else {
            return TaxReportYear(year: year, ctoGains: [], peaSnapshots: [], propertyIncome: .init(year: year, totalAmount: 0, entriesCount: 0), generatedAt: Date())
        }

        let ctoGains = computeCTOGains(year: year, yearStart: yearStart, yearEnd: yearEnd, invRepo: invRepo)
        let peaSnapshots = computePEASnapshots(invRepo: invRepo)
        let propertyIncome = computePropertyIncome(year: year, yearStart: yearStart, yearEnd: yearEnd, txRepo: txRepo)

        return TaxReportYear(
            year: year,
            ctoGains: ctoGains,
            peaSnapshots: peaSnapshots,
            propertyIncome: propertyIncome,
            generatedAt: Date()
        )
    }

    // MARK: - 1. Plus-values CTO FIFO

    /// For each CTO account, its positions and their orders are taken, sorted
    /// chronologically, and FIFO is applied: each SELL consumes the oldest
    /// BUYs until its quantity is exhausted.
    private static func computeCTOGains(year: Int, yearStart: Date, yearEnd: Date,
                                        invRepo: InvestmentRepository) -> [CTOGainEntry] {
        let accounts = invRepo.fetchAccounts().filter { $0.accountType == "CTO" }
        var result: [CTOGainEntry] = []

        for account in accounts {
            let positions = invRepo.fetchPositions(accountId: account.id)
            for position in positions {
                let orders = invRepo.fetchOrders(positionId: position.id)
                    .sorted { $0.executedAt < $1.executedAt }

                // Purchase lots awaiting FIFO consumption.
                // Each lot: (remaining quantity, average unit price including allocated fees)
                var buyLots: [(qty: Double, unitCost: Double)] = []

                for order in orders {
                    if order.orderType == .buy {
                        // Unit cost = price + fees allocated over the quantity
                        let unitCost = order.unitPrice + (order.fees / max(order.quantity, 0.000001))
                        buyLots.append((qty: order.quantity, unitCost: unitCost))
                    } else if order.orderType == .sell {
                        // Consomme FIFO
                        var remainingToSell = order.quantity
                        var totalCostBasis: Double = 0
                        while remainingToSell > 0 && !buyLots.isEmpty {
                            let lot = buyLots[0]
                            let taken = min(lot.qty, remainingToSell)
                            totalCostBasis += taken * lot.unitCost
                            remainingToSell -= taken
                            if taken >= lot.qty {
                                buyLots.removeFirst()
                            } else {
                                buyLots[0] = (qty: lot.qty - taken, unitCost: lot.unitCost)
                            }
                        }
                        let consumed = order.quantity - remainingToSell
                        // The entry is only created if the sale falls within the target year
                        if order.executedAt >= yearStart, order.executedAt <= yearEnd, consumed > 0 {
                            let weightedBuyPrice = totalCostBasis / consumed
                            result.append(CTOGainEntry(
                                positionId: position.id,
                                assetName: position.assetName,
                                ticker: position.ticker,
                                accountName: account.name,
                                quantity: consumed,
                                unitSalePrice: order.unitPrice,
                                weightedBuyPrice: weightedBuyPrice,
                                soldAt: order.executedAt,
                                saleFees: order.fees
                            ))
                        }
                    }
                    // DIV / other: ignored for capital gains (dividends have their
                    // own box 2DC, not covered in the MVP).
                }
            }
        }
        return result.sorted { $0.soldAt < $1.soldAt }
    }

    // MARK: - 2. Snapshot PEA

    private static func computePEASnapshots(invRepo: InvestmentRepository) -> [PEASnapshotEntry] {
        let peas = invRepo.fetchAccounts().filter { $0.accountType == "PEA" }
        return peas.map { acc in
            PEASnapshotEntry(
                accountId: acc.id,
                accountName: acc.name,
                openedAt: acc.openedAt,
                currentValue: acc.currentValue + acc.cashBalance,
                totalInvested: acc.investedAmount
            )
        }
    }

    // MARK: - 3. Property income

    /// A heuristic: takes the year's income transactions (amount > 0) whose
    /// label OR category OR payee contains "loyer" (rent, case-insensitive).
    /// A good approximation for most landlords.
    private static func computePropertyIncome(year: Int, yearStart: Date, yearEnd: Date,
                                              txRepo: TransactionRepository) -> PropertyIncomeSummary {
        let txs = txRepo.fetchTransactionsAllAccounts(
            from: yearStart, to: yearEnd, limit: 10000, offset: 0
        )
        let keyword = "loyer"
        let rentals = txs.filter { tx in
            guard tx.amount > 0 else { return false }
            let lowerName = tx.tiersName.lowercased()
            let lowerInfo = tx.information.lowercased()
            let lowerCat = tx.categoryName.lowercased()
            return lowerName.contains(keyword)
                || lowerInfo.contains(keyword)
                || lowerCat.contains(keyword)
        }
        let total = rentals.reduce(0.0) { $0 + $1.amount }
        return PropertyIncomeSummary(
            year: year,
            totalAmount: total,
            entriesCount: rentals.count
        )
    }
}
