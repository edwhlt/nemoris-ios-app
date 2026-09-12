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
                // Without this, macOS applies the default button chrome
                // (tinted with the app's accent) on top of `macGroupedRow`'s
                // already-green card.
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
            // `List` paints ITS OWN system background on macOS ON TOP OF
            // the host pane's — without this modifier, the user's
            // desktop shows through.
            .scrollContentBackground(.hidden)
            // Detaches the 1st card from `paneChrome`'s Divider() right above it.
            .macGroupedListTopGap()
            #endif
            .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
            .paneChrome("Remboursement par", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
