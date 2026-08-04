import SwiftUI
import Charts
import TipKit

struct BudgetRatioBar: View {
    let ratio: Double
    let forecastedExpenses: Double
    let actualExpenses: Double

    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct: Double = 20

    private var pct: Int { Int((min(ratio, 1.5) * 100).rounded()) }
    private var isOver: Bool { ratio > 1 }

    private var barColor: LinearGradient {
        let redRatio = 1.0 + budgetRedOverPct / 100
        if ratio <= 1.0 {
            return LinearGradient(colors: [AppTheme.Colors.success, AppTheme.Colors.success.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
        } else if ratio < redRatio {
            return LinearGradient(colors: [AppTheme.Colors.warning, AppTheme.Colors.warning.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [AppTheme.Colors.danger, AppTheme.Colors.danger], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(height: 10)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * min(ratio, 1.0), height: 10)
                }
            }
            .frame(height: 10)
            HStack {
                if isOver {
                    Label("Dépassement de \((actualExpenses - forecastedExpenses).formatted(.currency(code: "EUR").precision(.fractionLength(0))))", systemImage: ratio >= 1.0 + budgetRedOverPct / 100 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.danger)
                } else {
                    Text("Reste \((forecastedExpenses - actualExpenses).formatted(.currency(code: "EUR").precision(.fractionLength(0))))")
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                Text("\(pct) %")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOver ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
            }
        }
    }
}
