import SwiftUI

/// Row action declared ONCE, rendered per platform:
/// - **iOS**: `.swipeActions` (native Mail/Messages gesture, tint preserved).
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
    /// Adaptive row actions (iOS swipe / macOS context menu).
    /// Apply to a `List` row. On macOS, `leading` then `trailing` are merged
    /// into the right-click menu (separated by a `Divider`).
    ///
    /// `leadingFullSwipe`/`trailingFullSwipe` mirror the native
    /// `allowsFullSwipe` parameter (defaults to `true`, as in SwiftUI) — pass
    /// `false` for an edge whose action should not trigger on a full swipe.
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
