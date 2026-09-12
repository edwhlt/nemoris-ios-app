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
                .localizedAccessibilityLabel("Identifiant \(id)")

            // No pill background: this is secondary info (like the id
            // right next to it), not an action — a filled badge next to a
            // checkmark/chevron reads as one more button in an already
            // busy row.
            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(count)")
                    .font(.caption2).fontWeight(.medium)
            }
            .foregroundStyle(count == 0
                             ? AppTheme.Colors.textSecondary.opacity(0.4)
                             : AppTheme.Colors.textSecondary.opacity(0.7))
            .localizedAccessibilityLabel("\(count) transaction(s)")
        }
    }
}
