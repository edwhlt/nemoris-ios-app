import Foundation

// MARK: - Enums

enum RecurrenceFrequency: String, CaseIterable, Identifiable {
    case daily      = "DAILY"
    case weekly     = "WEEKLY"
    case biweekly   = "BIWEEKLY"    // biweekly: roughly every 2 weeks
    case monthly    = "MONTHLY"
    case quarterly  = "QUARTERLY"   // quarterly: every 3 months
    case semiannual = "SEMIANNUAL"  // semiannual: every 6 months
    case yearly     = "YEARLY"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:      return "Quotidien"
        case .weekly:     return "Hebdomadaire"
        case .biweekly:   return "Bimensuel"
        case .monthly:    return "Mensuel"
        case .quarterly:  return "Trimestriel"
        case .semiannual: return "Semestriel"
        case .yearly:     return "Annuel"
        }
    }

    var systemImage: String {
        switch self {
        case .daily:      return "sun.min"
        case .weekly:     return "calendar.badge.clock"
        case .biweekly:   return "calendar.badge.clock"
        case .monthly:    return "calendar"
        case .quarterly:  return "calendar"
        case .semiannual: return "calendar"
        case .yearly:     return "calendar.badge.checkmark"
        }
    }

    /// Approximate number of days between two occurrences
    var approximateDays: Int {
        switch self {
        case .daily:      return 1
        case .weekly:     return 7
        case .biweekly:   return 14
        case .monthly:    return 30
        case .quarterly:  return 91
        case .semiannual: return 182
        case .yearly:     return 365
        }
    }

    /// Number of months between two occurrences for frequencies based on
    /// a fixed day of the month (MONTHLY/QUARTERLY/SEMIANNUAL share the
    /// same projection logic, only the step changes).
    var monthStep: Int? {
        switch self {
        case .monthly:    return 1
        case .quarterly:  return 3
        case .semiannual: return 6
        default:          return nil
        }
    }

    /// true if the relevant anchor is a day of the month (1-31)
    var usesDayOfMonthAnchor: Bool { monthStep != nil }

    /// true if the relevant anchor is an ISO day of the week (1=Monday)
    var usesWeekdayAnchor: Bool {
        self == .weekly || self == .biweekly
    }
}

enum PrevisionStatus: String, CaseIterable {
    case pending = "PENDING"   // A venir, non confirme
    case matched = "MATCHED"   // Matched to a real transaction
    case skipped = "SKIPPED"   // Ignore manuellement

    var label: String {
        switch self {
        case .pending: return "Attendu"
        case .matched: return "Confirme"
        case .skipped: return "Ignore"
        }
    }
}

enum BudgetPeriod: String, CaseIterable {
    case monthly = "MONTHLY"
    case yearly  = "YEARLY"

    var label: String {
        switch self {
        case .monthly: return "Mensuel"
        case .yearly:  return "Annuel"
        }
    }
}

// MARK: - Core Models

/// A recurring pattern, detected or entered manually (subscription, rent, salary, etc.)
struct RecurringPattern: Identifiable, Hashable {
    let id: Int
    var name: String
    /// Montant moyen observe (negatif = depense, positif = revenu)
    var amountAvg: Double
    /// Tolerance de variation en % (0.15 = +/-15 %)
    var amountTolerance: Double
    var categoryId: Int?
    var payeeId: Int?
    var frequency: RecurrenceFrequency
    /// Anchor day: day of the month (1-31) for MONTHLY, or ISO weekday (1=Monday) for WEEKLY
    var anchorDay: Int?
    var isActive: Bool
    /// true if created manually by the user
    var isManual: Bool
    var createdAt: Date
    var lastDetectedAt: Date?
    /// Date from which previsions are generated (start of the contract, the subscription, etc.)
    var startDate: Date
    /// Optional end date. nil = no end.
    var endDate: Date?

    var isExpense: Bool { amountAvg < 0 }
    var displayAmount: Double { abs(amountAvg) }
}

/// A budget envelope: a spending cap allocated to a category over a period
struct BudgetEnvelope: Identifiable, Hashable {
    let id: Int
    var name: String
    var categoryId: Int?
    var amount: Double
    var period: BudgetPeriod
    var startDate: Date
    var isActive: Bool
}

