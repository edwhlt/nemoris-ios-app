import SwiftUI

/// Row éditable via swipe horizontal — pattern iOS natif (Mail, Messages, etc.)
/// adapté pour fonctionner dans nos `VStack`-in-`AppCard` (notre layout actuel
/// ne passe pas par `List`, donc `.swipeActions` n'est pas dispo).
///
/// Comportement :
/// - **Swipe vers la gauche** → révèle une action "Supprimer" rouge sur la droite
/// - **Swipe vers la droite** → révèle une action "Modifier" verte sur la gauche
/// - **Tap sur le contenu** quand un swipe est ouvert → ferme le swipe
/// - **Si une seule action est fournie** (onEdit OU onDelete nil) → l'autre
///   direction de swipe est rubber-bandée (no-op)
///
/// Détails techniques :
/// - `DragGesture(minimumDistance: 20)` : laisse la priorité au scroll vertical
///   pour les petits déplacements → marche dans ScrollView sans conflit
/// - Threshold à 1/3 de la largeur d'action pour valider l'ouverture
/// - Animation snappy 0.25s pour le retour à 0
struct SwipeableRow<Content: View>: View {

    @ViewBuilder let content: () -> Content
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    /// Texte affiché sur l'action "Modifier" (par défaut "Modifier")
    var editLabel: String = "Modifier"
    /// Texte affiché sur l'action "Supprimer" (par défaut "Supprimer")
    var deleteLabel: String = "Supprimer"
    /// Couleur de fond du contenu — doit matcher le parent pour fluidité
    var contentBackground: Color = AppTheme.Colors.surface

    private let actionWidth: CGFloat = 84

    @State private var offset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    private var totalOffset: CGFloat { offset + dragOffset }

    var body: some View {
        #if os(macOS)
        // Pas de geste de swipe sur Mac : on expose les actions via le menu
        // contextuel (clic droit), pattern desktop natif. Le contenu reste
        // cliquable normalement (NavigationLink / boutons enfants intacts).
        content()
            .contentShape(Rectangle())
            .contextMenu {
                if let onEdit {
                    Button { onEdit() } label: { Label(editLabel, systemImage: "pencil") }
                }
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: { Label(deleteLabel, systemImage: "trash") }
                }
            }
        #else
        swipeBody
        #endif
    }

    #if !os(macOS)
    private var swipeBody: some View {
        ZStack(alignment: .center) {
            // Background actions (révélées par le swipe)
            HStack(spacing: 0) {
                if let onEdit, totalOffset > 0 {
                    actionView(
                        label: editLabel,
                        icon: "pencil",
                        color: AppTheme.Colors.accent,
                        action: { onEdit(); reset() }
                    )
                    Spacer(minLength: 0)
                }
                if onEdit != nil { Spacer(minLength: 0) }
                if let onDelete, totalOffset < 0 {
                    Spacer(minLength: 0)
                    actionView(
                        label: deleteLabel,
                        icon: "trash",
                        color: AppTheme.Colors.danger,
                        action: { onDelete(); reset() }
                    )
                }
            }

            // Contenu principal (avec offset)
            content()
                .background(contentBackground)
                .contentShape(Rectangle())
                .offset(x: totalOffset)
                .overlay {
                    // Quand un swipe est ouvert, on bloque les taps sur la row
                    // pour éviter qu'un tap "pour fermer" déclenche aussi un
                    // NavigationLink ou un Button enfant. Tap sur l'overlay → close.
                    if offset != 0 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { reset() }
                            .offset(x: totalOffset)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 30)
                        .updating($dragOffset) { value, state, _ in
                            // Ne réagit QU'aux mouvements à dominance horizontale.
                            // Sans ça, un scroll vertical mal aligné déclenchait
                            // le swipe et bloquait le scroll de la fiche.
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else {
                                return
                            }
                            // Rubber band si on swipe dans une direction sans action
                            let t = value.translation.width
                            if t > 0 && onEdit == nil {
                                state = t / 4
                            } else if t < 0 && onDelete == nil {
                                state = t / 4
                            } else {
                                state = t
                            }
                        }
                        .onEnded { value in
                            // Idem au end : on ne valide qu'un drag horizontal franc.
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else {
                                offset = 0
                                return
                            }
                            handleDragEnd(translation: value.translation.width)
                        }
                )
        }
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: offset)
    }
    #endif

    private func handleDragEnd(translation: CGFloat) {
        let combined = offset + translation
        let threshold = actionWidth / 2

        if combined > threshold, onEdit != nil {
            offset = actionWidth
        } else if combined < -threshold, onDelete != nil {
            offset = -actionWidth
        } else {
            offset = 0
        }
    }

    private func reset() {
        offset = 0
    }

    @ViewBuilder
    private func actionView(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(color)
        }
        .buttonStyle(.plain)
    }
}
