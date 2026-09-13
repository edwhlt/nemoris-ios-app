import Foundation

// MARK: - DashboardPeriod
//
// The time window shown by the Dashboard. Replaces the date helpers that
// used to live in `AnnualDashboardViewModel`.
//
// ⚠️ The month is parsed BY HAND rather than with the global
// `dashboardMonthParser`: a `DateFormatter` is a shared mutable class, so not
// `Sendable`, and this structure crosses the builder's `Task.detached` boundary.

struct DashboardPeriod: Hashable, Sendable {
    /// The displayed fiscal year.
    var year: Int
    /// Month filter in "yyyy-MM" format. `nil` = the whole year.
    var month: String?

    private var calendar: Calendar { Calendar.current }

    var yearFrom: Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
    }

    var yearTo: Date {
        calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? Date()
    }

    var previousYearFrom: Date? {
        calendar.date(from: DateComponents(year: year - 1, month: 1, day: 1))
    }

    var previousYearTo: Date? {
        calendar.date(from: DateComponents(year: year - 1, month: 12, day: 31))
    }

    /// Start of the detail window (categories / tags): the filtered month if
    /// there is one, the whole year otherwise.
    var filterFrom: Date { monthStart ?? yearFrom }

    var filterTo: Date {
        guard let start = monthStart else { return yearTo }
        return calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
    }

    /// Readable label of the filtered month ("July 2026"), `nil` if there's no filter.
    ///
    /// Locale hardcoded (fr_FR): this type is a pure struct with no access to
    /// the SwiftUI environment (project doctrine), so `.formatted()` would
    /// otherwise fall back to the device's ACTUAL locale instead of French — the
    /// same precedent as `PatrimoineView.swift`.
    var monthLabel: String? {
        monthStart?.formatted(.dateTime.month(.wide).year().locale(AppLocalization.locale))
    }

    private var monthStart: Date? {
        guard let month else { return nil }
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: 1))
    }
}

// MARK: - DashboardSource
//
// A RAW piece of data read from the database. This is the grain of deduplication: each
// source is fetched **exactly once** per pass, regardless of how many aggregates
// consume it.
//
// Before this split, the month's transactions were loaded twice per
// `load()` (the Budget banner + AlertEngine) and investments'
// `fetchAccounts()` three times. Deduplication was only a convention; it's now
// structural.

enum DashboardSource: String, Sendable, CaseIterable {
    case yearMonthlyTotals
    case previousYearMonthlyTotals
    case categoryTotals
    case tagTotals
    case activeEnvelopes
    case monthTransactions
    case categories
    case investmentAccounts
    case bankAccounts
    /// Balances of the accounts linked to a Patrimoine asset. Derived: depends on
    /// `patrimoineAssets` + `bankAccounts`, so fetched after them.
    case bankBalances
    case patrimoineAssets
    case patrimoineRealEstate
    case patrimoineLoans
    case goals
}

// MARK: - DashboardAggregate
//
// A piece of data READY TO DISPLAY. This is the unit of demand: a card declares which
// aggregates it needs, and the builder only computes those — a hidden card
// therefore costs no query at all.

enum DashboardAggregate: String, Sendable, CaseIterable {
    /// The year's monthly series + totals + N-1 comparison (the hero and the monthly chart).
    case yearSeries
    case categoryBreakdown
    case tagBreakdown
    case budgetEnvelopes
    case investments
    case patrimoine
    case alerts
    case insights
    /// Pending Apple Pay expenses (the Shortcuts automation, see
    /// `PendingApplePayRepository`). A direct and already cheap query (a
    /// handful of rows): no dedicated `DashboardSource`, the same treatment
    /// as `.insights`, which also does its own direct access.
    case pendingApplePay

    /// Heavy aggregates, computed in a second, low-priority pass so the
    /// rest of the screen can show up without waiting for them.
    var isExpensive: Bool {
        self == .insights
    }

    /// Other aggregates this one needs (an aggregate-level dependency, not a source one).
    var requires: Set<DashboardAggregate> {
        switch self {
        case .alerts: return [.budgetEnvelopes]   // alerts read EnvelopeProgress
        default:      return []
        }
    }

    var sources: Set<DashboardSource> {
        switch self {
        case .yearSeries:
            return [.yearMonthlyTotals, .previousYearMonthlyTotals]
        case .categoryBreakdown:
            return [.categoryTotals]
        case .tagBreakdown:
            return [.tagTotals]
        case .budgetEnvelopes:
            return [.activeEnvelopes, .monthTransactions, .categories]
        case .investments:
            return [.investmentAccounts]
        case .patrimoine:
            return [.patrimoineAssets, .patrimoineRealEstate, .patrimoineLoans,
                    .bankAccounts, .bankBalances, .investmentAccounts]
        case .alerts:
            return [.goals, .patrimoineAssets, .bankAccounts, .investmentAccounts]
        case .insights:
            return []   // InsightEngine does its own 180-day scan
        case .pendingApplePay:
            return []   // a direct query on pending_apple_pay_entries
        }
    }

