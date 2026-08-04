import SwiftUI

// MARK: - DashboardCardContext
//
// Ce dont une carte a besoin **en plus** du snapshot : la période affichée (que
// certaines cartes montrent en sous-titre ou pilotent, comme le filtre mois du
// graphe) et la navigation vers les modules.

struct DashboardCardContext {
    @Binding var period: DashboardPeriod
    let onNavigate: (MainTabItem) -> Void

    /// Sous-titre de période, partagé par les cartes qui affichent un agrégat borné
    /// dans le temps (« Sur juillet 2026 » / « Sur l'année 2026 »).
    var periodSubtitle: String {
        period.monthLabel.map { "Sur \($0)" } ?? "Sur l'année \(period.year)"
    }
}

// MARK: - DashboardCardHost
//
// **Le** point de dispatch carte → vue. Une ligne par carte : tout le chrome (fond,
// en-tête, squelette, état vide, hauteur) est dans `DashboardTile`, et chaque
// contenu ne fait que dessiner sa donnée.
//
// Même convention que `MainTabView.tabView(for:)` pour les modules.

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
