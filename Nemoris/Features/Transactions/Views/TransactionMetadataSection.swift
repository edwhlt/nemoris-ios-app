import SwiftUI

/// "Metadata" section of a transaction sheet — replaces the
/// "payment method" picker.
///
/// ─── What changes, and why ──────────────────────────────────────────────
///
/// `transactions.payment_type_id` was the only free-form attribute a
/// transaction could carry outside of payee/category/tags, and it imposed its own
/// semantics on everyone. It becomes one metadata field among others, defined by
/// the user: "Project", "Work / Personal", "Joint account"… or nothing
/// at all.
///
/// ⚠️ A FRESH database has NO key at all. This section then shows an
/// invitation to create one, not an empty field — otherwise it would look like a
/// broken feature.
struct TransactionMetadataSection: View {

    /// `nil` as long as the transaction doesn't exist in the database yet (creation): a
    /// value can't be attached to a row that has no id.
    let transactionId: Int?

    @State private var keys: [TransactionMetadataKey] = []
    @State private var values: [Int: String] = [:]        // keyId → valeur
    @State private var suggestions: [Int: [String]] = [:] // keyId → values already seen
    @State private var showKeyManager = false
    /// Pending debounced writes, one per key (see `commit`).
    @State private var pendingWrites: [Int: Task<Void, Never>] = [:]

    private let repository = TransactionMetadataRepository()