/// A forecasted due date of a recurring pattern
struct BudgetPrevision: Identifiable, Hashable {
    let id: Int
    var recurringPatternId: Int?
    var amount: Double
    var expectedDate: Date
    var status: PrevisionStatus
    var actualTransactionId: Int?
    var notes: String?

    var isExpense: Bool { amount < 0 }
    var displayAmount: Double { abs(amount) }
}

// MARK: - Aggregates

/// A prevision enriched with its parent pattern's info, for display
struct EnrichedPrevision: Identifiable {
    let prevision: BudgetPrevision
    let patternName: String
    let categoryName: String?
    let frequency: RecurrenceFrequency

    var id: Int { prevision.id }
    var amount: Double { prevision.amount }
    var expectedDate: Date { prevision.expectedDate }
    var status: PrevisionStatus { prevision.status }
    var isExpense: Bool { amount < 0 }
    var displayAmount: Double { abs(amount) }
}

/// An envelope's health state over the period. The thresholds live HERE and
/// nowhere else — before, every screen redid its own ratio comparison.
enum EnvelopeHealth {
    case healthy   // < 80% of the budget used
    case warning   // 80 % … 100 %
    case exceeded  // > 100 %
}

/// Summary of a budget envelope for a given month
struct EnvelopeProgress: Identifiable {
    let envelope: BudgetEnvelope
    let categoryName: String
    let categoryIcon: String
    let spent: Double          // Actual total spent (positive)
    let allocated: Double      // Allocated budget (positive)
    let recurringSpent: Double // Portion coming from confirmed recurring items (positive)
    let forecasted: Double     // Total planned (this month's active previsions for this category)

    var id: Int { envelope.id }
    var variableSpent: Double { max(spent - recurringSpent, 0) }
    var remaining: Double { allocated - spent }
    /// ⚠️ Clamped to 1.0 — this is a **progress-bar width**, not a measurement.
    /// To rank/compare, use `rawRatio` or `healthState`.
    var ratio: Double { allocated > 0 ? min(spent / allocated, 1.0) : 0 }
    /// The real, unclamped ratio. Without it, going over budget is undetectable via `ratio`.
    var rawRatio: Double { allocated > 0 ? spent / allocated : 0 }
    var recurringRatio: Double { allocated > 0 ? min(recurringSpent / allocated, 1.0) : 0 }
    var forecastedRatio: Double { allocated > 0 ? min(forecasted / allocated, 1.0) : 0 }
    var isOverBudget: Bool { spent > allocated }
    var forecastExceedsBudget: Bool { forecasted > allocated }

    var healthState: EnvelopeHealth {
        if isOverBudget { return .exceeded }
        if rawRatio >= 0.8 { return .warning }
        return .healthy
    }
}

/// Monthly budget summary (for the dashboard)
struct MonthlyBudgetSummary {
    let month: String               // "2025-01"
    let forecastedExpenses: Double  // Sum of the month's forecasted expenses
    let actualExpenses: Double      // The month's actual expenses
    let matchedCount: Int
    let pendingCount: Int
    let envelopes: [EnvelopeProgress]
    let totalIncome: Double        // The month's actual income (positive)
    let fixedActual: Double        // Charges confirmees (recurrents matches, positif)

    var variableActual: Double { max(actualExpenses - fixedActual, 0) }
    var netSavings: Double { totalIncome - actualExpenses }
    var variance: Double { actualExpenses - forecastedExpenses }  // positif = depassement
    var isOverBudget: Bool { variance > 0 }
}

/// A day in the financial calendar
struct CalendarDay: Identifiable {
    let date: Date
    let previsions: [EnrichedPrevision]
    let transactions: [FinanceTransaction]

    var id: String { DateFormatter.isoDate.string(from: date) }

    var forecastedAmount: Double {
        previsions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
    }
    var actualAmount: Double {
        transactions.reduce(0) { $0 + $1.amount }
    }
    var hasEvents: Bool { !previsions.isEmpty || !transactions.isEmpty }
}

// MARK: - Helpers

private extension DateFormatter {
    static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
