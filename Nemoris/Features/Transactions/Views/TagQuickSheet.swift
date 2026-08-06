import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagQuickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let transactionId: Int
    let allTags: [Tag]
    let repository: TransactionRepository
    let onNewTag: (Tag) -> Void

    @State private var selectedTagIds: Set<Int> = []
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""
    @State private var isLoaded = false

    init(transactionId: Int, allTags: [Tag], repository: TransactionRepository, onNewTag: @escaping (Tag) -> Void) {
        self.transactionId = transactionId
        self.allTags = allTags
        self.repository = repository
        self.onNewTag = onNewTag
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
                            Button { toggle(tag.id) } label: {
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
            .onAppear {
                guard !isLoaded else { return }
                selectedTagIds = Set(repository.fetchTags(forTransaction: transactionId).map(\.id))
                isLoaded = true
            }
            .paneChrome("Tags",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark", onConfirm: { save() })
    }

    private func toggle(_ tagId: Int) {
        if selectedTagIds.contains(tagId) { selectedTagIds.remove(tagId) }
        else { selectedTagIds.insert(tagId) }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            let tag = Tag(id: id, name: name)
            selectedTagIds.insert(id)
            if !localAllTags.contains(where: { $0.id == id }) {
                localAllTags.append(tag)
                localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onNewTag(tag)
            }
        }
        newTagName = ""
    }

    private func save() {
        repository.setTags(Array(selectedTagIds), forTransaction: transactionId)
        dismiss()
    }
}
