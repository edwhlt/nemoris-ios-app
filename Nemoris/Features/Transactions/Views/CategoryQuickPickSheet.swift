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

    var body: some View {
            List {
                Button("Aucune catégorie") {
                    onSelect(nil, ""); dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(filtered) { c in
                    Button {
                        onSelect(c.id, c.name); dismiss()
                    } label: {
                        HStack {
                            Text(c.name).foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if c.id == currentCategoryId {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher une catégorie…")
            .paneChrome("Catégorie", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
