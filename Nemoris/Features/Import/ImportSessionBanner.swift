import SwiftUI

/// Bandeau flottant "Import en cours" affiché au-dessus de la tab bar dans MainTabView
/// quand une session est `active`. AXE E.2.
struct ImportSessionBanner: View {
    let summary: ImportSessionSummary
    let onTap: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppTheme.Colors.accent))

            VStack(alignment: .leading, spacing: 2) {
                Text("Import en cours")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onTap()
            } label: {
                HStack(spacing: 4) {
                    Text("Reprendre")
                    Image(systemName: "arrow.right")
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppTheme.Colors.accent, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Le bandeau est en haut de l'écran (sous le status bar) — divider en BAS pour
        // séparer du contenu du TabView, padding top pour respirer sous la status bar.
        .padding(.top, 4)
        .background(AppTheme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(AppTheme.Colors.surfaceSecondary)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var detailText: String {
        if summary.pendingRows > 0 {
            return "\(summary.pendingRows) ligne(s) à classer sur \(summary.totalRows)"
        }
        return "\(summary.totalRows) ligne(s) prêtes à importer"
    }
}
