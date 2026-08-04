import SwiftUI
import Charts
import TipKit

struct SavingsBreakdownRow: View {
    let summary: MonthlyBudgetSummary

    var body: some View {
        HStack(spacing: 0) {
            miniStat(title: "Fixes",
                     value: summary.fixedActual,
                     color: AppTheme.Colors.textSecondary.opacity(0.7))
            miniStat(title: "Variables",
                     value: summary.variableActual,
                     color: AppTheme.Colors.warning)
            if summary.totalIncome > 0 {
                miniStat(title: "Revenus",
                         value: summary.totalIncome,
                         color: AppTheme.Colors.success)
                let net = summary.netSavings
                miniStat(title: net >= 0 ? "Économisé" : "Déficit",
                         value: abs(net),
                         color: net >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }
        }
    }

    private func miniStat(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value, format: .currency(code: "EUR").precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
