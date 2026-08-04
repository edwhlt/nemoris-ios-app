import SwiftUI
import Charts
import TipKit

struct RecurringPatternRow: View {
    let pattern: RecurringPattern
    let categories: [Category]

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: pattern.frequency.systemImage)
                .frame(width: 28)
                .foregroundStyle(pattern.isActive ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(pattern.isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                HStack(spacing: 4) {
                    Text(pattern.frequency.label)
                    if let catId = pattern.categoryId,
                       let cat = categories.first(where: { $0.id == catId }) {
                        Text("·")
                        Text(cat.name)
                    }
                }
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Text(pattern.displayAmount, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall)
                .foregroundStyle(pattern.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .opacity(pattern.isActive ? 1.0 : 0.5)
    }
}
