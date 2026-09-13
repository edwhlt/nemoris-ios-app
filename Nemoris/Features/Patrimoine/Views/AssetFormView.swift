import SwiftUI

// MARK: - AssetFormView
//
// A sheet for creating/editing a Patrimoine asset (Movable Assets & Cash).
//
// 2 mutually exclusive modes:
//   • **Standalone**: the user enters a manual value. An editable field, fixed
//     until the user updates it.
//   • **Linked**: the user picks a source account (Account or InvestmentAccount)
//     via `AccountLinkPickerSheet`. The displayed value becomes read-only —
//     it will be resolved dynamically every time PatrimoineView opens.
//
// Form-side validation:
//   - The name is required (non-empty after trimming)
//   - If linked → checks that the source account isn't already taken by
//     another asset (the VM surfaces a failure → a toast).
//
// Editing uses the same form (passing a non-nil `existingAsset`). A "Delete"
// button is shown at the bottom in that case.

struct AssetFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel
    /// Nil = creation, otherwise editing.
    let existingAsset: PatrimoineAsset?

    // ── Draft fields ───────────────────────────────────────────
    @State private var name: String
    @State private var kind: AssetKind
    @State private var linkSelection: LinkSelection
    @State private var manualValueText: String
    @State private var notes: String

    // ── UI state ──────────────────────────────────────────────────
    @State private var showLinkPicker = false
    @State private var showDeleteConfirm = false
    @FocusState private var valueFieldFocused: Bool

    // MARK: - Init (pre-filling the draft)

    init(viewModel: PatrimoineViewModel, existingAsset: PatrimoineAsset? = nil) {
        self.viewModel = viewModel
        self.existingAsset = existingAsset

        let initialName = existingAsset?.name ?? ""
        let initialKind = existingAsset?.assetKind ?? .savings
        let initialLink: LinkSelection = {
            if let bankId = existingAsset?.linkedAccountId { return .bank(bankId) }
            if let invId = existingAsset?.linkedInvestmentAccountId { return .investment(invId) }
            return .none
        }()
        let initialManualValue = existingAsset?.manualValue ?? 0
        let initialNotes = existingAsset?.notes ?? ""

        _name = State(initialValue: initialName)
        _kind = State(initialValue: initialKind)
        _linkSelection = State(initialValue: initialLink)
        _manualValueText = State(initialValue: initialManualValue == 0
                                  ? ""
                                  : String(format: "%.2f", initialManualValue))
        _notes = State(initialValue: initialNotes)
    }

    // MARK: - Computed

    private var isLinked: Bool {
        if case .none = linkSelection { return false }
        return true
    }

    /// The live value to show in the preview when an account is linked. Recomputed on every
    /// build — it's local to the form, the cost is negligible.
    private var linkedLiveValue: Double {
        switch linkSelection {
        case .none: return 0
        case .bank(let id): return viewModel.liveValue(forBankAccountId: id)
        case .investment(let id): return viewModel.liveValue(forInvestmentAccountId: id)
        }
    }

    /// The selected account's label (e.g. "My savings account"). Empty if .none.
    private var linkedAccountName: String {
        switch linkSelection {
        case .none: return ""
        case .bank(let id):
            return viewModel.availableBankAccounts.first(where: { $0.id == id })?.name ?? "Compte"
        case .investment(let id):
            return viewModel.availableInvestmentAccounts.first(where: { $0.id == id })?.name ?? "Compte"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var manualValueParsed: Double {
        Double(manualValueText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: - Body

    /// True when editing an asset whose source account was deleted. The source of
    /// truth: the VM's `brokenLinkAssetIds` set (recomputed on every load).
    private var isEditingBrokenLink: Bool {
        guard let id = existingAsset?.id else { return false }
        return viewModel.brokenLinkAssetIds.contains(id)
    }

    var body: some View {
            Form {
                // ── Broken-link banner (editing an orphaned asset) ────
                if isEditingBrokenLink {
                    Section {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppTheme.Colors.warning)
                                Text("Lien rompu")
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                            }
                            Text("Le compte source de cet actif a été supprimé. La dernière valeur connue est conservée. Vous pouvez le relier à un autre compte ou repasser en saisie manuelle.")
                                .font(AppTheme.Typography.bodySmall)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Button {
                                    showLinkPicker = true
                                } label: {
                                    Label("Relier", systemImage: "link")
                                        .font(AppTheme.Typography.labelLarge)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, AppTheme.Spacing.md)
                                        .padding(.vertical, 8)
                                        .background(AppTheme.Colors.accent, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(AppTheme.Colors.warning.opacity(0.08))
                }

                // ── Identity ────────────────────────────────────────
                Section("Identité") {
                    TextField("Nom (ex. Livret A perso)", text: $name)
                        .autocorrectionDisabled()

                    Picker("Catégorie", selection: $kind) {
                        ForEach(AssetKind.allCases, id: \.self) { k in
                            Label(LocalizedStringKey(k.label), systemImage: k.systemIcon).tag(k)
                        }
                    }
                }

                // ── Source of the value ─────────────────────────────
                Section {
                    Button {
                        showLinkPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Source")
                                    .font(AppTheme.Typography.labelLarge)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                Text(isLinked ? "Lié à \(linkedAccountName)" : "Saisie manuelle")
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if isLinked {
                        // The resolved value shown read-only.
                        HStack {
                            Text("Valeur lue")
                                .font(AppTheme.Typography.bodyMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Spacer()
                            Text(linkedLiveValue, format: .currency(code: "EUR").presentation(.narrow))
                                .font(AppTheme.Typography.titleSmall)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                        }
                    } else {
                        // Champ saisie manuelle.
                        HStack {
                            Text("Valeur")
                                .font(AppTheme.Typography.bodyMedium)
                            Spacer()
                            // An empty title: the row already has its label ("Value")
                            // — see TransactionEditSheet for the macOS reason.
                            TextField("", text: $manualValueText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($valueFieldFocused)
                                .frame(maxWidth: 150)
                        }
                    }
                } header: {
                    Text("Source de la valeur")
                } footer: {
                    if isLinked {
                        Text("La valeur est mise à jour automatiquement à chaque ouverture depuis le compte lié.")
                            .font(AppTheme.Typography.bodySmall)
                    } else {
                        Text("Vous devrez mettre à jour la valeur manuellement.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Notes ───────────────────────────────────────────
                Section("Note") {
                    TextField("Note libre", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                // ── Deletion (editing only) ────────────────────────
                if existingAsset != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Supprimer cet élément")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .adaptivePane(isPresented: $showLinkPicker) {
                AccountLinkPickerSheet(
                    viewModel: viewModel,
                    currentSelection: linkSelection,
                    excludingAssetId: existingAsset?.id
                ) { newSelection in
                    linkSelection = newSelection
                    // If switching to .none, manualValueText is reset to 0 (empty, to
                    // force the user to type their own value).
                    if newSelection == .none, existingAsset == nil {
                        manualValueText = ""
                    }
                }
            }
            .confirmationDialog(
                "Supprimer cet élément du patrimoine ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    if let id = existingAsset?.id {
                        viewModel.deleteAsset(id: id)
                        dismiss()
                    }
                }
            } message: {
                Text("Cette action ne supprime pas le compte source lié, uniquement la fiche Patrimoine.")
            }
            .paneChrome(existingAsset == nil ? "Nouvel actif" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark", confirmDisabled: !canSave,
                        onConfirm: { save() })
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let notesValue: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        let bankId: Int? = {
            if case let .bank(id) = linkSelection { return id }
            return nil
        }()
        let investmentId: Int? = {
            if case let .investment(id) = linkSelection { return id }
            return nil
        }()

        let success: Bool
        if let existing = existingAsset {
            // Update
            var updated = existing
            updated.name = trimmedName
            updated.assetKind = kind
            updated.linkedAccountId = bankId
            updated.linkedInvestmentAccountId = investmentId
            // If the asset switches to linked, the previous manualValue is kept as a
            // fallback value (useful if the user switches back to standalone later).
            // In .none, the entered value is used.
            if !isLinked {
                updated.manualValue = manualValueParsed
            }
            updated.notes = notesValue
            success = viewModel.updateAsset(updated)
        } else {
            // Create — for a linked asset, manualValue stores the currently read
            // value as a "possible fallback value" if the user disables the link later.
            let manualForCreate = isLinked ? linkedLiveValue : manualValueParsed
            success = viewModel.createAsset(
                name: trimmedName,
                kind: kind,
                linkedAccountId: bankId,
                linkedInvestmentAccountId: investmentId,
                manualValue: manualForCreate,
                notes: notesValue
            )
        }

        if success {
            dismiss()
        } else {
            // A failure = most likely a UNIQUE INDEX conflict (the account is already
            // linked to another asset). The VM already logged the error. A toast is posted.
            appState.postToast(
                .error,
                "Impossible d'enregistrer. Ce compte est peut-être déjà lié à un autre élément Patrimoine."
            )
        }
    }
}
