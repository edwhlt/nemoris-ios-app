import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TiersSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let allTiers: [Tiers]
    @Binding var selectedId: Int
    /// Optional: called with the current search text when "+" is tapped. Parent opens a create form.
    var onCreateTiers: ((String) -> Void)? = nil

    @State private var search = ""

    var filtered: [Tiers] {
        guard !search.isEmpty else { return allTiers }
        return allTiers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
            List {
                Button("Aucun") {
                    selectedId = -1
                    dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)
                // Sans ça, macOS applique le chrome de bouton par défaut
                // (teinté par l'accent de l'app) par-dessus la carte déjà
                // verte de `macGroupedRow` (retour d'usage 2026-08-21).
                .buttonStyle(.plain)
                .macGroupedRow(first: true, last: filtered.isEmpty)

                ForEach(filtered) { t in
                    Button {
                        selectedId = t.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                if let r = t.regex, !r.isEmpty {
                                    Text(r).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                            Spacer()
                            if selectedId == t.id {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .macGroupedRow(first: false, last: t.id == filtered.last?.id)
                }
            }
            #if os(macOS)
            // Même politique que les autres pickers (PayeePickerSheet,
            // CategoryQuickPickSheet…) : base neutre pour les cartes
            // dessinées par macGroupedRow.
            .listStyle(.plain)
            // Décolle la 1ère carte du Divider() de `paneChrome` juste au-dessus.
            .macGroupedListTopGap()
            // ⚠️ Vérifié en direct (2026-08-26) sur `ImportActionsHelpSheet` :
            // un `.frame(maxWidth: .infinity, maxHeight: .infinity)` seul
            // (« greedy », qui ne fait que remplir l'espace déjà offert) NE
            // SUFFIT PAS à empêcher un `List` de s'effondrer quand cette vue
            // est atteinte via un `.sheet()` brut SANS `.adaptivePaneFrame()`
            // externe (ex. `AddTricountReimbursementSheet`) — macOS calcule
            // alors la hauteur de la fenêtre depuis la taille "naturelle" du
            // contenu, et un `List` ne la reporte pas de façon fiable dans ce
            // contexte. Le `minHeight` NUMÉRIQUE est ce qui force réellement
            // une hauteur — même valeur que `AdaptivePane.adaptivePaneFrame()`
            // (`minHeight: 520`), pour rester cohérent avec les panes qui,
            // eux, obtiennent cette contrainte de l'extérieur.
            .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            #endif
            // `List` peint SON PROPRE fond système sur macOS (matériau
            // vibrant/translucide) PAR-DESSUS tout `.background()` posé sur
            // le conteneur — sans `.scrollContentBackground(.hidden)`, le
            // fond explicite ci-dessous est invisible, cf. `TagSummaryView`
            // (retour d'usage 2026-08-19, capture montrant le bureau de
            // l'utilisateur qui bleedait à travers un inspecteur/modal).
            .scrollContentBackground(.hidden)
            .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // tentative précédente (`.toolbarBackground(for: .windowToolbar)`)
            // compilait mais n'avait AUCUN effet visuel, confirmé par capture
            // d'écran en direct (retour d'usage 2026-08-21). Cf. le
            // commentaire de `macSheetChrome` dans AdaptivePane.swift. Le "+"
            // (créer un tiers) prend le rôle "confirm" — il n'y a pas de
            // vrai bouton de confirmation ici (les rows sélectionnent et
            // ferment directement).
            .paneChrome(
                "Choisir un tiers",
                cancelLabel: "Annuler", onCancel: { dismiss() },
                confirmLabel: onCreateTiers != nil ? "Créer" : nil,
                confirmIcon: "plus",
                onConfirm: onCreateTiers != nil ? {
                    let prefill = search.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    // Small delay so dismiss completes before parent opens next sheet
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onCreateTiers?(prefill)
                    }
                } : nil
            )
    }
}
