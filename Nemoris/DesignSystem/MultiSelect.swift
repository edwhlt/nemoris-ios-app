import SwiftUI

/// Sélection multiple par plage — cmd+clic (bascule une ligne) et maj+clic
/// (étend depuis la dernière ligne touchée), partagés par toute liste qui
/// possède déjà son propre `Set<ID>` + `Bool` de sélection (Transactions,
/// Tiers, Tags…). Fonctions PURES sur des `inout` plutôt qu'un nouveau type
/// d'état à migrer : chaque écran garde ses `@State` existants et n'ajoute
/// qu'une ancre (`@State private var …Anchor: Int? = nil`).
enum RangeSelection {
    /// Case à cocher / clic simple pendant que la sélection est déjà active :
    /// bascule SEULEMENT cette ligne, pose l'ancre pour un futur maj+clic.
    static func toggle<ID: Hashable>(_ id: ID, index: Int, selected: inout Set<ID>, anchor: inout Int?) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchor = index
    }

    /// Maj+clic : sélectionne la plage entre l'ancre (dernière ligne
    /// touchée) et l'index cliqué. Sans ancre encore posée (premier
    /// maj+clic de la session), se comporte comme un clic simple.
    static func extend<ID: Hashable>(to id: ID, index: Int, allIds: [ID], selected: inout Set<ID>, anchor: inout Int?) {
        guard let a = anchor, allIds.indices.contains(a) else {
            selected.insert(id)
            anchor = index
            return
        }
        let range = a <= index ? a...index : index...a
        for i in range where allIds.indices.contains(i) {
            selected.insert(allIds[i])
        }
        anchor = index
    }
}

extension View {
    /// Superpose au tap normal d'une row la détection cmd+clic / maj+clic —
    /// API SwiftUI native `TapGesture().modifiers(_:)` (clavier physique Mac
    /// ET iPad clavier+trackpad ; no-op silencieux sur iPhone tactile pur,
    /// donc aucune régression là où il n'y a pas de clavier). Le clic nu
    /// garde le comportement historique de la row (`onOpen`) tant que la
    /// sélection n'est pas active ; une fois active, il bascule la ligne
    /// exactement comme la case à cocher.
    func selectableRow<ID: Hashable>(
        id: ID,
        index: Int,
        allIds: [ID],
        isSelecting: Binding<Bool>,
        selected: Binding<Set<ID>>,
        anchor: Binding<Int?>,
        onOpen: @escaping () -> Void
    ) -> some View {
        modifier(SelectableRowModifier(id: id, index: index, allIds: allIds,
                                        isSelecting: isSelecting, selected: selected, anchor: anchor,
                                        onOpen: onOpen))
    }
}

private struct SelectableRowModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let index: Int
    let allIds: [ID]
    let isSelecting: Binding<Bool>
    let selected: Binding<Set<ID>>
    let anchor: Binding<Int?>
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // `Gesture.modifiers(_:)` (détection cmd/maj au clic) n'existe
            // QUE sur macOS — indisponible sur iOS/iPadOS même avec clavier
            // physique. Le clic nu (`.onTapGesture` plus bas, cross-
            // platform) reste le seul mécanisme sur ces plateformes ; c'est
            // déjà l'idiome iOS natif (mode "Sélectionner" + tap).
            #if os(macOS)
            .highPriorityGesture(
                TapGesture().modifiers(.shift).onEnded {
                    isSelecting.wrappedValue = true
                    RangeSelection.extend(to: id, index: index, allIds: allIds,
                                           selected: &selected.wrappedValue, anchor: &anchor.wrappedValue)
                }
            )
            .highPriorityGesture(
                TapGesture().modifiers(.command).onEnded {
                    isSelecting.wrappedValue = true
                    RangeSelection.toggle(id, index: index, selected: &selected.wrappedValue, anchor: &anchor.wrappedValue)
                }
            )
            #endif
            .onTapGesture {
                if isSelecting.wrappedValue {
                    RangeSelection.toggle(id, index: index, selected: &selected.wrappedValue, anchor: &anchor.wrappedValue)
                } else {
                    onOpen()
                }
            }
    }
}

/// Entrées de sélection communes, à préfixer aux actions habituelles d'une
/// row via `.rowActions(selection: …)` — right-click macOS / appui long iOS.
///
/// - Hors sélection (ou ligne seule sélectionnée) : point d'entrée
///   ("Sélectionner" / "Tout sélectionner").
/// - Plusieurs lignes sélectionnées dont celle-ci : actions de GROUPE
///   seulement — l'action "Supprimer" d'une seule ligne (fournie par
///   ailleurs dans `trailing`) prêterait à confusion si les deux
///   coexistaient dans le même menu.
func selectionRowActions(
    isSelecting: Bool,
    isSelected: Bool,
    selectionCount: Int,
    toggle: @escaping () -> Void,
    selectAll: @escaping () -> Void,
    clearSelection: @escaping () -> Void,
    deleteSelection: @escaping () -> Void
) -> [RowAction] {
    if isSelecting && isSelected && selectionCount > 1 {
        return [
            RowAction("Désélectionner tout", systemImage: "xmark.circle", action: clearSelection),
            RowAction("Supprimer la sélection (\(selectionCount))", systemImage: "trash", role: .destructive, action: deleteSelection)
        ]
    } else {
        return [
            RowAction(isSelecting ? "Ajouter à la sélection" : "Sélectionner", systemImage: "checkmark.circle", action: toggle),
            RowAction("Tout sélectionner", systemImage: "checklist", action: selectAll)
        ]
    }
}

/// Raccourci ⌘A, scopé à l'écran qui l'attache (bouton de taille nulle —
/// reste dans la chaîne de répondeurs donc le raccourci reste actif, sans
/// occuper de place ni apparaître dans l'accessibilité). Sélectionne
/// `allIds` dans `selected` et active `isSelecting`.
///
/// ⚠️ Portée volontairement limitée à ce qui est déjà CHARGÉ en mémoire
/// (`allIds` doit être le jeu déjà matérialisé, pas re-fetché) — sur une
/// liste paginée (Transactions), ⌘A ne ramène pas silencieusement des
/// années d'historique non chargées.
struct SelectAllShortcut<ID: Hashable>: View {
    let isSelecting: Binding<Bool>
    let selected: Binding<Set<ID>>
    let allIds: [ID]

    var body: some View {
        Button("") {
            isSelecting.wrappedValue = true
            selected.wrappedValue = Set(allIds)
        }
        .keyboardShortcut("a", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
