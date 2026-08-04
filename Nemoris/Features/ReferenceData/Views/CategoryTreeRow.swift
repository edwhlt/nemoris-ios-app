import SwiftUI
import TipKit

struct CategoryTreeRow: View {
    let node: CategoryNode
    let countFor: (Category) -> Int
    let onEdit: (Category) -> Void
    let onDelete: (CategoryNode) -> Void
    /// Clic macOS sur une feuille → panneau détail (no-op iOS via macDetailTap).
    let onSelect: (Category) -> Void
    @State private var isExpanded = true

    var body: some View {
        if node.isLeaf {
            leafRow(node.category, isRootLevel: node.category.parentId == nil)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    CategoryTreeRow(node: child, countFor: countFor, onEdit: onEdit, onDelete: onDelete, onSelect: onSelect)
                }
            } label: {
                parentLabel(node)
                    .rowActions(
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { onEdit(node.category) }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { onDelete(node) }],
                        leadingFullSwipe: false,
                        trailingFullSwipe: false
                    )
            }
        }
    }


    @ViewBuilder
    private func parentLabel(_ node: CategoryNode) -> some View {
        HStack(spacing: 10) {
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
            Spacer()
            EntityIdCountBadge(id: node.category.id, count: countFor(node.category))
            Text("\(node.children.count)")
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(AppTheme.Colors.accent, in: Capsule())
        }
    }

    @ViewBuilder
    private func leafRow(_ category: Category, isRootLevel: Bool) -> some View {
        HStack(spacing: 10) {
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
            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { onEdit(category) }],
            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { onDelete(node) }],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }
}
