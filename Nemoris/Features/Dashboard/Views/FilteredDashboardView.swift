import SwiftUI
import Charts
import TipKit

// MARK: - FilteredDashboardView

struct FilteredDashboardView: View {
    let filter: TransactionFilter

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(PurchaseManager.self) private var store
    @State private var vm = FilteredDashboardViewModel()
    private let chartTip = FilteredChartTip()

    var body: some View {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        filterBadges
                        if vm.isLoading {
                            // Skeleton mime la structure summary + 2 charts.
                            AppCard {
                                SkeletonHero()
                            }
                            AppCard {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                    SkeletonLine(width: 180, height: 15)
                                    SkeletonChart(height: 200)
                                }
                            }
                            AppCard {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                    SkeletonLine(width: 160, height: 15)
                                    SkeletonChart(height: 160)
                                }
                            }
                        } else if vm.periodData.isEmpty && vm.categoryData.isEmpty {
                            summarySection
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "Aucune donnée",
                                message: "Aucune transaction ne correspond aux filtres actifs."
                            )
                        } else {
                            summarySection
                            if !vm.periodData.isEmpty { timeSeriesSection }
                            if !vm.categoryData.isEmpty { categorySection }
                            if !vm.tagData.isEmpty { tagSection }
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.sm)
                    .padding(.bottom, AppTheme.Spacing.xxxl)
                }
            }
            .task {
                await Task.yield()
                vm.load(filter: filter)
            }
            .paywallOverlay(for: .filteredDashboard)
            .paneChrome("Analyse filtrée", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    // MARK: - Filter Badges

    private var filterBadges: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Filtres actifs")
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    InfoBadge(
                        label: filter.accountName.isEmpty ? "Compte" : filter.accountName,
                        icon: "building.columns",
                        color: AppTheme.Colors.accent
                    )
                    InfoBadge(
                        label: "\(filter.from.formatted(date: .abbreviated, time: .omitted)) – \(filter.to.formatted(date: .abbreviated, time: .omitted))",
                        icon: "calendar",
                        color: AppTheme.Colors.accentSecondary
                    )
                    if !filter.tiersSearchText.isEmpty {
                        InfoBadge(label: "\"\(filter.tiersSearchText)\"", icon: "magnifyingglass", color: AppTheme.Colors.textSecondary)
                    }
                    if !filter.categoryName.isEmpty {
                        InfoBadge(label: filter.categoryName, icon: "folder", color: AppTheme.Colors.accent)
                    }
                    ForEach(filter.tagNames, id: \.self) { name in
                        InfoBadge(label: name, icon: "tag", color: AppTheme.Colors.accentSecondary)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
            }
        }
        .appCardStyle()
    }

    // MARK: - Sections

    private var summarySection: some View {
        DashboardSummaryCard(
            stats: vm.stats,
            title: filter.accountName,
            subtitle: "\(filter.from.formatted(date: .abbreviated, time: .omitted)) – \(filter.to.formatted(date: .abbreviated, time: .omitted))"
        )
    }

    private var timeSeriesSection: some View {
        @Bindable var vm = vm
        return AppChartCard(title: "Évolution", accentColor: AppTheme.Colors.accent) {
            TipView(chartTip, arrowEdge: .none)
            Picker("Granularité", selection: $vm.granularity) {
                ForEach(ChartGranularity.allCases, id: \.self) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, AppTheme.Spacing.xs)

            BalanceTimeChart(
                periodData: vm.periodData,
                balanceData: vm.dailyBalanceData,
                granularity: vm.granularity
            )
        }
    }

    private var categorySection: some View {
        AppChartCard(
            title: "Répartition par catégorie",
            subtitle: "Toutes catégories (filtré)",
            accentColor: AppTheme.Colors.accentSecondary
        ) {
            CategoryBarChartView(data: vm.categoryData, expenseOnly: false)
        }
    }

    private var tagSection: some View {
        AppChartCard(
            title: "Répartition par tag",
            accentColor: AppTheme.Colors.warning
        ) {
            TagBarChartView(data: vm.tagData)
        }
    }
}
