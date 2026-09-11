import SwiftUI

/// Compact "N pending Apple Pay expenses · €X" banner, shown ONLY when at
/// least one `pending` entry exists (see
/// `DashboardAggregate.pendingApplePay`). Deliberately neutral, not styled
/// like `AlertsBanner`: this isn't a problem to solve, just visibility on
/// expenses not yet categorized — never counted in the totals while they
/// stay here.
struct ApplePayPendingBanner: View {
    let count: Int
    let total: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "creditcard.and.123")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.Colors.accentSecondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Pay en attente")
                        .font(AppTheme.Typography.labelLarge)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                MoneyText(amount: total, font: AppTheme.Typography.bodyMedium, color: AppTheme.Colors.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        }
        .buttonStyle(.plain)
    }

    // `LocalizedStringKey`, not `String`: `Text(subtitle)` below would stay
    // verbatim (never localized) with a `String`-typed property — cf.
    // CLAUDE.md §5.
    private var subtitle: LocalizedStringKey {
        count > 1 ? "\(count) dépenses pas encore catégorisées" : "1 dépense pas encore catégorisée"
    }
}
