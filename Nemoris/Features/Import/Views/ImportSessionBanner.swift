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

/// Bandeau d'ANALYSE en arrière-plan : l'utilisateur a lancé un import de
/// document et continue à se servir de l'app pendant que ça travaille.
///
/// Même gabarit que le bandeau de session pour rester lisible au même endroit,
/// avec une barre de progression tant que l'analyse tourne et un bouton
/// « Continuer » dès que le résultat est relisible.
struct ImportAnalysisBanner: View {
    let coordinator: DocumentImportCoordinator
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.isReady ? "checkmark.circle.fill" : "wand.and.stars")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(coordinator.isReady
                                          ? AppTheme.Colors.success : AppTheme.Colors.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.bannerTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(coordinator.bannerSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                if coordinator.isRunning {
                    // Déterminée seulement quand elle a quelque chose à
                    // raconter (cf. `progressFraction`) ; sinon barre
                    // indéterminée, qui au moins montre que ça travaille.
                    if let fraction = coordinator.progressFraction {
                        ProgressView(value: fraction)
                            .tint(AppTheme.Colors.accent)
                            .frame(maxWidth: 220)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(AppTheme.Colors.accent)
                            .frame(maxWidth: 220)
                    }
                }
            }

            Spacer()

            if coordinator.isReady {
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text("Continuer")
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.Colors.success, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.top, 4)
        .background(AppTheme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(AppTheme.Colors.surfaceSecondary)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
