import SwiftUI
import TipKit

/// A FLAT row of the category tree (Data → Categories, normal mode).
///
/// ⚠️ No `DisclosureGroup` — the macOS rendering didn't
/// match iOS (a plain `.macGroupedRow(first:last:)` set at each level of
/// recursion produces a card PER group of siblings, so the tree fragments
/// into separate mini-cards, whereas iOS ignores
/// `first`/`last` and natively renders ONE continuous `.insetGrouped`
/// list for the whole tab). A structural fix, not a `first`/`last`
/// patch: the tree is flattened upstream (`ReferenceDataView.
/// visibleCategoryRows`, modeled on `SQLConsoleView.visibleRows` —
/// the same doctrine: "manual indentation + a separate chevron, no
/// DisclosureGroup") into a FLAT list of the currently VISIBLE nodes
/// given the current fold/unfold state. `first`/`last` are then computed
/// once, on the node's GLOBAL position in that flattened list —
/// exactly like `flatCategoryRow`/`TierRow`/everything else in the
/// app — and macOS gets back the same continuous, single card as iOS.
struct CategoryTreeRow: View {
    let node: CategoryNode
    /// Depth in the tree (0 = root) — drives manual indentation,
    /// since `DisclosureGroup`'s automatic one is gone along with it.
    let depth: Int
    /// nil for a leaf (nothing to fold/unfold).
    let isExpanded: Bool?
    let onToggleExpand: () -> Void
    let countFor: (Category) -> Int
    let onEdit: (Category) -> Void
    let onDelete: (CategoryNode) -> Void
    /// A macOS click on a leaf → the detail pane (a no-op on iOS via macDetailTap).
    let onSelect: (Category) -> Void
    /// Position in the FLATTENED, VISIBLE list — not among siblings alone
    /// (see the header comment): that's what gives ONE continuous card.
    var isFirst: Bool = true
    var isLast: Bool = true

    private var indent: CGFloat { CGFloat(depth) * 18 }

    var body: some View {
        if node.isLeaf {
            leafRow(node.category, isRootLevel: depth == 0)
                .padding(.leading, indent)
                .macGroupedRow(first: isFirst, last: isLast)
        } else {
            parentRow(node)
                .padding(.leading, indent)
                .rowActions(
                    leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { onEdit(node.category) }],
                    trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { onDelete(node) }],
                    leadingFullSwipe: false,
                    trailingFullSwipe: false
                )
                .macGroupedRow(first: isFirst, last: isLast)
        }
    }

    /// A parent's row — tap anywhere = fold/unfold (like
    /// `DisclosureGroup` before it: a parent isn't selectable in
    /// this screen, only foldable/unfoldable or editable/deletable via
    /// swipe, so there's no tap-zone conflict to isolate here — unlike
    /// a transaction's category picker, where a parent IS
    /// selectable, see `CategoryPickerTreeRow` in
    /// `CategoryQuickPickSheet.swift`).
    @ViewBuilder
    private func parentRow(_ node: CategoryNode) -> some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
                    .frame(width: 14)
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: node.category.displayIcon)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(node.category.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                EntityIdCountBadge(id: node.category.id, count: countFor(node.category))
                Text("\(node.children.count)")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(AppTheme.Colors.accent, in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func leafRow(_ category: Category, isRootLevel: Bool) -> some View {
        HStack(spacing: 10) {
            // Reserves `parentRow`'s chevron width (14pt): a
            // category WITH NO children (so rendered here, never by
            // `parentRow`) must align with a category WITH children at the
            // same level — without this spacer, a childless root category's
            // icon/name started 14pt further left than a
            // childless root category with children.
            Color.clear.frame(width: 14, height: 1)
            if isRootLevel {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.textSecondary.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: category.displayIcon)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.system(size: 13))
                }
            } else {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppTheme.Colors.accent.opacity(0.25))
                        .frame(width: 2, height: 18)
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.10))
                            .frame(width: 24, height: 24)
                        Image(systemName: category.displayIcon)
                            .foregroundStyle(AppTheme.Colors.accent.opacity(0.8))
                            .font(.system(size: 11))
                    }
                }
            }
            Text(category.name).foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            EntityIdCountBadge(id: category.id, count: countFor(category))
        }
        .contentShape(Rectangle())
        .macDetailTap { onSelect(category) }
        .rowActions(
            // `node` (the struct's property, not a local parameter) IS already
            // this leaf node — `body` only calls `leafRow` in the
            // `node.isLeaf` branch, `category` above being just
            // `node.category` passed as a parameter.
            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { onEdit(category) }],
            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { onDelete(node) }],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }
}
