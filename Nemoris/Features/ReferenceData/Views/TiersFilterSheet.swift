import SwiftUI

/// Structured filter for `ReferenceDataView`'s Payees tab — group /
/// category / city / country. Distinct from the text search (name/regex)
/// already provided by `.searchable`: the two combine (AND), the same
/// principle as `TransactionFiltersSheet` (payee + label).
struct TiersFilterSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss

    let allCategories: [Category]
    let payeeGroups: [PayeeGroup]
    @Binding var groupId: Int?
    @Binding var categoryId: Int?
    @Binding var city: String
    @Binding var country: String
    let onApply: () -> Void

    // Local copies — only written to the bindings on "Apply", so as
    // not to refilter/re-sort ~1000 payees on every character typed (same reason
    // as `localPayeeSearch`/`localLabelSearch` in `TransactionFiltersSheet`).
    @State private var localGroupId: Int?
    @State private var localCategoryId: Int?
    @State private var localCity: String = ""
    @State private var localCountry: String = ""

    /// Flattened in pre-order with depth-based indentation — the same pattern
    /// as `TransactionFiltersSheet.categoryPickerEntries` (a `Picker` doesn't
    /// render a real foldable tree, but indentation conveys the
    /// hierarchy without removing anything: both a parent AND its children stay selectable).
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
        // `.paneChrome` draws its own bars on macOS-sheet — the same
        // convention as `TransactionFiltersSheet`/`MetadataKeyManagerView`.
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
