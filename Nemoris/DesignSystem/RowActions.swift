import SwiftUI

/// Row action declared ONCE, rendered per platform:
/// - **iOS**: `.swipeActions` (native Mail/Messages gesture, tint preserved)
///   **and** `.contextMenu` (long press) — same entries, so a row's actions
///   stay reachable even without a swipe (e.g. while browsing one-handed).
/// - **macOS**: `.contextMenu` (right click) — swipe has no mouse equivalent.
///
/// Usage:
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
    /// Tint of the iOS swipe button (ignored by the macOS context menu,
    /// whose items cannot be tinted).
    var tint: Color? = nil
    /// Icon-only on the iOS swipe button (the label text still backs
    /// VoiceOver — `Label` keeps it as the accessibility label even under
    /// `.labelStyle(.iconOnly)`). Ignored by the context menu (long-press iOS /
    /// right-click macOS), which always shows icon + text — a menu row needs
    /// the label to be scannable, unlike a swipe button sized to its icon.
    var iconOnly: Bool = false
    let action: () -> Void

    init(_ title: String,
         systemImage: String,
         role: ButtonRole? = nil,
         tint: Color? = nil,
         iconOnly: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.tint = tint
        self.iconOnly = iconOnly
        self.action = action
    }
}

extension View {
    /// Adaptive row actions (iOS swipe + long-press menu / macOS right-click
    /// menu). Apply to a `List` row. `leading` then `trailing` are merged
    /// into the context menu (separated by a `Divider`); `selection`, when
    /// given, is PREPENDED above both — the multi-selection entry points
    /// ("Select" / "Select all" / group actions), always
    /// first because they answer a different question than the row's own
    /// actions.
    ///
    /// `leadingFullSwipe`/`trailingFullSwipe` mirror the native
    /// `allowsFullSwipe` parameter (defaults to `true`, as in SwiftUI) — pass
    /// `false` for an edge whose action should not trigger on a full swipe.
    func rowActions(selection: [RowAction] = [],
                    leading: [RowAction] = [],
                    trailing: [RowAction] = [],
                    leadingFullSwipe: Bool = true,
                    trailingFullSwipe: Bool = true) -> some View {
        modifier(RowActionsModifier(selection: selection,
                                    leading: leading,
                                    trailing: trailing,
                                    leadingFullSwipe: leadingFullSwipe,
                                    trailingFullSwipe: trailingFullSwipe))
    }
}

private struct RowActionsModifier: ViewModifier {
    let selection: [RowAction]
    let leading: [RowAction]
    let trailing: [RowAction]
    let leadingFullSwipe: Bool
    let trailingFullSwipe: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.contextMenu { menuContent }
        #else
        content
            .contextMenu { menuContent }
            .swipeActions(edge: .leading, allowsFullSwipe: leadingFullSwipe) {
                ForEach(leading) { swipeButton($0) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: trailingFullSwipe) {
                ForEach(trailing) { swipeButton($0) }
            }
        #endif
    }

    @ViewBuilder private var menuContent: some View {
        ForEach(selection) { menuButton($0) }
        if !selection.isEmpty && !(leading.isEmpty && trailing.isEmpty) { Divider() }
        ForEach(leading) { menuButton($0) }
        if !leading.isEmpty && !trailing.isEmpty { Divider() }
        ForEach(trailing) { menuButton($0) }
    }

    @ViewBuilder private func menuButton(_ a: RowAction) -> some View {
        Button(role: a.role) { a.action() } label: {
            Label(LocalizedStringKey(a.title), systemImage: a.systemImage)
        }
    }

    #if !os(macOS)
    @ViewBuilder private func swipeButton(_ a: RowAction) -> some View {
        Button(role: a.role) { a.action() } label: {
            if a.iconOnly {
                Label(LocalizedStringKey(a.title), systemImage: a.systemImage)
                    .labelStyle(.iconOnly)
            } else {
                Label(LocalizedStringKey(a.title), systemImage: a.systemImage)
            }
        }
        .tint(a.tint)
    }
    #endif
}
