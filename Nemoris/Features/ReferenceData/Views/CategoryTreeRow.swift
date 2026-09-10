import SwiftUI
import TipKit

/// Row PLATE de l'arbre des catégories (Données → Catégories, mode normal).
///
/// ⚠️ Pas de `DisclosureGroup` — retour d'usage : le rendu macOS ne
/// correspondait pas à iOS (une simple `.macGroupedRow(first:last:)` posée
/// niveau par niveau de récursion fabrique une carte PAR groupe de frères,
/// donc un arbre fragmenté en mini-cartes séparées, alors qu'iOS ignore
/// `first`/`last` et rend nativement UNE seule liste `.insetGrouped`
/// continue pour tout l'onglet). Remède structurel, pas un correctif de
/// `first`/`last` : l'arbre est aplati en amont (`ReferenceDataView.
/// visibleCategoryRows`, sur le modèle de `SQLConsoleView.visibleRows` —
/// même doctrine, "indentation manuelle + chevron séparé, pas de
/// DisclosureGroup") en une liste PLATE des nœuds VISIBLES compte tenu du
/// pli/dépli courant. `first`/`last` se calculent alors une seule fois, sur
/// la position GLOBALE dans cette liste aplatie — exactement comme
/// `flatCategoryRow`/`TierRow`/tout le reste de l'app — et macOS retrouve la
/// même carte unique et continue qu'iOS.
struct CategoryTreeRow: View {
    let node: CategoryNode
    /// Profondeur dans l'arbre (0 = racine) — pilote l'indentation manuelle,
    /// l'automatique de `DisclosureGroup` ayant disparu avec lui.
    let depth: Int
    /// nil pour une feuille (rien à plier/déplier).
    let isExpanded: Bool?
    let onToggleExpand: () -> Void
    let countFor: (Category) -> Int
    let onEdit: (Category) -> Void
    let onDelete: (CategoryNode) -> Void
    /// Clic macOS sur une feuille → panneau détail (no-op iOS via macDetailTap).
    let onSelect: (Category) -> Void
    /// Position dans la liste APLATIE et VISIBLE — pas parmi les seuls frères
    /// (cf. commentaire de tête) : c'est ce qui donne UNE carte continue.
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

    /// Ligne d'un parent — tap n'importe où = plier/déplier (comme
    /// `DisclosureGroup` avant lui : un parent n'est pas sélectionnable dans
    /// cet écran, seulement pliable/dépliable ou modifiable/supprimable par
    /// swipe, donc aucun conflit de zone de tap à isoler ici — contrairement
    /// au picker de catégorie d'une transaction où un parent EST
    /// sélectionnable, cf. `CategoryPickerTreeRow` dans
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
            // Réserve la largeur du chevron de `parentRow` (14pt) : une
            // catégorie SANS enfant (donc rendue ici, jamais par
            // `parentRow`) doit s'aligner avec une catégorie AVEC enfants du
            // même niveau — sans ce spacer, l'icône/le nom d'une catégorie
            // racine sans enfant démarrait 14pt plus à gauche qu'une
            // catégorie racine avec enfants (retour d'usage).
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
            // `node` (propriété du struct, pas un paramètre local) EST déjà
            // ce nœud feuille — `body` n'appelle `leafRow` que dans la
            // branche `node.isLeaf`, `category` ci-dessus n'étant que
            // `node.category` passé en paramètre.
            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { onEdit(category) }],
            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { onDelete(node) }],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }
}
