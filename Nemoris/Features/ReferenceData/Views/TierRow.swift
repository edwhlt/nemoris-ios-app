import SwiftUI
import TipKit

struct TierRow: View {
    let tiers: Tiers
    let allCategories: [Category]
    let subtitle: String?
    let count: Int
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
                    .imageScale(.large)
            }
            MerchantLogo(tiers: tiers, allCategories: allCategories, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(tiers.name)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if tiers.linkedCompteId != nil {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
            }
            EntityIdCountBadge(id: tiers.id, count: count)
        }
    }
}
