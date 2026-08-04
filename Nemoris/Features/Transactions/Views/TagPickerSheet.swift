import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var allTags: [Tag]
    @Binding var selectedTagIds: Set<Int>
    let repository: TransactionRepository

    @State private var newTagName = ""
    @State private var search = ""

    var filtered: [Tag] {
        guard !search.isEmpty else { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Création rapide
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // Liste des tags
                Section("Tags disponibles") {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Aucun tag créé" : "Aucun résultat")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        ForEach($allTags) { $tag in
                            // N'afficher que les tags correspondant à la recherche
                            if search.isEmpty || tag.name.localizedCaseInsensitiveContains(search) {
                                HStack(spacing: 12) {
                                    Button {
                                        if selectedTagIds.contains(tag.id) { selectedTagIds.remove(tag.id) }
                                        else { selectedTagIds.insert(tag.id) }
                                    } label: {
                                        Image(systemName: selectedTagIds.contains(tag.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedTagIds.contains(tag.id) ? tag.displayColor : .secondary)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.plain)
                                    Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    ColorPicker("", selection: Binding(
                                        get: { tag.displayColor },
                                        set: { newColor in
                                            if let hex = newColor.toTagHex() {
                                                tag.color = hex
                                                repository.updateTagColor(id: tag.id, colorHex: hex)
                                            }
                                        }
                                    ), supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 28, height: 28)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tag…")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            selectedTagIds.insert(id)
            if !allTags.contains(where: { $0.id == id }) {
                allTags.append(Tag(id: id, name: name))
                allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        newTagName = ""
    }
}
