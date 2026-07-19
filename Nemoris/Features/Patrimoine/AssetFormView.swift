import SwiftUI

// MARK: - AssetFormView
//
// Sheet de création/édition d'un asset Patrimoine (Mobilier & Liquidités).
//
// 2 modes mutuellement exclusifs :
//   • **Standalone** : l'user saisit une valeur manuelle. Champ éditable, figé
//     tant que l'user ne le met pas à jour.
//   • **Linked** : l'user choisit un compte source (Account ou InvestmentAccount)
//     via `AccountLinkPickerSheet`. La valeur affichée devient lecture seule —
//     elle sera résolue dynamiquement à chaque ouverture de la PatrimoineView.
//
// Validation côté form :
//   - Nom obligatoire (non vide après trim)
//   - Si linked → on vérifie que le compte source n'est pas déjà pris par un
//     autre asset (le VM remonte un échec → toast).
//
// L'édition utilise le même form (passe `existingAsset` non-nil). Bouton
// "Supprimer" affiché en bas dans ce cas.

struct AssetFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel
    /// Nil = création, sinon édition.
    let existingAsset: PatrimoineAsset?

    // ── Champs du draft ───────────────────────────────────────────
    @State private var name: String
    @State private var kind: AssetKind
    @State private var linkSelection: LinkSelection
    @State private var manualValueText: String
    @State private var notes: String

    // ── UI state ──────────────────────────────────────────────────
    @State private var showLinkPicker = false
    @State private var showDeleteConfirm = false
    @FocusState private var valueFieldFocused: Bool

    // MARK: - Init (préremplissage du draft)

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

    /// Valeur live à afficher en preview quand un compte est lié. Recalcule à chaque
    /// build — c'est local au form, le coût est négligeable.
    private var linkedLiveValue: Double {
        switch linkSelection {
        case .none: return 0
        case .bank(let id): return viewModel.liveValue(forBankAccountId: id)
        case .investment(let id): return viewModel.liveValue(forInvestmentAccountId: id)
        }
    }

    /// Libellé du compte sélectionné (ex : "Livret A perso"). Vide si .none.
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

    /// Vrai si on édite un asset dont le compte source a été supprimé. Source de
    /// vérité : le set `brokenLinkAssetIds` du VM (recalculé à chaque load).
    private var isEditingBrokenLink: Bool {
        guard let id = existingAsset?.id else { return false }
        return viewModel.brokenLinkAssetIds.contains(id)
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Bannière lien rompu (édition d'un asset orphelin) ────
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

                // ── Identité ────────────────────────────────────────
                Section("Identité") {
                    TextField("Nom (ex. Livret A perso)", text: $name)
                        .autocorrectionDisabled()

                    Picker("Catégorie", selection: $kind) {
                        ForEach(AssetKind.allCases, id: \.self) { k in
                            Label(k.label, systemImage: k.systemIcon).tag(k)
                        }
                    }
                }

                // ── Source de la valeur ─────────────────────────────
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
                        // Valeur résolue affichée en lecture seule.
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
                            TextField("0,00", text: $manualValueText)
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

                // ── Suppression (édition uniquement) ────────────────
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
            .navigationTitle(existingAsset == nil ? "Nouvel actif" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showLinkPicker) {
                AccountLinkPickerSheet(
                    viewModel: viewModel,
                    currentSelection: linkSelection,
                    excludingAssetId: existingAsset?.id
                ) { newSelection in
                    linkSelection = newSelection
                    // Si on bascule en .none, on remet manualValueText à 0 (vide pour
                    // forcer l'user à taper sa valeur).
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
        }
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
            // Si l'asset passe en linked, on garde la manualValue précédente comme
            // valeur de secours (utile si l'user re-bascule en standalone plus tard).
            // En .none, on prend la valeur saisie.
            if !isLinked {
                updated.manualValue = manualValueParsed
            }
            updated.notes = notesValue
            success = viewModel.updateAsset(updated)
        } else {
            // Create — pour un linked, manualValue stocke la valeur actuelle lue
            // comme "valeur de bascule possible" si l'user désactive le lien plus tard.
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
            // Échec = très probablement un conflit UNIQUE INDEX (compte déjà lié à
            // un autre asset). Le VM a déjà logué l'erreur. On post un toast user.
            appState.postToast(
                .error,
                "Impossible d'enregistrer. Ce compte est peut-être déjà lié à un autre élément Patrimoine."
            )
        }
    }
}
