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
                // Sans ça, macOS applique le chrome de bouton par défaut
                // (teinté par l'accent de l'app) par-dessus la carte déjà
                // verte de `macGroupedRow` (retour d'usage 2026-08-21).
                .buttonStyle(.plain)
                .macGroupedRow(first: true, last: filtered.isEmpty)

                ForEach(filtered) { t in
                    Button {
                        onSelect(t.id, t.name); dismiss()
                    } label: {
                        Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .macGroupedRow(first: false, last: t.id == filtered.last?.id)
                }
            }
            #if os(macOS)
            .listStyle(.plain)
            // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS
            // celui du panneau hôte — sans ce modificateur, le bureau de
            // l'utilisateur transparaît (retour d'usage 2026-08-19).
            .scrollContentBackground(.hidden)
            // Décolle la 1ère carte du Divider() de `paneChrome` juste au-dessus.
            .macGroupedListTopGap()
            #endif
            .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
            .paneChrome("Remboursement par", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
