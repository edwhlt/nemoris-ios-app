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

    /// Category tree — the same construction as Data's Categories tab
    /// (`ReferenceDataView.categoryForest`).
    private var categoryForest: [CategoryNode] {
        CategoryNode.buildForest(from: allCategories)
    }

    var body: some View {
        List {
            noneRow
                .macGroupedRow(first: true, last: true)

            if search.isEmpty {
                // Normal mode: a hierarchical tree (like "Data"), no
                // flat list with an "↳" prefix — depth is read through
                // indentation + the chevron, not a character.
                ForEach(categoryForest) { node in
                    CategoryPickerTreeRow(node: node, depth: 0, currentCategoryId: currentCategoryId) { c in
                        onSelect(c.id, c.name); dismiss()
                    }
                }
            } else {
                // Search mode: the parent context is lost by the filter
                // (a child can match with no parent) — a flat list with a
                // visual indicator, the same convention as
                // `ReferenceDataView.flatCategoryRow`.
                ForEach(filtered) { c in
                    categoryRow(c)
                        .macGroupedRow(first: false, last: c.id == filtered.last?.id)
                }
            }
        }
        #if os(macOS)
        // Same policy as Transactions/Patrimoine/Tricount/ReferenceData:
        // .plain = a neutral base for the custom cards drawn by
        // macGroupedRow. Without it, every row keeps its own isolated
        // rounded background → a "wall of buttons" look instead of a list.
        .listStyle(.plain)
        // `List` paints ITS OWN system background on macOS ON TOP OF the
        // host pane's — without this modifier, the user's desktop
        // shows through.
        .scrollContentBackground(.hidden)
        // Detaches the 1st card from `paneChrome`'s Divider() right above it.
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

    /// A flat row, used ONLY in search mode — the parent context
    /// is lost by the filter (a child can match with no parent), hence
    /// the parent's name as a subtitle (replaces the old "↳", which
    /// indicated a depth with no clue WHOSE it was — the same fix as
    /// `ReferenceDataView.flatCategoryRow`, same convention).
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

/// A selectable tree row — derived from `CategoryTreeRow` (Data), but
/// WITHOUT editing/deletion and with every node (parent OR leaf)
/// directly selectable.
///
/// ⚠️ No `DisclosureGroup`: its tap-to-toggle would cover the WHOLE row,
/// which would prevent tapping a parent to SELECT it (unlike
/// `CategoryTreeRow`, where parents aren't selectable). The chevron
/// is therefore a sibling button, separate from the selection button — the same
/// doctrine as the SQL Console's tree (`SQLConsoleView.entryRow`: "no
/// DisclosureGroup, manual indentation + a separate chevron").
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
                        // ⚠️ Tap zone EXPLICITLY bounded (a tap on this chevron
                        // used to sometimes select the category instead). A
                        // `Button` with tiny visual content (a 14pt icon)
                        // has its tap zone AUTOMATICALLY extended by the system to
                        // the minimum touch target (~44pt) — well beyond its
                        // visible frame, up to overlapping the
                        // selection button right next to it (only 6pt apart).
                        // `.frame` + `.contentShape` bound the tap zone to
                        // a comfortable but FIXED size, which no longer spills
                        // onto its neighbor.
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Reserves the chevron's width (28pt, see above): leaves
                // and parents stay aligned.
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
