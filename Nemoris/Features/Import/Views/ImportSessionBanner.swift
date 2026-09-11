import SwiftUI

/// Floating "Import in progress" banner shown above the tab bar in MainTabView
/// when a session is `active`.
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
        // The banner is at the top of the screen (under the status bar) — divider at
        // the BOTTOM to separate it from the TabView content, top padding to breathe
        // under the status bar.
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

/// Background ANALYSIS banner: the user started a document import and keeps
/// using the app while it works.
///
/// Same template as the session banner so it stays readable in the same
/// place, with a progress bar while the analysis runs and a "Continue" button
/// as soon as the result can be reviewed.
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
                    // Determinate only when it has something to tell (see `progressFraction`);
                    // otherwise an indeterminate bar, which at least shows work is happening.
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
