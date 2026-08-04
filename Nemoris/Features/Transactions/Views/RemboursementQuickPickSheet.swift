import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct RemboursementQuickPickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let allTiers: [Tiers]
    let onSelect: (Int?, String) -> Void

    @State private var search = ""

    var filtered: [Tiers] {
        guard !search.isEmpty else { return allTiers }
        return allTiers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
            List {
                Button("Aucun remboursement") {
                    onSelect(nil, ""); dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(filtered) { t in
                    Button {
                        onSelect(t.id, t.name); dismiss()
                    } label: {
                        Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tiers…")
            .paneChrome("Remboursement par", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