    var body: some View {
        Section {
            if keys.isEmpty {
                emptyState
            } else {
                ForEach(keys) { key in
                    metadataRow(key)
                }
            }
            Button {
                showKeyManager = true
            } label: {
                Label(keys.isEmpty ? "Créer une métadonnée" : "Gérer les métadonnées",
                      systemImage: keys.isEmpty ? "plus.circle" : "slider.horizontal.3")
                    .font(.callout)
            }
        } header: {
            Text("Métadonnées")
        } footer: {
            if transactionId == nil {
                Text("Enregistre d'abord la transaction pour lui poser des métadonnées.")
            } else if !keys.isEmpty {
                Text("Texte libre. Laisse un champ vide pour retirer la métadonnée de cette transaction.")
            }
        }
        .adaptivePane(isPresented: $showKeyManager) {
            MetadataKeyManagerView(onChange: load)
        }
        .task { load() }
        .onDisappear { flushPendingWrites() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Aucune métadonnée définie")
                .font(.subheadline.weight(.medium))
            Text("Les métadonnées sont des étiquettes que tu définis toi-même — « Projet », « Pro / Perso », « Mode de paiement »… — pour classer tes transactions comme tu l'entends.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func metadataRow(_ key: TransactionMetadataKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(key.name, systemImage: key.displayIcon)
                    .font(.subheadline)
                Spacer()
                TextField("Valeur", text: Binding(
                    get: { values[key.id] ?? "" },
                    set: { newValue in
                        values[key.id] = newValue
                        commit(key: key, value: newValue)
                    }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(transactionId == nil)
            }

            // Suggestions: what has ALREADY been typed for this key, most
            // frequent first.
            //
            // ⚠️ Suggestions only — no constraint in the database. Locking them into a
            // closed list would recreate a reference table, exactly what was
            // just removed.
            let proposals = (suggestions[key.id] ?? []).filter { $0 != (values[key.id] ?? "") }
            if !proposals.isEmpty, transactionId != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(proposals.prefix(6), id: \.self) { proposal in
                            Button {
                                values[key.id] = proposal
                                commit(key: key, value: proposal)
                            } label: {
                                Text(proposal)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private func load() {
        keys = repository.fetchKeys()
        suggestions = Dictionary(uniqueKeysWithValues: keys.map {
            ($0.id, repository.distinctValues(keyId: $0.id))
        })
        guard let transactionId else { values = [:]; return }
        values = Dictionary(uniqueKeysWithValues:
            repository.fetchValues(transactionId: transactionId).map { ($0.keyId, $0.value) })
    }

    /// A write with no "save" button, but DEBOUNCED.
    ///
    /// Consistent with tags, which also apply on the fly: a
    /// metadata field is a label, not a field of the main form. An
    /// emptied value removes the row (see `setValue`).
    ///
    /// ⚠️ The delay isn't a convenience. The initial version wrote to the database on
    /// EVERY KEYSTROKE: an SQLite connection opened and an UPSERT run per
    /// character, on the main actor — guaranteed choppy typing. Only the
    /// last keystroke of a burst is kept.
    private func commit(key: TransactionMetadataKey, value: String) {
        guard let transactionId else { return }
        pendingWrites[key.id]?.cancel()
        pendingWrites[key.id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            repository.setValue(value, keyId: key.id, transactionId: transactionId)
        }
    }

    /// Flushes the write queue: the last keystroke shouldn't be lost
    /// because the user closed the sheet right after.
    private func flushPendingWrites() {
        guard let transactionId else { return }
        for (keyId, task) in pendingWrites {
            task.cancel()
            repository.setValue(values[keyId] ?? "", keyId: keyId, transactionId: transactionId)
        }
        pendingWrites = [:]
    }
}

/// Creating, renaming and deleting metadata keys.
///
/// Deliberately separate from `ReferenceDataView`: this is a lightweight
/// reference table, created on the fly from the transaction sheet, whereas
/// categories and payees are managed in bulk.
struct MetadataKeyManagerView: View {
    @Environment(\.paneDismiss) private var dismiss
    var onChange: () -> Void = {}

    @State private var keys: [TransactionMetadataKey] = []
    @State private var newName = ""
    @State private var newIcon = "tag"
    @State private var fillsFromImport = false
    @State private var errorMessage: String?

    // In-place editing of an existing key.
    @State private var editingKeyId: Int?
    @State private var editName = ""
    @State private var editIcon = "tag"
    @State private var editFillsFromImport = false
    /// ⚠️ Confirmation before deletion: the CASCADE wipes EVERY value
    /// set on transactions. An accidental tap shouldn't lose them.
    @State private var deleteTarget: TransactionMetadataKey?

    private let repository = TransactionMetadataRepository()

    /// A few common symbols — typing an SF Symbol name by hand makes
    /// no sense for a user.
    private let iconChoices = ["tag", "creditcard", "briefcase", "folder", "person.2",
                               "building.2", "airplane", "car", "house", "star"]

    var body: some View {
        Form {
            Section {
                ForEach(keys) { key in
                    // A key can be EDITED: renamed, its icon changed, its
                    // "filled in by import" role moved. The first version
                    // could only create and delete, which forced
                    // destroying every value to fix a
                    // typo in a name.
                    if editingKeyId == key.id {
                        editor(for: key)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: key.displayIcon)
                                .foregroundStyle(AppTheme.Colors.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                if let role = key.role {
                                    Text(LocalizedStringKey(role.displayName))
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                            Spacer()
                            Button {
                                beginEditing(key)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.accent)
                            Button(role: .destructive) {
                                deleteTarget = key
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.danger)
                        }
                    }
                }
                if keys.isEmpty {
                    Text("Aucune métadonnée pour l'instant.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Métadonnées existantes")
            } footer: {
                // ⚠️ The CASCADE is real: say so before, not after.
                Text("Supprimer une métadonnée efface aussi toutes les valeurs posées sur les transactions.")
            }

            Section {
                TextField("Nom (ex. Projet, Pro / Perso)", text: $newName)
                Picker("Icône", selection: $newIcon) {
                    ForEach(iconChoices, id: \.self) { icon in
                        Label(icon, systemImage: icon).tag(icon)
                    }
                }
                Toggle("Renseignée par l'import", isOn: $fillsFromImport)
                Button {
                    create()
                } label: {
                    Label("Créer", systemImage: "plus.circle.fill")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                }
            } header: {
                Text("Nouvelle métadonnée")
            } footer: {
                Text("« Renseignée par l'import » fait remplir cette métadonnée automatiquement avec le moyen de paiement déduit du libellé bancaire (CB, virement, prélèvement…). Une seule métadonnée peut jouer ce rôle.")
            }
        }
        .nemorisFormStyle()
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        // Convention: any view presented in a pane sets its own tint.
        .tint(AppTheme.Colors.accent)
        .paneChrome("Métadonnées", cancelLabel: "Fermer", onCancel: { dismiss() })
        .confirmationDialog("Supprimer « \(deleteTarget?.name ?? "") » ?",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let target = deleteTarget { repository.deleteKey(id: target.id) }
                deleteTarget = nil
                reload()
            }
            Button("Annuler", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Toutes les valeurs posées sur tes transactions pour cette métadonnée seront effacées.")
        }
        .task { reload() }
    }

    /// In-place editing of a key, right in the row itself.
    @ViewBuilder
    private func editor(for key: TransactionMetadataKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nom", text: $editName)
            Picker("Icône", selection: $editIcon) {
                ForEach(iconChoices, id: \.self) { icon in
                    Label(icon, systemImage: icon).tag(icon)
                }
            }
            Toggle("Renseignée par l'import", isOn: $editFillsFromImport)
            HStack {
                Button("Annuler") { editingKeyId = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Button("Enregistrer") { saveEdit(key) }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func beginEditing(_ key: TransactionMetadataKey) {
        editingKeyId = key.id
        editName = key.name
        editIcon = key.displayIcon
        editFillsFromImport = key.role == .paymentMethod
    }

    private func saveEdit(_ key: TransactionMetadataKey) {
        var updated = key
        updated.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.icon = editIcon
        // Setting the role here automatically REMOVES it from the key that
        // held it (a partial UNIQUE index managed by the repository): it stays
        // exclusive.
        updated.role = editFillsFromImport ? .paymentMethod : nil
        guard repository.updateKey(updated) else {
            errorMessage = "Ce nom est déjà utilisé."
            return
        }
        editingKeyId = nil
        errorMessage = nil
        reload()
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.addKey(name: trimmed, icon: newIcon,
                                role: fillsFromImport ? .paymentMethod : nil) != nil else {
            errorMessage = "Ce nom est déjà utilisé."
            return
        }
        newName = ""
        fillsFromImport = false
        errorMessage = nil
        reload()
    }

    private func reload() {
        keys = repository.fetchKeys()
        onChange()
    }
}

/// Creating AND editing a key — a single form for both, like
/// `PayeeDetailView` (`key: nil` = creation). Used by the Data screen's
/// "Metadata" tab (`ReferenceDataView`), via the toolbar "+"
/// button (creation) and the detail pane (editing) — the same
/// swipeable/inspector flow as Accounts/Payees/Tags. Distinct from
/// `MetadataKeyManagerView` above, which stays the quick-creation
/// shortcut FROM the transaction sheet (don't merge them: different contexts).
struct MetadataKeyFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    /// `nil` = a new key.
    let key: TransactionMetadataKey?
    var onSave: () -> Void = {}

    @State private var name: String
    @State private var icon: String
    @State private var fillsFromImport: Bool
    @State private var errorMessage: String?

    private let repository = TransactionMetadataRepository()

    /// Same symbols as `MetadataKeyManagerView` — typing an SF
    /// Symbol name by hand makes no sense for a user.
    private let iconChoices = ["tag", "creditcard", "briefcase", "folder", "person.2",
                               "building.2", "airplane", "car", "house", "star"]

    init(key: TransactionMetadataKey?, onSave: @escaping () -> Void = {}) {
        self.key = key
        self.onSave = onSave
        _name = State(initialValue: key?.name ?? "")
        _icon = State(initialValue: key?.displayIcon ?? "tag")
        _fillsFromImport = State(initialValue: key?.role == .paymentMethod)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nom (ex. Projet, Pro / Perso)", text: $name)
                Picker("Icône", selection: $icon) {
                    ForEach(iconChoices, id: \.self) { i in
                        Label(i, systemImage: i).tag(i)
                    }
                }
                Toggle("Renseignée par l'import", isOn: $fillsFromImport)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                }
            } footer: {
                Text("« Renseignée par l'import » fait remplir cette métadonnée automatiquement avec le moyen de paiement déduit du libellé bancaire (CB, virement, prélèvement…). Une seule métadonnée peut jouer ce rôle.")
            }
        }
        .nemorisFormStyle()
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        // Convention: any view presented in a pane sets its own tint.
        .tint(AppTheme.Colors.accent)
        .paneChrome(
            key == nil ? "Nouvelle métadonnée" : "Renommer",
            cancelLabel: "Annuler", onCancel: { dismiss() },
            confirmLabel: key == nil ? "Créer" : "Enregistrer",
            confirmIcon: key == nil ? "plus" : "checkmark",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            onConfirm: save
        )
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let role: MetadataKeyRole? = fillsFromImport ? .paymentMethod : nil
        if var existing = key {
            existing.name = trimmed
            existing.icon = icon
            existing.role = role
            guard repository.updateKey(existing) else {
                errorMessage = "Ce nom est déjà utilisé."
                return
            }
        } else {
            guard repository.addKey(name: trimmed, icon: icon, role: role) != nil else {
                errorMessage = "Ce nom est déjà utilisé."
                return
            }
        }
        onSave()
        dismiss()
    }
}

/// Read-only detail of a key (Close / Delete / Edit) — the
/// `detail:` of `adaptiveEntityPane` in `ReferenceDataView`. Same template
/// as `PayeeDetailPane`/`ReferenceDetailPane`.
struct MetadataKeyDetailPane: View {
    let key: TransactionMetadataKey
    let usageCount: Int

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: key.displayIcon)
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                    Text(key.name).font(AppTheme.Typography.bodyMedium)
                }
            }
            Section("Détails") {
                if let role = key.role {
                    LabeledContent("Rôle", value: role.displayName)
                }
                LabeledContent("Transactions", value: "\(usageCount)")
                LabeledContent("Identifiant", value: "#\(key.id)")
            }
        }
        .nemorisFormStyle()
    }
}
