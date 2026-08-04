import SwiftUI
import Charts
import TipKit

struct BudgetSummaryBubble: View {
    let summary: MonthlyBudgetSummary
    let month: Date
    let onTap: () -> Void

    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct: Double = 20

    private var fullRatio: Double {
        guard summary.forecastedExpenses > 0 else { return 0 }
        return summary.actualExpenses / summary.forecastedExpenses
    }

    private var ratio: Double { min(fullRatio, 1.0) }

    private var overColor: Color {
        guard summary.isOverBudget else { return AppTheme.Colors.accent }
        return fullRatio >= 1.0 + budgetRedOverPct / 100 ? AppTheme.Colors.danger : AppTheme.Colors.warning
    }

    private var overIcon: String {
        guard summary.isOverBudget else { return "chart.pie.fill" }
        return fullRatio >= 1.0 + budgetRedOverPct / 100 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: overIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(overColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(month, format: .dateTime.month(.wide).year())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                            Capsule()
                                .fill(overColor)
                                .frame(width: geo.size.width * ratio, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(width: 120)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.actualExpenses, format: .currency(code: "EUR").precision(.fractionLength(0)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(overColor)
                    Text("/ \(summary.forecastedExpenses.formatted(.currency(code: "EUR").precision(.fractionLength(0))))")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppTheme.Colors.accent.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Capsule())
            .modifier(GlassBubbleModifier())
        }
        .buttonStyle(BubblePressStyle())
    }
}
