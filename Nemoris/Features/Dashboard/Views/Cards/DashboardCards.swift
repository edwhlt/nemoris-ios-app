import SwiftUI
import Charts
import TipKit

// MARK: - Dashboard cards
//
// Each card draws ONLY its own data: the background, header, skeleton and
// empty state are provided by `DashboardTile`.
//
// Shared convention: the data arrives as an optional from the snapshot. `nil` = not
// computed yet → a skeleton; empty = computed but nothing to show → an empty state.

// MARK: - Coach financier

/// The 3 most important recommendations, ACROSS EVERY COACH.
///
/// ⚠️ The arbitration between "spending" and "investment" does NOT happen here:
/// it lives in `CoachRanker` (a pure engine), so the Dashboard and a
/// coach's own screen rank things exactly the same way.
///
/// Fallback: as long as no AI analysis has run (no backend configured,
/// first use), the card shows `InsightEngine`'s deterministic insights. That's
/// the app's offline-first doctrine — every AI feature keeps a
/// path with no AI.
struct InsightsCoachCard: View {
    let insights: [Insight]?
    let size: DashboardCardSize
    @Environment(CoachStore.self) private var coach
    @State private var selected: CoachRecommendation?

    private var top: [CoachRecommendation] { coach.topRecommendations(limit: 3) }
    private var isAnalyzing: Bool { CoachDomain.allCases.contains { coach.isRunning($0) } }

    var body: some View {
        DashboardTile(
            card: .insightsCoach,
            size: size,
            isLoading: insights == nil && top.isEmpty && !isAnalyzing,
            isEmpty: top.isEmpty && (insights?.isEmpty ?? false) && !isAnalyzing,
            emptyMessage: "Rien à optimiser pour l'instant — revenez après quelques semaines de transactions.",
            subtitle: top.isEmpty ? "Vos meilleures pistes d'optimisation" : "Ce qui compte le plus, tous domaines confondus"
        ) {
            VStack(spacing: AppTheme.Spacing.sm) {
                if isAnalyzing && top.isEmpty {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small).tint(AppTheme.Colors.accent)
                        Text("Le coach analyse tes données…")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                    }
                }
                if top.isEmpty {
                    // `showsHeader: false` — the tile carries the title,
                    // otherwise there'd be two stacked headers.
                    InsightsCoachSection(insights: insights ?? [], showsHeader: false)
                } else {
                    ForEach(top) { reco in
                        CoachRecommendationRow(reco: reco)
                            .padding(AppTheme.Spacing.md)
                            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected = reco
                                HapticService.shared.tap()
                            }
                    }
                }
            }
        }
        .adaptivePane(item: $selected) { reco in
            CoachRecommendationPane(reco: reco)
        }
        .task {
            await coach.load()
            // An automatic, non-blocking relaunch, only if the analysis is
            // stale AND an AI is available. The Dashboard therefore never
            // TRIGGERS an unexpected cost just by being displayed.
            for domain in CoachDomain.allCases { coach.refreshIfStale(domain) }
        }
    }
}

// MARK: - Budget envelopes

struct BudgetEnvelopesCard: View {
    let progresses: [EnvelopeProgress]?
    let size: DashboardCardSize
    let context: DashboardCardContext

    /// In compact mode only what needs action is shown, otherwise the first 4.
    private var displayed: [EnvelopeProgress] {
        let all = (progresses ?? []).sorted { $0.rawRatio > $1.rawRatio }
        return Array(all.prefix(size == .compact ? 3 : 5))
    }

