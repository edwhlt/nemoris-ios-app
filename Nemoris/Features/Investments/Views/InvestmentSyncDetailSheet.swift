import SwiftUI

/// Detail of a price sync — shared by the 3 levels (position / account /
/// global) so they never disagree on what counts as "a problem": several
/// implementations of the same computation always end up diverging.
///
/// - `.single`: a single position (position sheet).
/// - `.list`: several positions (account or global view), problems first.
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

    // MARK: - List mode (account / global)

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

/// A position and its sync result — for the `.list` modes (account /
/// global). `outcome == nil` = not attempted in this pass, treated as a
/// problem (nothing is known about its state).
struct SyncPositionStatus: Identifiable {
    let id: Int
    let name: String
    let outcome: PositionSyncOutcome?

    var isProblem: Bool { outcome?.isProblem ?? true }
}

/// Compact "?" button opening a sync's detail — the same component at all 3
/// levels for consistent rendering.
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
