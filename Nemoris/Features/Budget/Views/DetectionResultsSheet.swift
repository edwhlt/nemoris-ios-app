import SwiftUI
import Charts
import TipKit

struct DetectionResultsSheet: View {
    @Bindable var vm: BudgetViewModel
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    // Panneau niveau 2 : voir le détail (occurrences + explication) d'un
    // candidat, avec un bouton "Modifier" qui bascule vers l'édition SANS
    // ouvrir un 3e niveau de panneau (même swap in-place que
    // `EntityDetailEditPane` dans AdaptivePane.swift). `startCandidateInEditing`
    // permet au swipe "Modifier" de la liste d'ouvrir directement l'édition,
    // en sautant le détail.
    @State private var inspectedCandidate: DetectionCandidate?
    @State private var startCandidateInEditing = false

    /// Candidats qui ne correspondent à AUCUN motif déjà suivi — seuls ceux-là
    /// peuvent être créés ("Confirmer"/"Tout accepter"/"Modifier"). Les autres
    /// restent affichés (grisés) plutôt qu'exclus en silence : un retour
    /// terrain a montré qu'un candidat qui disparaît sans explication se lit
    /// comme "la détection ne marche pas", alors que la vraie raison est
    /// qu'un motif — même désactivé — existe déjà pour ce tiers.
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
        // ⚠️ Volontairement PAS de confirmIcon : action de masse irréversible
        // (crée N récurrents d'un coup). Une version antérieure du panneau
        // repliait ce bouton sur un ✓ générique, lu comme « OK/fermer » — un
        // clic a créé 157 récurrents par erreur (cf. `AdaptivePane.swift`,
        // `InspectorChromeToolbar.barButton`). Le libellé reste explicite.
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
                    // Un motif déjà suivi peut avoir dérivé (prix augmenté,
                    // échéance décalée) sans que rien ne l'ait jamais
                    // rattrapé — on le distingue d'un motif réellement à jour,
                    // qui lui n'a besoin d'aucune action.
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
                    // Grisé UNIQUEMENT quand il n'y a rien à faire — un motif
                    // qui a dérivé reste en pleine opacité, il a besoin d'attention.
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
            // Même politique que TricountListView/TransactionsView : .plain =
            // base neutre pour les cartes custom dessinées par macGroupedRow.
            .listStyle(.plain)
            .macGroupedListTopGap()
            #endif
    }
}

/// Panneau niveau 2 d'un candidat détecté : détail en lecture seule (avec
/// bouton "Modifier") qui bascule vers `PatternEditSheet` DANS le même
/// panneau — pas de 3e niveau de nesting. `startInEditing` permet d'ouvrir
/// directement en mode édition (swipe "Modifier" de la liste).
/// `existingPattern` : si non-nil, le candidat correspond déjà à un motif
/// suivi — l'édition (qui créerait un DOUBLON) est désactivée, seul le
/// détail (avec le motif existant affiché) reste accessible.
private struct DetectionCandidatePane: View {
    let candidate: DetectionCandidate
    let vm: BudgetViewModel
    let startInEditing: Bool
    let existingPattern: RecurringPattern?
    /// Appelé uniquement après une création réussie (pas sur annulation) —
    /// retire le candidat de la liste, qui n'a plus lieu d'être proposé.
    let onResolved: () -> Void

    @State private var isEditing: Bool
    /// Fermeture RÉELLE du panneau niveau 2 (rendu à la liste des candidats).
    /// À ne pas confondre avec le "retour au détail" depuis l'édition — cf.
    /// le `.environment(\.paneDismiss, …)` posé sur `PatternEditSheet`
    /// ci-dessous, qui redéfinit ce que "dismiss" veut dire DANS ce
    /// sous-arbre uniquement.
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

    /// nil (rien à faire) tant qu'il n'y a ni création ni mise à jour possible.
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
                // Création réussie ⇒ il n'y a plus de "candidat" à montrer,
                // donc fermeture COMPLÈTE (pas juste un retour au détail).
                onCreated: { onResolved(); paneDismiss() }
            )
            // Même règle que `EntityDetailEditPane` (AdaptivePane.swift) pour
            // l'édition d'un motif EXISTANT : "Annuler" depuis le formulaire
            // revient au détail plutôt que de fermer tout le panneau — sans
            // ça, "Modifier" était une porte sans retour (retour terrain
            // 2026-08-28). `onCreated` ci-dessus court-circuite ce retour en
            // fermant complètement une fois la création effective.
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
