import SwiftUI

// MARK: - DashboardCardContext
//
// What a card needs **in addition to** the snapshot: the displayed period (which
// some cards show as a subtitle or drive, like the chart's month filter)
// and navigation to the modules.

struct DashboardCardContext {
    @Binding var period: DashboardPeriod
    let onNavigate: (MainTabItem) -> Void

    /// A period subtitle, shared by cards that show a time-bounded aggregate
    /// ("For July 2026" / "For the year 2026").
    var periodSubtitle: LocalizedStringResource {
        period.monthLabel.map { "Sur \($0)" } ?? "Sur l'année \(period.year.yearLabel)"
    }
}

// MARK: - DashboardCardHost
//
// **The** card → view dispatch point. One line per card: all the chrome (background,
// header, skeleton, empty state, height) is in `DashboardTile`, and each
// content just draws its own data.
//
// The same convention as `MainTabView.tabView(for:)` for modules.

struct DashboardCardHost: View {
    let preference: DashboardCardPreference
    let snapshot: DashboardSnapshot
    let context: DashboardCardContext

    var body: some View {
        switch preference.card {
        case .insightsCoach:
            InsightsCoachCard(insights: snapshot.insights, size: preference.size)
        case .budgetEnvelopes:
            BudgetEnvelopesCard(progresses: snapshot.envelopeProgresses, size: preference.size, context: context)
        case .netWorth:
            NetWorthCard(snapshot: snapshot.patrimoine, size: preference.size, context: context)
        case .monthlyFlow:
            MonthlyFlowCard(series: snapshot.monthlySeries, size: preference.size, context: context)
        case .topCategories:
            TopCategoriesCard(totals: snapshot.categoryTotals, size: preference.size, context: context)
        case .tags:
            TagsCard(totals: snapshot.tagTotals, size: preference.size, context: context)
        case .investments:
            InvestmentsCard(recap: snapshot.investments, size: preference.size, context: context)
        }
    }
}
