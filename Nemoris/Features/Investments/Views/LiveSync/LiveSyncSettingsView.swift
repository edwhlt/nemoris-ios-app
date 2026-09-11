import SwiftUI

// MARK: - Live sync link management, within the Investments module
//
// 3 levels:
//   1. LiveSyncProviderPickerView: catalog of available providers
//   2. LiveSyncLinkFormView: credentials + config form (generated dynamically)
//   3. LiveSyncLinkDetailView: detail of ONE link (status, sync, edit, delete)
//
// Entry points (2, both open `LiveSyncProviderPickerView`):
//   - `InvestmentsView` (module toolbar, "Link an exchange / wallet") — no
//     pre-existing account: `accountId: nil`, a dedicated account is created
//     on the fly by `LiveSyncLinkFormView.save()`.
//   - `InvestmentAccountFormView` ("Edit account" sheet, "Sync" section) —
//     `accountId: account.id`, the new link is attached directly to THAT
//     account.
//
// There is no global list of links independent of an account: every link is
// ALWAYS visible and manageable from the sheet of the account it's attached
// to (see `InvestmentAccountFormView.linkedSourcesSection`).

// MARK: - Provider picker (catalogue)

struct LiveSyncProviderPickerView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    /// Account to attach the new link to. `nil` = created from the module's
    /// catalog (no pre-existing account): `LiveSyncLinkFormView` then creates a
    /// dedicated account on the fly. Non-nil = created from an existing
    /// account's sheet, the link is attached to it directly.
    var accountId: Int? = nil
    /// State instead of a `NavigationLink`: a push from this content, once hosted
    /// in the macOS pane, would lift the credentials form's title/back button
    /// into the MODULE's bar. A level-2 sheet instead.
    @State private var selectedProviderType: InvestmentLiveSyncProvider.Type?

    var body: some View {
        Form {
            Section {
                Text("Choisissez la source à lier. Vous serez ensuite invité à saisir les identifiants (clé API ou adresse publique).")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(LiveSyncRegistry.availableProviders) { entry in
                    Button {
                        selectedProviderType = entry.providerType
                    } label: {
                        HStack {
                            providerRow(entry)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .adaptivePane(isPresented: Binding(
            get: { selectedProviderType != nil },
            set: { if !$0 { selectedProviderType = nil } }
        )) {
            if let providerType = selectedProviderType {
                LiveSyncLinkFormView(providerType: providerType, existingLink: nil, accountId: accountId)
            }
        }
        .paneChrome("Ajouter une source", cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    private func providerRow(_ entry: LiveSyncProviderEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: entry.iconName)
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Credentials form (creation/edit)

struct LiveSyncLinkFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let providerType: InvestmentLiveSyncProvider.Type
    let existingLink: InvestmentLiveSyncLink?
    /// Target account for a NEW link. Ignored when editing (`existingLink`
    /// already carries its own `accountId`, never reassigned here). `nil` on
    /// creation = no account supplied by the caller → `save()` creates one.
    var accountId: Int? = nil

    @State private var displayName: String = ""
    @State private var credentials: [String: String] = [:]
    @State private var selectedChain: String = ""
    @State private var saveError: String?
    /// True during `save()` (persistence + first sync). Without this guard, a
    /// link would be created even with invalid credentials (e.g. a missing
    /// Etherscan key) with no signal before the first "Sync now" — a user seeing
    /// nothing happen on "Save" could retry and create a local duplicate.
    @State private var isSaving = false

    private var isEditing: Bool { existingLink != nil }

    private var canSave: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        for field in providerType.credentialFields {
            let val = credentials[field.key] ?? ""
            // .anyString = optional field (may be empty) → skip the check
            if case .anyString = field.validation { continue }
            // Empty or invalid → blocked
            if val.isEmpty || !field.isValid(val) { return false }
        }
        if providerType.supportsChainSelection && selectedChain.isEmpty { return false }
        return true
    }

    var body: some View {
        // Background via .background (bounded by the Form), not a greedy ZStack +
        // Color: the latter stretches the window infinitely on macOS.
        Form {
                Section("Nom d'affichage") {
                    TextField("Ex: \(suggestedName)", text: $displayName)
                }

                if providerType.supportsChainSelection {
                    Section("Chaîne") {
                        Picker("Chaîne", selection: $selectedChain) {
                            ForEach(providerType.supportedChains) { chain in
                                Label(LocalizedStringKey(chain.displayName), systemImage: chain.icon).tag(chain.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Identifiants") {
                    ForEach(providerType.credentialFields) { field in
                        credentialField(field)
                    }
                }

                if isSaving {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Enregistrement et première synchronisation…")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }

                Section {
                    Text("⚠️ Avant de sauvegarder, vérifiez bien que vos clés API sont **read-only**. Les permissions d'écriture (trading, withdraw) ne sont JAMAIS nécessaires pour la synchronisation Nemoris.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .nemorisFormStyle()
            .background(AppTheme.Colors.background.ignoresSafeArea())
        .onAppear { populate() }
        .paneChrome(isEditing ? "Modifier la source" : providerType.displayName,
                    cancelLabel: "Annuler", onCancel: { dismiss() },
                    confirmLabel: isEditing ? "Mettre à jour" : "Enregistrer", confirmIcon: "checkmark",
                    confirmDisabled: !canSave || isSaving,
                    onConfirm: { Task { await save() } })
    }

    // MARK: - Field renderer (dynamique selon LiveSyncCredentialField)

    @ViewBuilder
    private func credentialField(_ field: LiveSyncCredentialField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.isSecret {
                SecureField(field.label, text: bindingFor(field.key), prompt: Text(field.placeholder ?? field.label))
            } else {
                TextField(field.label, text: bindingFor(field.key), prompt: Text(field.placeholder ?? field.label))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if let help = field.helpText {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func bindingFor(_ key: String) -> Binding<String> {
        Binding(
            get: { credentials[key] ?? "" },
            set: { credentials[key] = $0 }
        )
    }

    // MARK: - Save / load

    private var suggestedName: String {
        switch providerType.id {
        case "binance":         return "Binance perso"
        case "evm_wallet":      return "MetaMask principal"
        case "bitcoin_wallet":  return "Ledger BTC"
        case "solana_wallet":   return "Phantom"
        default:                return providerType.displayName
        }
    }

    private func populate() {
        guard let link = existingLink else {
            // Default name suggestion (the user can overwrite it)
            displayName = suggestedName
            // Default chain = the first available one, if applicable
            if providerType.supportsChainSelection, let first = providerType.supportedChains.first {
                selectedChain = first.id
            }
            return
        }
        displayName = link.displayName
        if let chain = link.config["chain"] {
            selectedChain = chain
        }
        if let creds = InvestmentCredentialStore.shared.load(linkId: link.id, providerId: link.providerId) {
            credentials = creds
        }
    }

    private func save() async {
        saveError = nil
        // Trim every value before saving
        var cleanCreds: [String: String] = [:]
        for field in providerType.credentialFields {
            let raw = (credentials[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cleanCreds[field.key] = raw
        }

        var config: [String: String] = [:]
        if providerType.supportsChainSelection && !selectedChain.isEmpty {
            config["chain"] = selectedChain
        }

        isSaving = true
        defer { isSaving = false }

        let linkId: Int
        if let existing = existingLink {
            // UPDATE
            var updated = existing
            updated.displayName = displayName
            updated.configJSON = encodeConfig(config)
            guard LiveSyncRepository.shared.updateLink(updated) else {
                saveError = "Impossible de mettre à jour le lien."
                return
            }
            do {
                try InvestmentCredentialStore.shared.store(
                    linkId: existing.id, providerId: providerType.id, credentials: cleanCreds
                )
            } catch {
                saveError = "Erreur Keychain : \(error.localizedDescription)"
                return
            }
            linkId = existing.id
        } else {
            // CREATE — a target account is ALWAYS assigned at creation: the one
            // supplied by the caller (account sheet → "Link a source to this
            // account") or, failing that, a new dedicated account created right here
            // (module catalog → no pre-existing account). The account therefore exists
            // and appears in the Investments account list as soon as it's saved, even
            // if the sync that follows fails.
            let targetAccountId: Int
            if let accountId {
                targetAccountId = accountId
            } else {
                let accountName = LiveSyncRegistry.autoAccountName(
                    providerType: providerType, displayName: displayName, chain: config["chain"]
                )
                guard let newAccountId = InvestmentRepository().addAccountAndGetId(
                    name: accountName,
                    broker: providerType.displayName,
                    currency: "EUR",
                    accountType: LiveSyncRegistry.accountTypeForProvider(providerType.id),
                    openedAt: Date()
                ) else {
                    saveError = "Impossible de créer le compte cible."
                    return
                }
                targetAccountId = newAccountId
            }

            guard let newId = LiveSyncRepository.shared.addLink(
                providerId: providerType.id,
                displayName: displayName,
                accountId: targetAccountId,
                config: config
            ) else {
                saveError = "Impossible de créer le lien en base."
                return
            }
            do {
                try InvestmentCredentialStore.shared.store(
                    linkId: newId, providerId: providerType.id, credentials: cleanCreds
                )
            } catch {
                // Rollback: delete the created link, since the credentials couldn't be stored
                LiveSyncRepository.shared.deleteLink(id: newId)
                saveError = "Erreur Keychain : \(error.localizedDescription)"
                return
            }
            linkId = newId
        }

        // Immediate first sync (creation AND edit): the account already exists at
        // this point, so even a network failure here leaves a link fully visible
        // and manageable from the account sheet rather than a silent "pending"
        // state. Best-effort: reported through a toast, but it never blocks closing
        // the form (the credentials themselves are already persisted).
        if let freshLink = LiveSyncRepository.shared.fetchLink(id: linkId) {
            if let syncError = await LiveSyncRegistry.shared.syncLink(freshLink) {
                appState.postToast(.error, "« \(displayName) » enregistré, mais la sync a échoué : \(syncError)")
            } else {
                appState.postToast(.success, "« \(displayName) » synchronisé")
            }
            NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
        }
        dismiss()
    }

    private func encodeConfig(_ dict: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Detail view (status / sync / edit / delete)

struct LiveSyncLinkDetailView: View {
    let link: InvestmentLiveSyncLink
    let onChange: () -> Void

    // paneDismiss: uniform closing for the iOS sheet / macOS pane — this view is
    // ALWAYS presented via `.adaptivePane` (never pushed by NavigationLink), so
    // it's the only relevant closing mechanism here.
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    @State private var showDeleteConfirm = false
    /// Instead of a `NavigationLink` to the credentials form: an internal push
    /// from this view, once hosted in the macOS pane (no local `NavigationStack`
    /// in that case), would have no navigation context to push into.
    /// `.adaptivePane` works in both contexts.
    @State private var showEditForm = false
    @State private var enabledLocal: Bool
    @State private var isSyncing = false
    @State private var lastSyncFeedback: String?
    @State private var liveLink: InvestmentLiveSyncLink

    init(link: InvestmentLiveSyncLink, onChange: @escaping () -> Void) {
        self.link = link
        self.onChange = onChange
        _enabledLocal = State(initialValue: link.enabled)
        _liveLink = State(initialValue: link)
    }

    var body: some View {
        let providerType = LiveSyncRegistry.provider(for: link.providerId)

        Form {
            Section {
                Toggle("Activé", isOn: $enabledLocal)
                    .onChange(of: enabledLocal) { _, newValue in
                        var updated = link
                        updated.enabled = newValue
                        LiveSyncRepository.shared.updateLink(updated)
                        onChange()
                    }
            }
            .listRowBackground(AppTheme.Colors.surface)

            Section("Source") {
                HStack {
                    Text("Type")
                    Spacer()
                    Text(providerType?.displayName ?? liveLink.providerId)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                if let chain = liveLink.config["chain"] {
                    HStack {
                        Text("Chaîne")
                        Spacer()
                        Text(chain.capitalized)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                if let lastSync = liveLink.lastSyncAt {
                    HStack {
                        Text("Dernière sync")
                        Spacer()
                        Text(lastSync, format: .dateTime.day().month().year().hour().minute())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                // `LocalizedStringResource` has no `.isEmpty` — not needed anyway:
                // `persistPositions`/`persistTransactions` return `nil` (not `""`) when
                // there is nothing to say.
                if let message = liveLink.lastSyncMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Statut")
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(
                                liveLink.lastSyncStatus == .error
                                    ? AppTheme.Colors.danger
                                    : AppTheme.Colors.textSecondary
                            )
                    }
                }
            }
            .listRowBackground(AppTheme.Colors.surface)

            // Bouton sync now + feedback inline
            Section {
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        if isSyncing {
                            ProgressView().controlSize(.small)
                            Text("Synchronisation en cours…")
                        } else {
                            Image(systemName: "arrow.clockwise")
                            Text("Synchroniser maintenant")
                        }
                        Spacer()
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                }
                .disabled(isSyncing || !enabledLocal)

                if let feedback = lastSyncFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(
                            liveLink.lastSyncStatus == .error
                                ? AppTheme.Colors.danger
                                : AppTheme.Colors.success
                        )
                }
            }
            .listRowBackground(AppTheme.Colors.surface)

            Section {
                if providerType != nil {
                    Button("Modifier les identifiants") { showEditForm = true }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Supprimer ce lien")
                }
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        // Always presented as a pane/sheet (never pushed) → paneChrome
        // unconditionally on both platforms (Close / native iOS sheet, macOS pane
        // or level-2 sheet depending on where it was opened from).
        .paneChrome(link.displayName, cancelLabel: "Fermer", onCancel: { paneDismiss() })
        .adaptivePane(isPresented: $showEditForm) {
            if let providerType {
                LiveSyncLinkFormView(providerType: providerType, existingLink: link)
            }
        }
        .confirmationDialog("Supprimer ce lien ?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { delete() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les credentials seront effacés du Keychain. Les positions déjà synchronisées dans Nemoris ne sont pas supprimées.")
        }
    }

    private func delete() {
        InvestmentCredentialStore.shared.delete(linkId: link.id, providerId: link.providerId)
        LiveSyncRepository.shared.deleteLink(id: link.id)
        onChange()
        paneDismiss()
    }

    @MainActor
    private func syncNow() async {
        isSyncing = true
        lastSyncFeedback = nil
        let error = await LiveSyncRegistry.shared.syncLink(liveLink)
        // Re-fetch to get the last_sync_* columns updated by the Registry
        if let refreshed = LiveSyncRepository.shared.fetchLink(id: link.id) {
            liveLink = refreshed
        }
        if let error {
            lastSyncFeedback = error
            appState.postToast(.error, "Sync « \(link.displayName) » : \(error)")
        } else {
            lastSyncFeedback = "Synchronisation réussie"
            appState.postToast(.success, "Sync « \(link.displayName) » réussie")
        }
        isSyncing = false
        onChange()
        // The Investments module must reflect the manual sync (positions persisted
        // even on a partial error) → bump dataRefreshToken via NemorisApp.
        NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
    }
}
