import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagManagementSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let initialTagIds: Set<Int>
    let allTags: [Tag]
    let repository: TransactionRepository
    let onSave: (Set<Int>) -> Void
    let onNewTag: (Tag) -> Void

    @State private var selectedTagIds: Set<Int>
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""
    @State private var tagColors: [Int: Color] = [:]

    init(initialTagIds: Set<Int>, allTags: [Tag], repository: TransactionRepository,
         onSave: @escaping (Set<Int>) -> Void, onNewTag: @escaping (Tag) -> Void) {
        self.initialTagIds = initialTagIds
        self.allTags = allTags
        self.repository = repository
        self.onSave = onSave
        self.onNewTag = onNewTag
        _selectedTagIds = State(initialValue: initialTagIds)
        _localAllTags = State(initialValue: allTags)
    }

    var body: some View {
            List {
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section(localAllTags.isEmpty ? "Aucun tag créé" : "Tags") {
                    ForEach($localAllTags) { $tag in
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
                            // Color picker inline
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
            #if os(macOS)
            // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS
            // celui du panneau hôte — sans ce modificateur, le bureau de
            // l'utilisateur transparaît (retour d'usage 2026-08-19).
            .scrollContentBackground(.hidden)
            #endif
            .paneChrome("Tags",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark") {
                onSave(selectedTagIds); dismiss()
            }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            selectedTagIds.insert(id)
            let tag = Tag(id: id, name: name)
            if !localAllTags.contains(where: { $0.id == id }) {
                localAllTags.append(tag)
                localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onNewTag(tag)
            }
        }
        newTagName = ""
    }
}
