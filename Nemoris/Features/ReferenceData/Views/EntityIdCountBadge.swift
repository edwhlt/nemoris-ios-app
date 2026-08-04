import SwiftUI
import TipKit

struct EntityIdCountBadge: View {
    let id: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(id)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                .accessibilityLabel("Identifiant \(id)")

            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(count)")
                    .font(.caption2).fontWeight(.medium)
            }
            .foregroundStyle(count == 0
                             ? AppTheme.Colors.textSecondary.opacity(0.4)
                             : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((count == 0 ? Color.clear : AppTheme.Colors.textSecondary.opacity(0.12)),
                        in: Capsule())
            .accessibilityLabel("\(count) transaction(s)")
        }
    }
}
