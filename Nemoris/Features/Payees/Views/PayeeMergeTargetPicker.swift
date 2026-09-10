import SwiftUI

/// Étape 1 (source UNIQUE) d'une fusion de tiers DOUBLONS : cherche le
/// second tier à fusionner parmi tous les autres — utilisé seulement par le
/// swipe "Fusionner…" d'UNE row (`ReferenceDataView.mergeTierSearchSourceId`).
/// Une fusion groupée (2+ tiers déjà sélectionnés) n'a pas besoin de cet
/// écran : elle va directement au résolveur de champs, cf.
/// `PayeeMergeResolverView` — c'est LUI qui commet la fusion, pas ce picker.
/// Niveau 2 (`.adaptivePane`) depuis `ReferenceDataView`, elle-même niveau 1
/// — bascule en sheet bornée sur macOS. Même doctrine que
/// `PayeeGroupMergeTargetPicker` (`PayeeGroupManagerView.swift`).
struct PayeeMergeTargetPicker: View {
    /// Nom du tier déjà désigné (swipe), pour le titre/footer.
    let sourceName: String
    let candidates: [Tiers]
    let onSelect: (Tiers) -> Void

    @Environment(\.paneDismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Tiers] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return candidates }
        let q = search.lowercased()
        return candidates.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    message: "Aucun autre tier ne correspond."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { t in
                        Button {
                            onSelect(t)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                if let r = t.regex, !r.isEmpty {
                                    Text(r).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(verbatim: "L'étape suivante permet de choisir, champ par champ, les informations à garder entre « \(sourceName) » et le tier choisi.")
                }
            }
        }
        #if os(macOS)
        // Même politique que les autres listes de panneaux : `.plain` = base
        // neutre, hauteur forcée sans `.adaptivePaneFrame()` externe.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .tint(AppTheme.Colors.accent)
        .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
        .paneChrome("Fusionner « \(sourceName) »", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
