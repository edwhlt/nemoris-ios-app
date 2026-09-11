import SwiftUI

/// Step 1 (SINGLE source) of a DUPLICATE payee merge: searches for the
/// second payee to merge among all the others — used only by a single row's
/// "Merge…" swipe (`ReferenceDataView.mergeTierSearchSourceId`). A bulk merge
/// (2+ payees already selected) doesn't need this screen: it goes straight to
/// the field resolver, see `PayeeMergeResolverView` — THAT is what commits
/// the merge, not this picker. Level 2 (`.adaptivePane`) from
/// `ReferenceDataView`, itself level 1 — falls back to a bounded sheet on
/// macOS. Same doctrine as `PayeeGroupMergeTargetPicker`
/// (`PayeeGroupManagerView.swift`).
struct PayeeMergeTargetPicker: View {
    /// Name of the already-designated payee (swipe), for the title/footer.
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
                    // Literal interpolation (not `verbatim:`): the static
                    // prose is translatable, only the embedded payee name is
                    // raw data — `verbatim:` here permanently pinned this
                    // footer to French, cf. CLAUDE.md §5.
                    Text("L'étape suivante permet de choisir, champ par champ, les informations à garder entre « \(sourceName) » et le tier choisi.")
                }
            }
        }
        #if os(macOS)
        // Same policy as the other pane lists: `.plain` = neutral base,
        // height forced without an external `.adaptivePaneFrame()`.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .tint(AppTheme.Colors.accent)
        .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
        // Same remedy as `PayeeGroupManagerView`'s merge picker:
        // `AppLocalization.string(...)` resolves the STATIC "Fusionner « » "
        // template via `String.LocalizationValue` interpolation before
        // `paneChrome` (whose `title:` is a plain `String`) ever sees it.
        .paneChrome(AppLocalization.string("Fusionner « \(sourceName) »"), cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
