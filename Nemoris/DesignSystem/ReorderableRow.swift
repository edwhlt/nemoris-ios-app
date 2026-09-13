import SwiftUI
#if os(macOS)
import UniformTypeIdentifiers
#endif

// MARK: - macOS row drag reorder
//
// `.onMove(perform:)` alone does NOT produce a working drag gesture on macOS
// in this app — confirmed by direct usage on `ModulesSettingsView` and
// `DashboardCustomizeView`, both `List`-backed at the time and both
// already wired with `.onMove`: dragging a row silently did nothing on
// device. `.onMove` stays wired anyway (harmless, and iOS still needs it to
// drive its edit-mode reorder handle) but macOS reordering goes through the
// lower-level `onDrag`/`onDrop` pair below instead — the classic mechanism
// SwiftUI reordering was built on before `.onMove` existed, and the one that
// actually drives the drag gesture here. It works on `Form` rows just as well
// as `List` rows (generic view modifiers, not tied to either container) —
// both screens now use `Form`, cf. `ReorderDropDelegate`'s history below for
// why `List` specifically turned out to be a problem for `ModulesSettingsView`.
//
// ⚠️ History of this delegate, and why it looks the way it does now (three
// rounds):
// 1. First version moved `items` live in `dropEntered` (rows slide out of
//    the way while dragging, à la iOS) AND in `performDrop`. Freeze reported
//    on release.
// 2. Hypothesis: `dropEntered`'s live move reflows row geometry under the
//    cursor, re-firing `dropEntered` in a feedback loop. Moved the mutation
//    to `performDrop` ONLY, no live preview. Freeze was STILL there on
//    release, AND the live drag animation was gone — so the feedback-loop
//    hypothesis was wrong, and removing the live preview bought nothing.
// 3. `dropEntered` live-move restored (the animation back). The mutation
//    itself was never the expensive part in EITHER version; what's actually
//    suspected now is the interaction between AppKit's own `NSDraggingSession`
//    teardown and a `List` (NSTableView-backed on macOS) — `ModulesSettingsView`
//    (a `List`) is the one that froze, `DashboardCustomizeView` (already
//    reverted to `Form` by the time this delegate was last touched) was not
//    reported to. Fixed at the CALLER level by moving `ModulesSettingsView`
//    itself off `List` onto `Form` too — same as `DashboardCustomizeView` —
//    since `macReorderable` never required `List` in the first place.
//    `performDrop` still defers `onReorder` by one runloop tick as a cheap,
//    harmless safety net: AppKit expects `performDrop` to return promptly,
//    and whatever `onReorder` ends up doing (currently a no-op at both call
//    sites, but not guaranteed to stay that way) shouldn't run synchronously
//    inside its completion callback.
#if os(macOS)
private struct ReorderDropDelegate<Item: Equatable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var draggedItem: Item?
    var onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItem, draggedItem != item,
              let from = items.firstIndex(of: draggedItem),
              let to = items.firstIndex(of: item),
              from != to
        else { return }
        withAnimation(.default) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        DispatchQueue.main.async { onReorder() }
        return true
    }
}
#endif

extension View {
    /// Makes a row draggable for reordering, macOS only (no-op on iOS —
    /// that platform reorders via `.onMove` + forced edit mode, cf.
    /// `ModulesSettingsView`/`DashboardCustomizeView`).
    ///
    /// `onDrag`/`onDrop` are generic view modifiers, NOT tied to `List` —
    /// unlike `.onMove` (which needs a real `List`/`ForEach`, cf. the doc
    /// above), this works just as well on a `Form` row. Use whichever
    /// container fits the screen's look; this modifier doesn't force either.
    ///
    /// `items`/`dragged` mirror the row's own list and a shared "currently
    /// dragged element" state (one `@State private var dragged<Thing>:
    /// Item?` per screen) — the live reorder happens on `items` as the drag
    /// crosses other rows (cf. `ReorderDropDelegate` above); `onReorder`
    /// fires once, shortly after drop, to persist the final order wherever
    /// it needs to live (e.g. `appState.foo = items`) — though when `items`
    /// is already a direct binding to the persisted source of truth (as in
    /// both current call sites), there's nothing left for it to do.
    func macReorderable<Item: Equatable>(
        _ item: Item,
        items: Binding<[Item]>,
        dragged: Binding<Item?>,
        onReorder: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        return self
            .onDrag {
                dragged.wrappedValue = item
                // The provider's content is never read back — only its
                // presence drives macOS's drag session (cursor, drop
                // targeting). The actual moved element is tracked via
                // `dragged`, not this string.
                return NSItemProvider(object: String(describing: item) as NSString)
            }
            .onDrop(
                of: [.text],
                delegate: ReorderDropDelegate(item: item, items: items, draggedItem: dragged, onReorder: onReorder)
            )
        #else
        return self
        #endif
    }
}

#if os(macOS)
/// A visible affordance for a `macReorderable` row — without it, the row is
/// draggable but nothing on screen says so ("you can
/// drag, but you can't see that you can"). Purely decorative (a drag
/// starts from anywhere on the row, not just this glyph) — placed at the
/// row's trailing edge, the conventional spot for a reorder handle.
struct ReorderHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            .accessibilityHidden(true)
    }
}
#endif
