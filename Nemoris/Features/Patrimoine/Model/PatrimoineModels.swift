import Foundation

// MARK: - Patrimoine — Net Worth module models
//
// 3 independent business entities (real estate, loans, assets) + their
// associated enums. Persisted via migration v37 (see DatabaseManager).
//
// Convention: every `id` is an Int (SQLite AUTOINCREMENT). Every
// date is stored in SQL as yyyy-MM-dd.

// MARK: - Kinds (associated enums)

/// A "Movable Assets & Cash" asset's functional family. Not a strict
/// constraint on the SQL side — a CASH asset linked to a checking account remains
/// valid. Mainly used for sorting and the default icon in the UI.
enum AssetKind: String, CaseIterable {
    case cash       = "CASH"       // Cash, current treasury
    case savings    = "SAVINGS"    // Livret A, LDDS, LEP, PEL, CEL…
    case investment = "INVESTMENT" // PEA, CTO, Assurance Vie, crypto
    case other      = "OTHER"

    var label: String {
        switch self {
        case .cash:       return "Liquidités"
        case .savings:    return "Épargne"
        case .investment: return "Investissements"
        case .other:      return "Autre"
        }
    }

    var systemIcon: String {
        switch self {
        case .cash:       return "banknote.fill"
        case .savings:    return "building.columns.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .other:      return "circle.grid.2x2.fill"
        }
    }
}

/// A loan's type — determines the formula used to compute the remaining principal.
/// The logic lives in `LoanCalculator`.
enum LoanType: String, CaseIterable {
    case amortizing      = "AMORT"             // A fixed monthly payment, progressive amortization
    case inFine          = "IN_FINE"           // The principal repaid in one block at maturity
    case deferredTotal   = "DEFERRED_TOTAL"    // A total deferral then amortization
    case deferredPartial = "DEFERRED_PARTIAL"  // A partial deferral (interest only) then amortization
    case revolving       = "REVOLVING"         // Revolving credit, the remaining principal entered manually

    var label: String {
        switch self {
        case .amortizing:      return "Amortissable"
        case .inFine:          return "In fine"
        case .deferredTotal:   return "Différé total"
        case .deferredPartial: return "Différé partiel"
        case .revolving:       return "Renouvelable"
        }
    }

    /// Shown as creation help — explains in 1 sentence what this type implies.
    var explanation: String {
        switch self {
        case .amortizing:
            return "Prêt classique. Mensualité fixe, le capital diminue chaque mois."
        case .inFine:
            return "Seuls les intérêts sont payés mensuellement. Le capital est remboursé en une fois à l'échéance."
        case .deferredTotal:
            return "Aucun paiement pendant la période de différé (les intérêts sont capitalisés), puis amortissement classique."
        case .deferredPartial:
            return "Seuls les intérêts sont payés pendant le différé, puis amortissement classique."
        case .revolving:
            return "Crédit renouvelable (réserve d'argent). Le capital restant dû est saisi manuellement."
        }
    }
}

// MARK: - Real estate (bien immobilier)

struct PatrimoineRealEstate: Identifiable, Hashable {
    let id: Int
    var name: String
    var purchasePrice: Double
    var purchaseDate: Date
    var currentValue: Double
    /// The date of the last manual estimate. Nil = never re-estimated since the purchase.
    var estimatedAt: Date?
    var address: String?
    var notes: String?
    let createdAt: Date

    /// An estimated gross gain (excluding notary fees or renovation). This is a
    /// user estimate, not a tax calculation.
    var capitalGain: Double { currentValue - purchasePrice }

    var capitalGainPercent: Double {
        guard purchasePrice > 0 else { return 0 }
        return (currentValue - purchasePrice) / purchasePrice * 100
    }
}

// MARK: - Loan

struct PatrimoineLoan: Identifiable, Hashable {
    let id: Int
    var name: String
    var loanType: LoanType
    var principal: Double        // The initial borrowed principal
    var annualRate: Double       // Taux annuel nominal (ex 0.034 = 3.4%)
    var durationMonths: Int      // The total duration in months
    var deferralMonths: Int      // Deferral months (0 if type ≠ DEFERRED_*)
    var startDate: Date
    /// Monthly borrower's insurance (in EUR). A cost separate from the
    /// amortization payment — does NOT affect the remaining principal or the
    /// interest calculation. Shown in the form + summed into the total monthly cost.
    /// 0 if there's no insurance or the user doesn't track it separately.
    var insuranceMonthly: Double
    /// An optional link to a real-estate property (typically the loan funds this property).
    /// ON DELETE SET NULL on the SQL side — deleting the property doesn't delete the loan.
    var linkedRealEstateId: Int?
    var notes: String?
    let createdAt: Date

    /// The cumulative insurance cost over the loan's whole duration (the total cost).
    /// Indicative for the form — shows how much the insurance will "cost" in total.
    var totalInsuranceCost: Double { insuranceMonthly * Double(durationMonths) }
}

// MARK: - Asset (a "Movable Assets & Cash" item)

struct PatrimoineAsset: Identifiable, Hashable {
    let id: Int
    var name: String
    var assetKind: AssetKind

    // A soft link — at most 1 of the 2 columns is non-nil (guaranteed by partial
    // SQL UNIQUE INDEXes: an account can only be linked to 1 Patrimoine asset).
    var linkedAccountId: Int?            // A link to accounts.id (a savings account, checking, savings)
    var linkedInvestmentAccountId: Int?  // Lien vers investment_accounts.id (PEA, CTO, etc.)

    /// A value entered manually by the user. Used ONLY if no link is set.
    var manualValue: Double

    /// The last snapshot of the resolved value (read from the linked account or
    /// copied from manualValue). Kept even if the link is broken — serves as an
    /// offline fallback and a memory if the user deletes their source account.
    var lastKnownValue: Double

    var notes: String?
    let createdAt: Date

    /// True if the asset is attached to a source account (Account or InvestmentAccount).
    /// When `true` the displayed value is resolved dynamically; manual editing
    /// of the value field is disabled in the UI.
    var isLinked: Bool {
        linkedAccountId != nil || linkedInvestmentAccountId != nil
    }
}

// MARK: - Aggregated snapshot (used by the global net-worth hero)

/// An overview of total net worth at a point in time. Computed in memory by the
/// ViewModel from the 3 collections (resolved assets + real estate + loans).
/// Not persisted (for now — historical snapshots are out of MVP scope).
struct PatrimoineSnapshot {
    let totalAssets: Double        // Σ resolved assets + Σ real estate currentValue
    let totalLiabilities: Double   // Σ loans' remaining principal
    let assetsCount: Int
    let realEstateCount: Int
    let loansCount: Int

    var netWorth: Double { totalAssets - totalLiabilities }

    /// The total number of tracked items, across every category.
    var itemsCount: Int { assetsCount + realEstateCount + loansCount }

    /// False when the user hasn't entered anything in the module — the Dashboard
    /// then hides its Patrimoine block rather than showing a €0 net worth.
    var hasData: Bool { itemsCount > 0 }

    static let empty = PatrimoineSnapshot(
        totalAssets: 0,
        totalLiabilities: 0,
        assetsCount: 0,
        realEstateCount: 0,
        loansCount: 0
    )
}
