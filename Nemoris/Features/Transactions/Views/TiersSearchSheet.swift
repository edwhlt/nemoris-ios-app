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
        NavigationStack {
            List {
                Button("Aucun") {
                    selectedId = -1
                    dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

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
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tiers…")
            .navigationTitle("Choisir un tiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                if let onCreateTiers {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            let prefill = search.trimmingCharacters(in: .whitespaces)
                            dismiss()
                            // Small delay so dismiss completes before parent opens next sheet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onCreateTiers(prefill)
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
    }
}
