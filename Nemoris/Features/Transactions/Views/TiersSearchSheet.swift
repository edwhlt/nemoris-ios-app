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
                // Without this, macOS applies the default button chrome
                // (tinted with the app's accent) on top of `macGroupedRow`'s
                // already-green card.
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
            // Same policy as the other pickers (PayeePickerSheet,
            // CategoryQuickPickSheet…): a neutral base for the cards
            // drawn by macGroupedRow.
            .listStyle(.plain)
            // Detaches the 1st card from `paneChrome`'s Divider() right above it.
            .macGroupedListTopGap()
            // ⚠️ Verified live on `ImportActionsHelpSheet`:
            // a `.frame(maxWidth: .infinity, maxHeight: .infinity)` alone
            // ("greedy", which only fills the space already offered) is NOT
            // ENOUGH to keep a `List` from collapsing when this view
            // is reached via a bare `.sheet()` with NO external
            // `.adaptivePaneFrame()` (e.g. `AddTricountReimbursementSheet`) —
            // macOS then computes the window's height from the content's
            // "natural" size, and a `List` doesn't report it reliably in that
            // context. The NUMERIC `minHeight` is what actually forces
            // a height — the same value as `AdaptivePane.adaptivePaneFrame()`
            // (`minHeight: 520`), to stay consistent with panes that
            // get this constraint from the outside.
            .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            #endif
            // `List` paints ITS OWN system background on macOS (a vibrant/
            // translucent material) ON TOP OF any `.background()` set on
            // the container — without `.scrollContentBackground(.hidden)`, the
            // explicit background below is invisible, see `TagSummaryView`
            // (a screenshot once showed the user's desktop
            // bleeding through an inspector/modal).
            .scrollContentBackground(.hidden)
            .paneSearchable(text: $search, prompt: "Rechercher un tiers…")
            // `.paneChrome` draws its own bars on macOS-sheet — the earlier
            // attempt (`.toolbarBackground(for: .windowToolbar)`)
            // compiled but had NO visual effect at all, confirmed by a live
            // screenshot. See the `macSheetChrome` comment in
            // AdaptivePane.swift. The "+" (create a payee) takes on the
            // "confirm" role — there's no real confirmation button here
            // (the rows select and dismiss directly).
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
