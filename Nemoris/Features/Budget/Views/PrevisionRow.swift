import SwiftUI
import Charts
import TipKit

struct PrevisionRow: View {
    let enriched: EnrichedPrevision
    /// Si fourni ET status == .pending, affiche un bouton inline "skip" trailing.
    /// (les rows sont dans VStack/AppCard, pas dans List → pas de .swipeActions natif)
    var onSkip: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(enriched.patternName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let cat = enriched.categoryName {
                    Text(cat)
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(enriched.displayAmount, format: .currency(code: "EUR"))
                    .font(AppTheme.Typography.moneySmall)
                    .foregroundStyle(enriched.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Text(enriched.expectedDate, format: .dateTime.day().month(.abbreviated))
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            // Bouton rapide skip : visible seulement sur les .pending
            if let onSkip, enriched.status == .pending {
                Button(action: onSkip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(AppTheme.Colors.surfaceSecondary, in: Circle())
                }
                .buttonStyle(.plain)
                .localizedAccessibilityLabel("Ignorer cette échéance")
            }
        }
    }

    private var statusColor: Color {
        switch enriched.status {
        case .pending: return AppTheme.Colors.warning
        case .matched: return AppTheme.Colors.success
        case .skipped: return AppTheme.Colors.textSecondary
        }
    }
}