    /// Evaluation order: aggregates other ones depend on come first.
    static let evaluationOrder: [DashboardAggregate] = [
        .yearSeries, .categoryBreakdown, .tagBreakdown,
        .investments, .patrimoine,
        .budgetEnvelopes,   // before .alerts
        .alerts, .insights, .pendingApplePay
    ]

    /// Aggregates needed by the Dashboard's FIXED elements (the hero, the alert
    /// banner, the "Overview" banner). Always requested, whatever cards
    /// are shown.
    static let fixedElements: Set<DashboardAggregate> = [
        .yearSeries,        // hero : mois dominant + cumul annuel + variation N-1
        .alerts,            // AlertsBanner
        .investments,       // the "Invested" column of the banner
        .patrimoine,        // the "Patrimoine" column
        .budgetEnvelopes,   // the "Envelopes" column (and alerts' dependency)
        .pendingApplePay    // bandeau Apple Pay en attente
    ]

    /// Completes a requested set with its transitive dependencies.
    static func expanded(_ units: Set<DashboardAggregate>) -> Set<DashboardAggregate> {
        var result = units
        var changed = true
        while changed {
            changed = false
            for unit in result {
                let missing = unit.requires.subtracting(result)
                if !missing.isEmpty {
                    result.formUnion(missing)
                    changed = true
                }
            }
        }
        return result
    }
}

// MARK: - DashboardSnapshot
//
// The result. **One optional field per aggregate**: `nil` means "not requested or
// not computed yet", which lets each card show its own skeleton
// instead of the whole screen's all-or-nothing skeleton.

struct DashboardSnapshot: Sendable {
    var monthlySeries: [MonthlyTotals]?
    var stats: DashboardStats?
    var previousYearStats: DashboardStats?
    var categoryTotals: [CategoryTotal]?
    var tagTotals: [TagTotal]?
    /// Envelope progressions — consumed by both the budget recap AND the alerts.
    var envelopeProgresses: [EnvelopeProgress]?
    var budget: BudgetRecap?
    var investments: InvestmentsRecap?
    var patrimoine: PatrimoineSnapshot?
    var alerts: [Alert]?
    var insights: [Insight]?
    /// Count and total (positive, already `abs`) of Apple Pay expenses still
    /// `pending`. `nil` = not computed yet — distinct from `0` (none pending).
    var pendingApplePayCount: Int?
    var pendingApplePayTotal: Double?

    /// Merges a partial pass: only the fields that are set overwrite ours.
    /// This is what lets the heavy pass (insights) arrive afterward without
    /// erasing what the light pass has already published.
    func merging(_ other: DashboardSnapshot) -> DashboardSnapshot {
        var result = self
        if let v = other.monthlySeries      { result.monthlySeries = v }
        if let v = other.stats              { result.stats = v }
        if let v = other.previousYearStats  { result.previousYearStats = v }
        if let v = other.categoryTotals     { result.categoryTotals = v }
        if let v = other.tagTotals          { result.tagTotals = v }
        if let v = other.envelopeProgresses { result.envelopeProgresses = v }
        if let v = other.budget             { result.budget = v }
        if let v = other.investments        { result.investments = v }
        if let v = other.patrimoine         { result.patrimoine = v }
        if let v = other.alerts             { result.alerts = v }
        if let v = other.insights           { result.insights = v }
        if let v = other.pendingApplePayCount { result.pendingApplePayCount = v }
        if let v = other.pendingApplePayTotal { result.pendingApplePayTotal = v }
        return result
    }
}

// MARK: - DashboardCacheKey

/// Identifies a computation pass. The `refreshToken` is `AppState.dataRefreshToken`,
/// already bumped by the app on every data mutation — nothing new to invent.
///
/// ⚠️ The Dashboard must NEVER bump this token itself: a documented infinite-loop
/// precedent in `InvestmentsView`.
struct DashboardCacheKey: Hashable, Sendable {
    let refreshToken: UUID
    let period: DashboardPeriod

    /// A key specific to an aggregate, restricted to what it actually depends on.
    func unitKey(for unit: DashboardAggregate) -> DashboardUnitKey {
        DashboardUnitKey(refreshToken: refreshToken, scope: unit.scope(for: period))
    }
}

/// What an aggregate's result actually depends on.
///
/// Without this distinction, toggling the chart's month filter would also recompute
/// the budget, the patrimoine, the alerts and the insights — even though none of them
/// look at the displayed month. The old `toggleMonth` only ever refetched
/// categories and tags; this split preserves that behavior.
enum DashboardAggregateScope: Hashable, Sendable {
    /// Independent of the displayed period (the current month, "now", etc.).
    case global
    case year(Int)
    case period(DashboardPeriod)
}

struct DashboardUnitKey: Hashable, Sendable {
    let refreshToken: UUID
    let scope: DashboardAggregateScope
}

extension DashboardAggregate {
    func scope(for period: DashboardPeriod) -> DashboardAggregateScope {
        switch self {
        case .categoryBreakdown, .tagBreakdown:
            return .period(period)
        case .yearSeries:
            return .year(period.year)
        case .budgetEnvelopes, .investments, .patrimoine, .alerts, .insights, .pendingApplePay:
            return .global
        }
    }
}
