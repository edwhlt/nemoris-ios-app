import SwiftUI

/// Filtre structuré de l'onglet Tiers de `ReferenceDataView` — groupe /
/// catégorie / ville / pays. Distinct de la recherche texte (nom/regex)
/// déjà fournie par `.searchable` : les deux se combinent (ET), même
/// principe que `TransactionFiltersSheet` (tiers + libellé).
struct TiersFilterSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss

    let allCategories: [Category]
    let payeeGroups: [PayeeGroup]
    @Binding var groupId: Int?
    @Binding var categoryId: Int?
    @Binding var city: String
    @Binding var country: String
    let onApply: () -> Void

    // Copies locales — n'écrivent dans les bindings qu'à "Appliquer", pour ne
    // pas refiltrer/re-trier ~1000 tiers à chaque caractère tapé (même raison
    // que `localPayeeSearch`/`localLabelSearch` dans `TransactionFiltersSheet`).
    @State private var localGroupId: Int?
    @State private var localCategoryId: Int?
    @State private var localCity: String = ""
    @State private var localCountry: String = ""

    /// Aplatie en pré-ordre avec indentation par profondeur — même pattern
    /// que `TransactionFiltersSheet.categoryPickerEntries` (un `Picker` ne
    /// rend pas un vrai arbre pliable, mais l'indentation transmet la
    /// hiérarchie sans rien retirer : parent ET enfants restent sélectionnables).
    private var categoryPickerEntries: [(node: CategoryNode, depth: Int)] {
        CategoryNode.flattenedForest(CategoryNode.buildForest(from: allCategories))
    }

    var body: some View {
        Form {
            Section {
                Picker("Groupe", selection: $localGroupId) {
                    Text("Tous").tag(Int?.none)
                    ForEach(payeeGroups) { g in
                        Text(g.displayName).tag(Int?.some(g.id))
                    }
                }
                Picker("Catégorie", selection: $localCategoryId) {
                    Text("Toutes").tag(Int?.none)
                    ForEach(categoryPickerEntries, id: \.node.id) { entry in
                        Text(String(repeating: "    ", count: entry.depth) + entry.node.category.name)
                            .tag(Int?.some(entry.node.category.id))
                    }
                }
            } header: {
                Text("Catégorisation")
            }

            Section {
                TextField("Ville…", text: $localCity)
                    .autocorrectionDisabled()
                TextField("Pays (code ou nom)…", text: $localCountry)
                    .autocorrectionDisabled()
            } header: {
                Text("Localisation")
            }

            Section {
                Button("Réinitialiser les filtres") {
                    localGroupId    = nil
                    localCategoryId = nil
                    localCity       = ""
                    localCountry    = ""
                }
                .foregroundStyle(AppTheme.Colors.danger)
            }
        }
        .nemorisFormStyle()
        .tint(AppTheme.Colors.accent)
        .onAppear {
            localGroupId    = groupId
            localCategoryId = categoryId
            localCity       = city
            localCountry    = country
        }
        // `.paneChrome` dessine ses propres barres sur macOS-sheet — même
        // convention que `TransactionFiltersSheet`/`MetadataKeyManagerView`.
        .paneChrome(
            "Filtres",
            cancelLabel: "Fermer", onCancel: { paneDismiss() },
            confirmLabel: "Appliquer", confirmIcon: "checkmark",
            onConfirm: {
                groupId    = localGroupId
                categoryId = localCategoryId
                city       = localCity
                country    = localCountry
                onApply()
                paneDismiss()
            }
        )
    }
}
