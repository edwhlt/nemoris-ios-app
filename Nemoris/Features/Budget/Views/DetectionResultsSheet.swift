import SwiftUI
import Charts
import TipKit

struct DetectionResultsSheet: View {
    @Bindable var vm: BudgetViewModel
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    // Level-2 pane: view a candidate's detail (occurrences + explanation),
    // with a "Modify" button that switches to editing WITHOUT
    // opening a 3rd pane level (the same in-place swap as
    // `EntityDetailEditPane` in AdaptivePane.swift). `startCandidateInEditing`
    // lets a swipe "Modify" from the list open editing directly,
    // skipping the detail.
    @State private var inspectedCandidate: DetectionCandidate?
    @State private var startCandidateInEditing = false

    /// Candidates that don't match ANY already-tracked pattern — only those
    /// can be created ("Confirm"/"Accept all"/"Modify"). The others
    /// stay shown (grayed out) rather than silently excluded: a
    /// real-world report showed that a candidate disappearing with no explanation
    /// reads as "detection doesn't work", when the real reason is
    /// that a pattern — even a disabled one — already exists for that payee.
    private var newCandidates: [DetectionCandidate] {
        vm.detectionResults.filter { $0.existingMatch(in: vm.patterns) == nil }
    }

    var body: some View {
        Group {
            if vm.detectionResults.isEmpty {
                EmptyStateView(
                    icon: "wand.and.stars",
                    title: "Aucun récurrent détecté",
                    message: "Aucune dépense de votre historique ne réunit les 4 critères d'un récurrent : même tiers, fréquence régulière, montant quasi identique et date d'échéance stable (±1-2 jours)."
                )
            } else {
                resultsList
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background)
        // ⚠️ Deliberately NO confirmIcon: an irreversible bulk action
        // (creates N recurring items at once). An earlier version of the panel
        // collapsed this button to a generic ✓, read as "OK/close" — a
        // click once created 157 recurring items by mistake (see `AdaptivePane.swift`,
        // `InspectorChromeToolbar.barButton`). The label stays explicit.
        .paneChrome("Récurrents détectés",
                    cancelLabel: "Fermer", onCancel: { dismiss() },
                    confirmLabel: newCandidates.isEmpty ? nil : "Tout accepter") {
            for c in newCandidates { vm.acceptCandidate(c) }
            let acceptedIds = Set(newCandidates.map(\.id))
            vm.detectionResults.removeAll { acceptedIds.contains($0.id) }
            if vm.detectionResults.isEmpty { dismiss() }
        }
        .adaptivePane(item: $inspectedCandidate) { candidate in
            DetectionCandidatePane(
                candidate: candidate, vm: vm, startInEditing: startCandidateInEditing,
                existingPattern: candidate.existingMatch(in: vm.patterns),
                onResolved: {
                    vm.detectionResults.removeAll { $0.id == candidate.id }
                    if vm.detectionResults.isEmpty { dismiss() }
                }
            )
        }
    }

    private var resultsList: some View {
            List {
                Text("Ces dépenses semblent récurrentes dans votre historique. Touchez une ligne pour voir le détail et l'explication, ou confirmez directement celles que vous souhaitez suivre.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .macGroupedRow()

                ForEach(vm.detectionResults) { candidate in
                    let existing = candidate.existingMatch(in: vm.patterns)
                    // An already-tracked pattern may have drifted (a higher price,
                    // a shifted due date) with nothing ever catching up with it —
                    // distinguished here from a pattern that's genuinely up to date,
                    // which needs no action.
                    let drifted = existing.map { candidate.differsFrom($0) } ?? false
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text(LocalizedStringKey(candidate.frequency.label))
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(abs(candidate.amountAvg), format: .currency(code: "EUR"))
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                if let existing {
                                    if drifted {
                                        Label("A changé", systemImage: "exclamationmark.triangle.fill")
                                            .font(AppTheme.Typography.labelMedium)
                                            .foregroundStyle(AppTheme.Colors.warning)
                                    } else {
                                        Label("Déjà suivi", systemImage: "checkmark.seal.fill")
                                            .font(AppTheme.Typography.labelMedium)
                                            .foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                    if drifted {
                                        Text("était \(abs(existing.amountAvg), format: .currency(code: "EUR"))")
                                            .font(AppTheme.Typography.labelSmall)
                                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                                    }
                                } else {
                                    Text("\(Int(candidate.confidence * 100))% confiance")
                                        .font(AppTheme.Typography.labelMedium)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                        }
                        Text("\(candidate.occurrences.count) occurrences détectées")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                    // Grayed out ONLY when there's nothing to do — a pattern
                    // that has drifted stays at full opacity, it needs attention.
                    .opacity(existing == nil || drifted ? 1 : 0.55)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        startCandidateInEditing = false
                        inspectedCandidate = candidate
                    }
                    .rowActions(
                        leading: existing == nil ? [
                            RowAction("Confirmer", systemImage: "checkmark", tint: AppTheme.Colors.success) {
                                vm.acceptCandidate(candidate)
                                vm.detectionResults.removeAll { $0.id == candidate.id }
                                if vm.detectionResults.isEmpty { dismiss() }
                            }
                        ] : (drifted ? [
                            RowAction("Mettre à jour", systemImage: "arrow.triangle.2.circlepath", tint: AppTheme.Colors.warning) {
                                vm.updatePattern(candidate.updating(existing!))
                                vm.detectionResults.removeAll { $0.id == candidate.id }
                            }
                        ] : []),
                        trailing: existing == nil ? [
                            RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) {
                                startCandidateInEditing = true
                                inspectedCandidate = candidate
                            }
                        ] : []
                    )
                    .macGroupedRow(
                        first: candidate.id == vm.detectionResults.first?.id,
                        last: candidate.id == vm.detectionResults.last?.id
                    )
                }
            }
            #if os(macOS)
            // Same policy as TricountListView/TransactionsView: .plain =
            // a neutral base for the custom cards drawn by macGroupedRow.
            .listStyle(.plain)
            .macGroupedListTopGap()
            #endif
    }
}

/// Level-2 pane for a detected candidate: a read-only detail (with a
/// "Modify" button) that switches to `PatternEditSheet` WITHIN the same
/// pane — no 3rd nesting level. `startInEditing` lets it open
/// directly in edit mode (a "Modify" swipe from the list).
/// `existingPattern`: if non-nil, the candidate already matches a
/// tracked pattern — editing (which would create a DUPLICATE) is disabled,
/// only the detail (showing the existing pattern) stays accessible.
private struct DetectionCandidatePane: View {
    let candidate: DetectionCandidate
    let vm: BudgetViewModel
    let startInEditing: Bool
    let existingPattern: RecurringPattern?
    /// Called only after a successful creation (not on cancel) —
    /// removes the candidate from the list, which no longer needs offering.
    let onResolved: () -> Void

