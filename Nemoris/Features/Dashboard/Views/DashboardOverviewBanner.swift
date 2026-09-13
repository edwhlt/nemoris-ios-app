import SwiftUI

// MARK: - DashboardOverviewBanner
//
// The "Overview" band: three module figures side by side, each tappable
// toward its tab.
//
// **Replaces three full-width banners** (Investments, Patrimoine, Budget)
// that were three near-identical copies of the same layout — a 44pt circular
// icon, a 10pt tracking-0.6 eyebrow, a value, a subtitle, a chevron, a gradient and a
// border — for ~210 duplicated lines. Stacked, they alone took up nearly
// three screens of scroll to deliver three numbers.
//
// This is a **fixed** element of the Dashboard: it doesn't enter the configurable
// card grid. A column whose module is disabled (or has no data) disappears
// and the others share the width.

struct DashboardOverviewBanner: View {
    /// Read for the global masking toggle: `compact(_:)` bypasses `MoneyText`,
    /// so it must honor masking itself. The old Patrimoine banner
    /// used to show the debt amount in plain view even with masking on.
    @Environment(AppState.self) private var appState

    /// `nil` = a hidden column (the module is disabled or there's no data to show).
    let investments: InvestmentsRecap?
    let patrimoine: PatrimoineSnapshot?
    let budget: BudgetRecap?
    let onSelect: (MainTabItem) -> Void

    private var hasAnyColumn: Bool {
        investments != nil || patrimoine != nil || budget != nil
    }

    var body: some View {
        if hasAnyColumn {
            HStack(alignment: .top, spacing: 0) {
                if let investments {
                    column(
                        icon: "chart.line.uptrend.xyaxis",
                        tint: AppTheme.Colors.accentSecondary,
                        title: "Investi",
                        destination: .investments
                    ) {
                        MoneyText(
                            amount: investments.totalCurrentValue,
                            font: AppTheme.Typography.moneySmall,
                            maskedPlaceholder: "••• €"
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        if investments.totalInvested > 0 {
                            caption(
                                Text(String(format: "%@%.1f %%",
                                       investments.pnlAbsolute >= 0 ? "+" : "",
                                       investments.pnlPercent)),
                                color: investments.pnlAbsolute >= 0
                                    ? AppTheme.Colors.success
                                    : AppTheme.Colors.danger
                            )
                        } else {
                            caption(Text("\(investments.activeAccountCount) compte\(investments.activeAccountCount > 1 ? "s" : "")"))
                        }
                    }
                }

                if patrimoine != nil, investments != nil { separator }

                if let patrimoine {
                    column(
                        icon: "house.fill",
                        tint: AppTheme.Colors.accent,
                        title: "Patrimoine",
                        destination: .patrimoine
                    ) {
                        MoneyText(
                            amount: patrimoine.netWorth,
                            font: AppTheme.Typography.moneySmall,
                            color: patrimoine.netWorth >= 0
                                ? AppTheme.Colors.textPrimary
                                : AppTheme.Colors.danger,
                            maskedPlaceholder: "••• €"
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        // Liabilities explain why the net can be negative — that's
                        // the most useful information next to the net figure.
                        if patrimoine.totalLiabilities > 0 {
                            caption(
                                appState.amountsHidden
                                    ? Text("••• de dettes")
                                    : Text("\(compact(patrimoine.totalLiabilities)) de dettes"),
                                color: AppTheme.Colors.danger
                            )
                        } else {
                            caption(Text("\(patrimoine.itemsCount) élément\(patrimoine.itemsCount > 1 ? "s" : "")"))
                        }
                    }
                }

                if budget != nil, investments != nil || patrimoine != nil { separator }

                if let budget {
                    column(
                        icon: budgetIcon(budget),
                        tint: budgetTint(budget),
                        title: "Enveloppes",
                        destination: .budget
                    ) {
                        Text("\(budget.totalCount)")
                            .font(AppTheme.Typography.moneySmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        HStack(spacing: 6) {
                            chip(budget.healthyCount, color: AppTheme.Colors.success, icon: "checkmark")
                            chip(budget.warningCount, color: AppTheme.Colors.warning, icon: "exclamationmark")
                            chip(budget.exceededCount, color: AppTheme.Colors.danger, icon: "xmark")
                        }
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Colors.textSecondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Composants

    @ViewBuilder
    private func column<Content: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        destination: MainTabItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            HapticService.shared.selection()
            onSelect(destination)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .textCase(.uppercase)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle()
            .fill(AppTheme.Colors.textSecondary.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func caption(_ text: Text, color: Color = AppTheme.Colors.textSecondary) -> some View {
        text
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func chip(_ count: Int, color: Color, icon: String) -> some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 7, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
        }
    }

    private func budgetIcon(_ recap: BudgetRecap) -> String {
        if recap.exceededCount > 0 { return "xmark.octagon.fill" }
        if recap.warningCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private func budgetTint(_ recap: BudgetRecap) -> Color {
        if recap.exceededCount > 0 { return AppTheme.Colors.danger }
        if recap.warningCount > 0 { return AppTheme.Colors.warning }
        return AppTheme.Colors.success
    }

    /// An abbreviated amount ("€300.8k"): on a third of an iPhone's width, a
    /// six-digit liability squashed by `minimumScaleFactor` becomes unreadable.
    private func compact(_ amount: Double) -> String {
        let value = abs(amount)
        if value >= 1_000_000 {
            return String(format: "%.1f M€", value / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.0f k€", value / 1_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f k€", value / 1_000)
        }
        // Stays consistent with the 2 branches above (a homegrown abbreviation, a
        // decimal point) rather than `.formatted(.currency(...))` — which, called
        // outside a `Text(_:format:)`, ignores the app-forced locale and falls
        // back to the device's actual one (see the Patrimoine fix).
        return String(format: "%.2f €", value)
    }
}
