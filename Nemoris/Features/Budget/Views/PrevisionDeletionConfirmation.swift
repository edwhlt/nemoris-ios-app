import SwiftUI

/// Confirmation requested before skipping a recurring item's due date: the user
/// must specify whether to skip ONLY this occurrence (the recurring item
/// continues next month), or stop the recurring item from here on (changes
/// the pattern's end date, no due date after this one will be generated).
/// Shared between `BudgetView` (the "Next 7 days" / "This month" lists) and
/// `DayDetailPanel` (the calendar) to avoid duplicating this choice 3 times.
struct PrevisionDeletionConfirmation: ViewModifier {
    @Binding var target: BudgetPrevision?
    let vm: BudgetViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Ignorer cette échéance",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            titleVisibility: .visible,
            presenting: target
        ) { prevision in
            Button("Seulement ce mois-ci") {
                vm.skipPrevision(prevision)
            }
            Button("Arrêter ce récurrent définitivement", role: .destructive) {
                vm.stopPatternAfter(prevision)
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("« Seulement ce mois-ci » ignore juste cette échéance, le récurrent continue ensuite. « Arrêter ce récurrent » modifie sa date de fin : plus aucune échéance ne sera générée après celle-ci.")
        }
    }
}

extension View {
    func previsionDeletionConfirmation(target: Binding<BudgetPrevision?>, vm: BudgetViewModel) -> some View {
        modifier(PrevisionDeletionConfirmation(target: target, vm: vm))
    }
}
