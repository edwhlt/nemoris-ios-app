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

            // Pas de fond en pilule : c'est une info secondaire (comme l'id
            // juste à côté), pas une action — un badge rempli à côté d'un
            // checkmark/chevron se lit comme un bouton de plus dans une
            // rangée déjà chargée. Cf. retour d'usage 2026-08-18.
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
