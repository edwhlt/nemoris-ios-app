import SwiftUI
import Charts
import TipKit

struct DetectionResultsSheet: View {
    @Bindable var vm: BudgetViewModel
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    var body: some View {
            List {
                Section {
                    Text("Ces dépenses semblent récurrentes dans votre historique. Confirmez celles que vous souhaitez suivre.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)

                ForEach(vm.detectionResults, id: \.name) { candidate in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text(candidate.frequency.label)
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(abs(candidate.amountAvg), format: .currency(code: "EUR"))
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                Text("\(Int(candidate.confidence * 100))% confiance")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Text("\(candidate.occurrences.count) occurrences détectées")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                    .rowActions(leading: [
                        RowAction("Confirmer", systemImage: "checkmark", tint: AppTheme.Colors.success) {
                            vm.acceptCandidate(candidate)
                            vm.detectionResults.removeAll { $0.name == candidate.name }
                            if vm.detectionResults.isEmpty { dismiss() }
                        }
                    ])
                    .listRowBackground(AppTheme.Colors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.background)
            // ⚠️ Volontairement PAS de confirmIcon : action de masse irréversible
            // (crée N récurrents d'un coup). Une version antérieure du panneau
            // repliait ce bouton sur un ✓ générique, lu comme « OK/fermer » — un
            // clic a créé 157 récurrents par erreur (cf. `AdaptivePane.swift`,
            // `InspectorChromeToolbar.barButton`). Le libellé reste explicite.
            .paneChrome("Récurrents détectés",
                        cancelLabel: "Fermer", onCancel: { dismiss() },
                        confirmLabel: "Tout accepter") {
                for c in vm.detectionResults { vm.acceptCandidate(c) }
                dismiss()
            }
    }
}
