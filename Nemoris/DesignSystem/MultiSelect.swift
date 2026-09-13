import SwiftUI

/// Range-based multi-selection — cmd+click (toggles a row) and shift+click
/// (extends from the last touched row), shared by any list that already
/// has its own selection `Set<ID>` + `Bool` (Transactions,
/// Payees, Tags…). PURE functions on `inout` rather than a new state
/// type to migrate to: each screen keeps its existing `@State` and only
/// adds an anchor (`@State private var …Anchor: Int? = nil`).
enum RangeSelection {
    /// A checkbox / plain click while selection is already active:
    /// toggles ONLY this row, sets the anchor for a future shift+click.
    static func toggle<ID: Hashable>(_ id: ID, index: Int, selected: inout Set<ID>, anchor: inout Int?) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchor = index
    }

    /// Shift+click: selects the range between the anchor (the last
    /// touched row) and the clicked index. With no anchor set yet
    /// (the session's first shift+click), behaves like a plain click.
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
    /// Layers cmd+click / shift+click detection on top of a row's normal tap —
    /// the native SwiftUI `TapGesture().modifiers(_:)` API (a physical Mac
    /// keyboard AND an iPad with keyboard+trackpad; a silent no-op on pure
    /// touch iPhone, so no regression where there's no keyboard). A plain
    /// click keeps the row's historical behavior (`onOpen`) as long as
    /// selection isn't active; once active, it toggles the row
    /// exactly like the checkbox.
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
            // `Gesture.modifiers(_:)` (cmd/shift detection on click) only
            // exists on macOS — unavailable on iOS/iPadOS even with a physical
            // keyboard. A plain click (`.onTapGesture` below, cross-
            // platform) stays the only mechanism on those platforms; that's
            // already the native iOS idiom ("Select" mode + tap).
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

/// Shared selection entries, to prefix a row's usual actions
/// via `.rowActions(selection: …)` — a macOS right-click / iOS long press menu.
///
/// - Outside selection (or with only this row selected): an entry point
///   ("Select" / "Select all").
/// - Several rows selected including this one: GROUP actions
///   only — a single row's "Delete" action (provided elsewhere
///   in `trailing`) would be confusing if the two
///   coexisted in the same menu.
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

/// A ⌘A shortcut, scoped to the screen that attaches it (a zero-size button —
/// stays in the responder chain so the shortcut stays active, without
/// taking up space or showing up in accessibility). Selects
/// `allIds` into `selected` and turns on `isSelecting`.
///
/// ⚠️ Deliberately limited in scope to what's already LOADED in memory
/// (`allIds` must be the already-materialized set, not re-fetched) — on
/// a paginated list (Transactions), ⌘A doesn't silently pull in
/// years of unloaded history.
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
