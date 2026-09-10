import SwiftUI

/// Bandeau compact "N dépenses Apple Pay en attente · X €", affiché
/// SEULEMENT s'il y a au moins une entrée `pending` (cf.
/// `DashboardAggregate.pendingApplePay`). Volontairement neutre, pas dans le
/// style `AlertsBanner` : ce n'est pas un problème à résoudre, juste une
/// visibilité sur des dépenses pas encore catégorisées — jamais comptées
/// dans les totaux tant qu'elles restent ici.
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

    private var subtitle: String {
        count > 1 ? "\(count) dépenses pas encore catégorisées" : "1 dépense pas encore catégorisée"
    }
}
