import SwiftUI

/// Confirmation demandée avant d'ignorer une échéance de récurrent : le user
/// doit préciser s'il veut ignorer UNIQUEMENT cette occurrence (le récurrent
/// continue le mois suivant), ou arrêter le récurrent à partir d'ici (modifie
/// la date de fin du motif, aucune échéance après celle-ci ne sera générée).
/// Partagée entre `BudgetView` (listes "7 prochains jours" / "Ce mois") et
/// `DayDetailPanel` (calendrier) pour éviter de dupliquer ce choix 3 fois.
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
