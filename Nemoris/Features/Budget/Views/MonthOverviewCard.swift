import SwiftUI
import Charts
import TipKit

struct MonthOverviewCard: View {
    let summary: MonthlyBudgetSummary

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                statBox(title: "Prévu",   value: summary.forecastedExpenses, color: AppTheme.Colors.accent)
                Divider().frame(height: 40)
                statBox(title: "Réel",    value: summary.actualExpenses,
                        color: summary.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Divider().frame(height: 40)
                let v = summary.variance
                statBox(title: v >= 0 ? "Écart" : "Économie",
                        value: abs(v),
                        color: v > 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
            }
            .frame(maxWidth: .infinity)

            let ratio = summary.forecastedExpenses > 0
                ? min(summary.actualExpenses / summary.forecastedExpenses, 1.5)
                : 0
            BudgetRatioBar(ratio: ratio, forecastedExpenses: summary.forecastedExpenses, actualExpenses: summary.actualExpenses)

            HStack {
                Text("\(summary.matchedCount) confirmés")
                    .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text("\(summary.pendingCount) en attente")
                    .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if summary.fixedActual > 0 || summary.totalIncome > 0 {
                Rectangle()
                    .fill(AppTheme.Colors.surfaceSecondary)
                    .frame(height: 1)
                SavingsBreakdownRow(summary: summary)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func statBox(title: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall).foregroundStyle(color)
            Text(title)
                .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
