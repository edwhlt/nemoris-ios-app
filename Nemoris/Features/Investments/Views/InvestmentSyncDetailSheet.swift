import SwiftUI

/// Détail d'une synchronisation de cours — partagé par les 3 niveaux
/// (position / compte / global) pour ne jamais diverger sur ce qui compte
/// comme "un problème" (cf. doctrine du dépôt : plusieurs implémentations
/// du même calcul finissent toujours par diverger, AXE Q).
///
/// - `.single` : une seule position (fiche position) — reprend le contenu
///   de l'ancienne carte "Dernière synchro du cours".
/// - `.list` : plusieurs positions (compte ou vue globale), triées
///   problèmes d'abord.
struct InvestmentSyncDetailSheet: View {

    enum Content {
        case single(InvestmentSyncTraceStore.Entry?)
        case list(summary: String?, positions: [SyncPositionStatus])
    }

    let content: Content

    @Environment(\.paneDismiss) private var paneDismiss

    var body: some View {
        Form {
            switch content {
            case .single(let trace):
                singleContent(trace)
            case .list(let summary, let positions):
                listContent(summary: summary, positions: positions)
            }
        }
        .nemorisFormStyle()
        .paneChrome("Détails de la synchronisation", cancelLabel: "Fermer", onCancel: { paneDismiss() })
    }

    // MARK: - Mode position unique

    @ViewBuilder
    private func singleContent(_ trace: InvestmentSyncTraceStore.Entry?) -> some View {
        if let trace {
            Section {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: trace.status.icon)
                        .foregroundStyle(traceColor(trace.status))
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(LocalizedStringKey(trace.status.label)) + Text(" — \(trace.humanizedAttemptedAt)"))
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text(trace.message)
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !trace.symbolsTried.isEmpty {
                    Text("Symbole(s) essayé(s) : \(trace.symbolsTried.joined(separator: ", "))")
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        } else {
            Section {
                Text("Aucune tentative de synchronisation enregistrée pour cette position.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Mode liste (compte / global)

    @ViewBuilder
    private func listContent(summary: String?, positions: [SyncPositionStatus]) -> some View {
        if let summary {
            Section {
                Text(summary)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        let problems = positions.filter(\.isProblem)
        let ok = positions.filter { !$0.isProblem }
        if !problems.isEmpty {
            Section("Non synchronisées") {
                ForEach(problems) { positionRow($0) }
            }
        }
        if !ok.isEmpty {
            Section("À jour") {
                ForEach(ok) { positionRow($0) }
            }
        }
        if positions.isEmpty {
            Section {
                Text("Aucune position à synchroniser.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func positionRow(_ status: SyncPositionStatus) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: status.outcome?.systemIcon ?? "questionmark.circle")
                .foregroundStyle(color(for: status.outcome))
            VStack(alignment: .leading, spacing: 1) {
                Text(status.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(status.outcome?.shortLabel ?? "Jamais synchronisée")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func color(for outcome: PositionSyncOutcome?) -> Color {
        guard let outcome else { return AppTheme.Colors.textSecondary }
        switch outcome {
        case .success, .upToDate:
            return AppTheme.Colors.success
        case .noData, .rateLimited, .invalidIdentifier:
            return AppTheme.Colors.warning
        case .networkError:
            return AppTheme.Colors.danger
        }
    }

    private func traceColor(_ status: InvestmentSyncTraceStore.Status) -> Color {
        switch status {
        case .success:                    return AppTheme.Colors.success
        case .noData, .invalidId:         return AppTheme.Colors.warning
        case .rateLimited:                return AppTheme.Colors.warning
        case .error:                      return AppTheme.Colors.danger
        }
    }
}

/// Une position et son résultat de synchronisation — pour les modes
/// `.list` (compte / global). `outcome == nil` = jamais tentée cette passe,
/// traité comme un problème (on ne sait rien de son état).
struct SyncPositionStatus: Identifiable {
    let id: Int
    let name: String
    let outcome: PositionSyncOutcome?

    var isProblem: Bool { outcome?.isProblem ?? true }
}

/// Bouton "?" compact ouvrant le détail d'une synchronisation — même
/// composant aux 3 niveaux pour un rendu cohérent.
struct SyncInfoButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.Colors.textSecondary)
        .localizedHelp("Détails de la synchronisation")
        .localizedAccessibilityLabel("Détails de la synchronisation")
    }
}
