import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct CategoryQuickPickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let currentCategoryId: Int?
    let allCategories: [Category]
    let onSelect: (Int?, String) -> Void

    @State private var search = ""

    var filtered: [Category] {
        guard !search.isEmpty else { return allCategories }
        return allCategories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Arbre des catégories — même construction que l'onglet Catégories de
    /// « Données » (`ReferenceDataView.categoryForest`).
    private var categoryForest: [CategoryNode] {
        CategoryNode.buildForest(from: allCategories)
    }

    var body: some View {
        List {
            noneRow
                .macGroupedRow(first: true, last: true)

            if search.isEmpty {
                // Mode normal : arbre hiérarchique (comme « Données »), pas de
                // liste à plat avec préfixe "↳" — la profondeur se lit par
                // l'indentation + le chevron, pas par un caractère.
                ForEach(categoryForest) { node in
                    CategoryPickerTreeRow(node: node, depth: 0, currentCategoryId: currentCategoryId) { c in
                        onSelect(c.id, c.name); dismiss()
                    }
                }
            } else {
                // Mode recherche : le contexte parent est perdu par le filtre
                // (un enfant peut matcher sans son parent) — liste plate avec
                // indicateur visuel, même convention que
                // `ReferenceDataView.flatCategoryRow`.
                ForEach(filtered) { c in
                    categoryRow(c)
                        .macGroupedRow(first: false, last: c.id == filtered.last?.id)
                }
            }
        }
        #if os(macOS)
        // Même politique que Transactions/Patrimoine/Tricount/ReferenceData :
        // .plain = base neutre pour les cartes custom dessinées par
        // macGroupedRow. Sans elle chaque row garde son propre fond
        // arrondi isolé → l'effet "plein de boutons" au lieu d'une liste.
        .listStyle(.plain)
        // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS celui du
        // panneau hôte — sans ce modificateur, le bureau de l'utilisateur
        // transparaît (retour d'usage 2026-08-19).
        .scrollContentBackground(.hidden)
        // Décolle la 1ère carte du Divider() de `paneChrome` juste au-dessus.
        .macGroupedListTopGap()
        #endif
        .paneSearchable(text: $search, prompt: "Rechercher une catégorie…")
        .paneChrome("Catégorie", cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    private var noneRow: some View {
        Button {
            onSelect(nil, ""); dismiss()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.textSecondary.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Text("Aucune catégorie").foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                if currentCategoryId == nil {
                    Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Row à plat, utilisée UNIQUEMENT en mode recherche — le contexte parent
    /// est perdu par le filtre (un enfant peut matcher sans son parent), d'où
    /// le nom du parent en sous-titre (remplace l'ancien "↳", qui indiquait
    /// une profondeur sans dire DE QUI — même correctif que
    /// `ReferenceDataView.flatCategoryRow`, même convention).
    private func categoryRow(_ c: Category) -> some View {
        Button {
            onSelect(c.id, c.name); dismiss()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((c.parentId == nil ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary).opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: c.displayIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(c.parentId == nil ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name)
                        .fontWeight(c.parentId == nil ? .semibold : .regular)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if let parentId = c.parentId,
                       let parentName = allCategories.first(where: { $0.id == parentId })?.name {
                        Text(parentName)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                if c.id == currentCategoryId {
                    Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Row d'arbre sélectionnable — dérivée de `CategoryTreeRow` (Données), mais
/// SANS édition/suppression et avec chaque nœud (parent OU feuille)
/// directement sélectionnable.
///
/// ⚠️ Pas de `DisclosureGroup` : son tap-to-toggle couvrirait TOUTE la ligne,
/// ce qui empêcherait de taper sur un parent pour le CHOISIR (contrairement à
/// `CategoryTreeRow`, où les parents ne sont pas sélectionnables). Le chevron
/// est donc un bouton frère, séparé du bouton de sélection — même doctrine
/// que l'arborescence de la Console SQL (`SQLConsoleView.entryRow` : "pas de
/// DisclosureGroup, indentation manuelle + chevron séparé").
private struct CategoryPickerTreeRow: View {
    let node: CategoryNode
    let depth: Int
    let currentCategoryId: Int?
    let onSelect: (Category) -> Void

    @State private var isExpanded = true

    private var isParent: Bool { node.category.parentId == nil }
    private var hasChildren: Bool { !node.children.isEmpty }

    var body: some View {
        Group {
            row
            if isExpanded {
                ForEach(node.children) { child in
                    CategoryPickerTreeRow(node: child, depth: depth + 1, currentCategoryId: currentCategoryId, onSelect: onSelect)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // ⚠️ Zone de tap EXPLICITEMENT bornée (retour d'usage :
                        // le tap sur ce chevron sélectionnait parfois la
                        // catégorie à la place). Un `Button` dont le contenu
                        // visuel est minuscule (icône 14pt) voit sa zone de
                        // tap AUTOMATIQUEMENT étendue par le système vers la
                        // cible tactile minimale (~44pt) — bien au-delà de son
                        // cadre visible, jusqu'à chevaucher le bouton de
                        // sélection juste à côté (séparés de 6pt seulement).
                        // `.frame` + `.contentShape` bornent la zone de tap à
                        // une taille confortable MAIS FIXE, qui ne déborde
                        // plus sur son voisin.
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Réserve la largeur du chevron (28pt, cf. ci-dessus) : feuilles
                // et parents restent alignés.
                Color.clear.frame(width: 28, height: 1)
            }

            Button {
                onSelect(node.category)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill((isParent ? AppTheme.Colors.accent : AppTheme.Colors.accent.opacity(0.7))
                                .opacity(isParent ? 0.15 : 0.10))
                            .frame(width: isParent ? 30 : 24, height: isParent ? 30 : 24)
                        Image(systemName: node.category.displayIcon)
                            .font(.system(size: isParent ? 14 : 11, weight: .semibold))
                            .foregroundStyle(isParent ? AppTheme.Colors.accent : AppTheme.Colors.accent.opacity(0.8))
                    }
                    Text(node.category.name)
                        .fontWeight(isParent ? .semibold : .regular)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    if node.category.id == currentCategoryId {
                        Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 18)
    }
}