    var body: some View {
        DashboardTile(
            card: .budgetEnvelopes,
            size: size,
            isLoading: progresses == nil,
            isEmpty: progresses?.isEmpty ?? false,
            emptyMessage: "Aucune enveloppe active.",
            subtitle: "Mois en cours",
            onOpenModule: { context.onNavigate(.budget) }
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(displayed) { progress in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                            Text(progress.categoryName)
                                .font(AppTheme.Typography.titleSmall)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(String(format: "%.0f %%", progress.rawRatio * 100))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tint(progress))
                                .monospacedDigit()
                        }
                        // `ratio` is clamped to 1.0 — that's exactly what's wanted
                        // for a bar's width; the color carries the overspend.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(AppTheme.Colors.surfaceSecondary)
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(tint(progress))
                                    .frame(width: max(6, geo.size.width * progress.ratio), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private func tint(_ progress: EnvelopeProgress) -> Color {
        switch progress.healthState {
        case .healthy:  return AppTheme.Colors.success
        case .warning:  return AppTheme.Colors.warning
        case .exceeded: return AppTheme.Colors.danger
        }
    }
}

// MARK: - Patrimoine net

struct NetWorthCard: View {
    let snapshot: PatrimoineSnapshot?
    let size: DashboardCardSize
    let context: DashboardCardContext

    var body: some View {
        DashboardTile(
            card: .netWorth,
            size: size,
            isLoading: snapshot == nil,
            isEmpty: !(snapshot?.hasData ?? true),
            emptyMessage: "Aucun élément de patrimoine.",
            onOpenModule: { context.onNavigate(.patrimoine) }
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    MoneyText(
                        amount: snapshot.netWorth,
                        font: AppTheme.Typography.moneyMedium,
                        color: snapshot.netWorth >= 0 ? AppTheme.Colors.textPrimary : AppTheme.Colors.danger
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                    breakdownRow("Brut", amount: snapshot.totalAssets, color: AppTheme.Colors.success)
                    if snapshot.totalLiabilities > 0 {
                        breakdownRow("Dettes", amount: snapshot.totalLiabilities, color: AppTheme.Colors.danger)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownRow(_ label: LocalizedStringKey, amount: Double, color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer(minLength: 0)
            MoneyText(amount: amount, font: .system(size: 13, weight: .semibold), color: color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Investissements

struct InvestmentsCard: View {
    let recap: InvestmentsRecap?
    let size: DashboardCardSize
    let context: DashboardCardContext

    var body: some View {
        DashboardTile(
            card: .investments,
            size: size,
            isLoading: recap == nil,
            isEmpty: !(recap?.hasData ?? true),
            emptyMessage: "Aucun compte d'investissement.",
            onOpenModule: { context.onNavigate(.investments) }
        ) {
            if let recap {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    MoneyText(amount: recap.totalCurrentValue, font: AppTheme.Typography.moneyMedium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if recap.totalInvested > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: recap.pnlAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            MoneyText(
                                amount: recap.pnlAbsolute,
                                font: .system(size: 13, weight: .semibold),
                                color: recap.pnlAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger,
                                maskedPlaceholder: "••• €"
                            )
                            Text(String(format: "%@%.1f %%", recap.pnlAbsolute >= 0 ? "+" : "", recap.pnlPercent))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(recap.pnlAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }

                    Text("\(recap.activeAccountCount) compte\(recap.activeAccountCount > 1 ? "s" : "") actif\(recap.activeAccountCount > 1 ? "s" : "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
    }
}

// MARK: - Flux mensuel

struct MonthlyFlowCard: View {
    let series: [MonthlyTotals]?
    let size: DashboardCardSize
    let context: DashboardCardContext

    private let chartTip = DashboardChartTip()

    var body: some View {
        DashboardTile(
            card: .monthlyFlow,
            size: size,
            isLoading: series == nil,
            isEmpty: series?.isEmpty ?? false,
            emptyMessage: "Aucune transaction sur cet exercice.",
            subtitle: context.period.month != nil
                ? "Touchez une barre pour déselectionner"
                : "Touchez un mois pour filtrer les catégories"
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                TipView(chartTip, arrowEdge: .none)
                MonthlyBarChartView(
                    data: series ?? [],
                    selectedMonth: Binding(
                        get: { context.period.month },
                        set: { newValue in
                            let month = newValue ?? ""
                            context.period.month = (context.period.month == month) ? nil : month
                        }
                    )
                )
                if let label = context.period.monthLabel {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text("Filtre actif : \(label)")
                            .font(AppTheme.Typography.labelMedium)
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                    .onTapGesture {
                        // The Dashboard's `.task(id: cacheKey)` relaunches the computation:
                        // only the aggregates tied to the month are recomputed.
                        withAnimation(AppTheme.Animations.spring) {
                            context.period.month = nil
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Top expenses

struct TopCategoriesCard: View {
    let totals: [CategoryTotal]?
    let size: DashboardCardSize
    let context: DashboardCardContext

    /// Grouping by parent category. Local to the card: it's a momentary
    /// display preference, not a setting to persist.
    @State private var groupByParent = false

    private var expenses: [CategoryTotal] {
        let ranked = (totals ?? [])
            .filter { $0.total < 0 }
            .sorted { abs($0.total) > abs($1.total) }
        let grouped = groupByParent ? groupedByParent(Array(ranked.prefix(5))) : Array(ranked.prefix(5))
        return Array(grouped.prefix(size == .compact ? 3 : 5))
    }

    var body: some View {
        DashboardTile(
            card: .topCategories,
            size: size,
            isLoading: totals == nil,
            isEmpty: totals?.filter { $0.total < 0 }.isEmpty ?? false,
            emptyMessage: "Aucune dépense sur cette période.",
            subtitle: context.periodSubtitle
        ) {
            let maxAbs = expenses.map { abs($0.total) }.max() ?? 1
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if size == .wide {
                    Toggle("Parente", isOn: $groupByParent)
                        .toggleStyle(.button)
                        .controlSize(.mini)
                        .tint(AppTheme.Colors.accent)
                        .font(AppTheme.Typography.labelMedium)
                }
                ForEach(Array(expenses.enumerated()), id: \.element.category) { index, item in
                    rankRow(rank: index + 1, item: item, maxAbs: maxAbs)
                }
            }
        }
    }

    private func groupedByParent(_ expenses: [CategoryTotal]) -> [CategoryTotal] {
        var totals: [String: Double] = [:]
        for item in expenses {
            totals[item.parentCategory ?? item.category, default: 0] += item.total
        }
        return totals
            .map { CategoryTotal(category: $0.key, parentCategory: nil, total: $0.value) }
            .sorted { abs($0.total) > abs($1.total) }
    }

    @ViewBuilder
    private func rankRow(rank: Int, item: CategoryTotal, maxAbs: Double) -> some View {
        let ratio = maxAbs > 0 ? abs(item.total) / maxAbs : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("\(rank).")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 18, alignment: .leading)
                Text(item.category)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                MoneyText(
                    amount: item.total,
                    font: AppTheme.Typography.moneySmall,
                    color: AppTheme.Colors.danger,
                    maskedPlaceholder: "••• €"
                )
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Colors.dangerGradient)
                        .frame(width: max(6, geo.size.width * ratio), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Tags

struct TagsCard: View {
    let totals: [TagTotal]?
    let size: DashboardCardSize
    let context: DashboardCardContext

    var body: some View {
        DashboardTile(
            card: .tags,
            size: size,
            isLoading: totals == nil,
            isEmpty: totals?.isEmpty ?? false,
            emptyMessage: "Aucun tag utilisé sur cette période.",
            subtitle: context.periodSubtitle
        ) {
            DashboardFlowLayout(spacing: AppTheme.Spacing.sm) {
                ForEach((totals ?? []).prefix(size == .compact ? 6 : 15)) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.tag.displayColor)
                            .frame(width: 7, height: 7)
                        Text(item.tag.name)
                            .font(AppTheme.Typography.labelLarge)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        MoneyText(
                            amount: item.total,
                            font: AppTheme.Typography.labelMedium,
                            color: item.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success,
                            maskedPlaceholder: "•••"
                        )
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppTheme.Colors.surfaceSecondary.opacity(0.7)))
                }
            }
        }
    }
}

// MARK: - DashboardFlowLayout (chips that wrap to a new line)

/// A horizontal layout with automatic line wrapping. Used by the Tags card.
/// A minimal implementation based on `Layout` (iOS 16+). Used to live in
/// `DashboardView` before sections were extracted into cards.
struct DashboardFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Onboarding empty state

/// ⚠️ `internal`, not `private`: the card is declared here but used by
/// `DashboardView` (it followed `FlowLayout` when sections were extracted).
struct OnboardingImportCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.success.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AppTheme.Colors.success)
            }
            VStack(spacing: AppTheme.Spacing.sm) {
                Text("Commencez par importer vos données")
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Exportez le relevé de votre compte bancaire au format CSV depuis votre banque en ligne, puis importez-le ici pour commencer à suivre vos finances.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label("Importation", systemImage: "square.and.arrow.down")
                    .font(AppTheme.Typography.labelLarge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.xl)
                    .padding(.vertical, AppTheme.Spacing.md)
                    .background(AppTheme.Colors.success, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.Spacing.xxxl)
        .padding(.top, 60)
    }
}