    @State private var isEditing: Bool
    /// The REAL dismissal of the level-2 pane (back to the candidate list).
    /// Not to be confused with "back to detail" from editing — see
    /// the `.environment(\.paneDismiss, …)` set on `PatternEditSheet`
    /// below, which redefines what "dismiss" means WITHIN this
    /// sub-tree only.
    @Environment(\.paneDismiss) private var paneDismiss

    init(candidate: DetectionCandidate, vm: BudgetViewModel, startInEditing: Bool,
         existingPattern: RecurringPattern?, onResolved: @escaping () -> Void) {
        self.candidate = candidate
        self.vm = vm
        self.startInEditing = startInEditing
        self.existingPattern = existingPattern
        self.onResolved = onResolved
        _isEditing = State(initialValue: existingPattern == nil && startInEditing)
    }

    /// nil (nothing to do) as long as neither creation nor an update is possible.
    private var confirmSpec: (label: String, icon: String, action: () -> Void)? {
        guard let existing = existingPattern else {
            return ("Modifier", "pencil", { isEditing = true })
        }
        guard candidate.differsFrom(existing) else { return nil }
        return ("Mettre à jour", "arrow.triangle.2.circlepath", {
            vm.updatePattern(candidate.updating(existing))
            onResolved()
            paneDismiss()
        })
    }

    var body: some View {
        if isEditing, existingPattern == nil {
            PatternEditSheet(
                vm: vm, pattern: nil, prefill: candidate.asDraftPattern(),
                // A successful creation ⇒ there's no more "candidate" to show,
                // so a FULL dismissal (not just back to detail).
                onCreated: { onResolved(); paneDismiss() }
            )
            // Same rule as `EntityDetailEditPane` (AdaptivePane.swift) for
            // editing an EXISTING pattern: "Cancel" from the form
            // goes back to the detail rather than closing the whole pane — without
            // this, "Modify" was a door with no way back. `onCreated`
            // above short-circuits this return by closing
            // completely once creation actually happens.
            .environment(\.paneDismiss, { isEditing = false })
        } else {
            DetectionCandidateDetailPane(candidate: candidate, existingPattern: existingPattern)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paneChrome("Récurrent détecté",
                            cancelLabel: "Fermer", onCancel: { paneDismiss() },
                            confirmLabel: confirmSpec?.label, confirmIcon: confirmSpec?.icon,
                            onConfirm: confirmSpec?.action)
        }
    }
}
