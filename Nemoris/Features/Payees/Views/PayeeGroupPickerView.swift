import SwiftUI

/// Sheet de sélection d'un groupe de marque (`payee_groups`) pour un payee.
/// Permet aussi de créer un nouveau groupe à la volée.
///
/// utilisé depuis `PayeeDetailView`.
struct PayeeGroupPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let currentGroupId: Int?
    let onSelect: (PayeeGroup?) -> Void  // nil = "Aucun groupe"

    @State private var groups: [PayeeGroup] = []
    @State private var search: String = ""
    @State private var showCreateForm = false

    private let repository = TransactionRepository()

    private var filtered: [PayeeGroup] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let q = search.lowercased()
        return groups.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "minus.circle").foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("Aucun groupe").foregroundStyle(AppTheme.Colors.textPrimary)
                        Spacer()
                        if currentGroupId == nil {
                            Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                }

                if !filtered.isEmpty {
                    Section("Groupes existants") {
                        ForEach(filtered) { g in
                            Button {
                                onSelect(g)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: g.engineMerchantId == nil ? "person.crop.rectangle" : "building.2")
                                        .foregroundStyle(AppTheme.Colors.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(g.displayName).foregroundStyle(AppTheme.Colors.textPrimary)
                                        if let eid = g.engineMerchantId {
                                            Text(eid).font(.caption2.monospaced()).foregroundStyle(AppTheme.Colors.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if currentGroupId == g.id {
                                        Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un groupe…")
            .navigationTitle("Groupe de marque")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateForm = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateForm) {
                CreatePayeeGroupSheet(prefilledName: search.trimmingCharacters(in: .whitespaces)) { name in
                    if let id = repository.addPayeeGroup(displayName: name) {
                        let created = PayeeGroup(id: id, displayName: name, engineMerchantId: nil, custom: true)
                        groups.append(created)
                        groups.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                        onSelect(created)
                        dismiss()
                    }
                }
            }
            .task { loadGroups() }
        }
    }

    private func loadGroups() {
        groups = repository.fetchPayeeGroups()
    }
}

private struct CreatePayeeGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prefilledName: String
    let onCreate: (String) -> Void

    @State private var name: String

    init(prefilledName: String, onCreate: @escaping (String) -> Void) {
        self.prefilledName = prefilledName
        self.onCreate = onCreate
        _name = State(initialValue: prefilledName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ex. : Carrefour", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Rassemble plusieurs tiers de la même enseigne (ex. tous les Carrefour Market).")
                }
            }
            .nemorisFormStyle()
            .navigationTitle("Nouveau groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
