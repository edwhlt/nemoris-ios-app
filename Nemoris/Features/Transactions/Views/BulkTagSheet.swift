import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct BulkTagSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let initialStates: [Int: TagSelectionState]
    let repository: TransactionRepository
    let onSave: ([Int: TagSelectionState]) -> Void
    let onNewTag: (Tag) -> Void

    @State private var states: [Int: TagSelectionState]
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""

    init(allTags: [Tag], initialStates: [Int: TagSelectionState], repository: TransactionRepository,
         onSave: @escaping ([Int: TagSelectionState]) -> Void, onNewTag: @escaping (Tag) -> Void) {
        self.initialStates = initialStates
        self.repository = repository
        self.onSave = onSave
        self.onNewTag = onNewTag
        _states = State(initialValue: initialStates)
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

                Section("Tags") {
                    ForEach(localAllTags) { tag in
                        Button { toggleTag(tag) } label: {
                            HStack(spacing: 12) {
                                stateIcon(for: tag)
                                Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                if states[tag.id] == .some {
                                    Text("partiel")
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
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
            .paneChrome("Tags — sélection multiple",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Appliquer", confirmIcon: "checkmark") {
                onSave(states); dismiss()
            }
    }

    @ViewBuilder
    private func stateIcon(for tag: Tag) -> some View {
        switch states[tag.id] ?? .none {
        case .all:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tag.displayColor).font(.title3)
        case .some:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(AppTheme.Colors.textSecondary).font(.title3)
        case .none:
            Image(systemName: "circle")
                .foregroundStyle(AppTheme.Colors.textSecondary).font(.title3)
        }
    }

    private func toggleTag(_ tag: Tag) {
        states[tag.id, default: .none].toggle()
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            states[id] = .all
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
