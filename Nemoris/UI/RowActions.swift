import SwiftUI

/// Action de ligne déclarée UNE seule fois, rendue selon la plateforme :
/// - **iOS** : `.swipeActions` (geste natif Mail/Messages, teinte conservée).
/// - **macOS** : `.contextMenu` (clic droit) — le swipe n'existe pas à la souris.
///
/// Remplace l'ancien composant `SwipeableRow` (supprimé) : celui-ci ne couvrait
/// que nos `VStack`-in-`AppCard` et n'était plus instancié nulle part, alors que
/// ~42 lignes de `List` utilisaient `.swipeActions` SANS aucune alternative
/// souris sur Mac (édition/suppression inatteignables au clic).
///
/// Usage :
/// ```
/// .rowActions(
///     leading:  [RowAction("Modifier", systemImage: "pencil", tint: .accent) { edit() }],
///     trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { delete() }]
/// )
/// ```
struct RowAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    /// Teinte du bouton de swipe iOS (ignorée par le menu contextuel macOS,
    /// dont les items ne sont pas colorables).
    var tint: Color? = nil
    let action: () -> Void

    init(_ title: String,
         systemImage: String,
         role: ButtonRole? = nil,
         tint: Color? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.tint = tint
        self.action = action
    }
}

extension View {
    /// Actions de ligne adaptatives (swipe iOS / menu contextuel macOS).
    /// À appliquer sur une row de `List`. Sur macOS, `leading` puis `trailing`
    /// sont fusionnés dans le clic droit (séparés par un `Divider`).
    ///
    /// `leadingFullSwipe`/`trailingFullSwipe` reprennent le paramètre natif
    /// `allowsFullSwipe` (défaut `true` comme SwiftUI) — passer `false` pour un
    /// bord dont l'action ne doit pas se déclencher au swipe complet.
    func rowActions(leading: [RowAction] = [],
                    trailing: [RowAction] = [],
                    leadingFullSwipe: Bool = true,
                    trailingFullSwipe: Bool = true) -> some View {
        modifier(RowActionsModifier(leading: leading,
                                    trailing: trailing,
                                    leadingFullSwipe: leadingFullSwipe,
                                    trailingFullSwipe: trailingFullSwipe))
    }
}

private struct RowActionsModifier: ViewModifier {
    let leading: [RowAction]
    let trailing: [RowAction]
    let leadingFullSwipe: Bool
    let trailingFullSwipe: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.contextMenu {
            ForEach(leading) { menuButton($0) }
            if !leading.isEmpty && !trailing.isEmpty { Divider() }
            ForEach(trailing) { menuButton($0) }
        }
        #else
        content
            .swipeActions(edge: .leading, allowsFullSwipe: leadingFullSwipe) {
                ForEach(leading) { swipeButton($0) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: trailingFullSwipe) {
                ForEach(trailing) { swipeButton($0) }
            }
        #endif
    }

    #if os(macOS)
    @ViewBuilder private func menuButton(_ a: RowAction) -> some View {
        Button(role: a.role) { a.action() } label: {
            Label(a.title, systemImage: a.systemImage)
        }
    }
    #else
    @ViewBuilder private func swipeButton(_ a: RowAction) -> some View {
        Button(role: a.role) { a.action() } label: {
            Label(a.title, systemImage: a.systemImage)
        }
        .tint(a.tint)
    }
    #endif
}
