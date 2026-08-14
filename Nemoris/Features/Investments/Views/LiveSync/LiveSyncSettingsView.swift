import SwiftUI

// MARK: - AXE I Couche 0g → repris 2026-08-08 : gestion des liens live sync
// intégrée au module Investissements (n'est plus un écran de Settings).
//
// 3 niveaux :
//   1. LiveSyncProviderPickerView: catalogue des providers disponibles
//   2. LiveSyncLinkFormView: form de credentials + config (généré dynamiquement)
//   3. LiveSyncLinkDetailView: détail d'UN lien (statut, sync, édition, suppression)
//
// Points d'entrée (2, tous les deux ouvrent `LiveSyncProviderPickerView`) :
//   - `InvestmentsView` (toolbar module, "Lier un exchange / wallet") — pas de
//     compte pré-existant : `accountId: nil`, un compte dédié est créé à la
//     volée par `LiveSyncLinkFormView.save()`.
//   - `InvestmentAccountFormView` (fiche "Modifier le compte", section
//     "Synchronisation") — `accountId: account.id`, le nouveau lien est
//     rattaché directement à CE compte.
//
// Il n'y a plus de liste globale des liens indépendante d'un compte : chaque
// lien est TOUJOURS visible et gérable depuis la fiche du compte auquel il
// est rattaché (cf. `InvestmentAccountFormView.linkedSourcesSection`).

// MARK: - Provider picker (catalogue)

struct LiveSyncProviderPickerView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    /// Compte auquel rattacher le nouveau lien. `nil` = créé depuis le
    /// catalogue du module (pas de compte pré-existant) : `LiveSyncLinkFormView`
    /// crée alors un compte dédié à la volée. Non-nil = créé depuis la fiche
    /// d'un compte existant, le lien lui est directement rattaché.
    var accountId: Int? = nil
    /// État à la place d'un `NavigationLink` : un push depuis ce contenu, une
    /// fois hébergé dans le panneau macOS, ferait remonter le titre/back-button
    /// du form de credentials dans la barre du MODULE. Sheet niveau 2 à la place.
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

// MARK: - Form de credentials (création/édition)

struct LiveSyncLinkFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let providerType: InvestmentLiveSyncProvider.Type
    let existingLink: InvestmentLiveSyncLink?
    /// Compte cible pour un NOUVEAU lien. Ignoré en édition (`existingLink`
    /// porte déjà son propre `accountId`, jamais réassigné ici). `nil` en
    /// création = aucun compte fourni par l'appelant → `save()` en crée un.
    var accountId: Int? = nil

    @State private var displayName: String = ""
    @State private var credentials: [String: String] = [:]
    @State private var selectedChain: String = ""
    @State private var saveError: String?
    /// Vrai pendant `save()` (persistance + première synchronisation). Sans ce
    /// garde, un lien se créait même avec des identifiants invalides (ex. clé
    /// Etherscan manquante) sans qu'aucun signal n'apparaisse avant le premier
    /// "Synchroniser maintenant" — un user ne voyant rien se produire au tap
    /// "Enregistrer" pouvait retenter et créer un doublon local.
    @State private var isSaving = false

    private var isEditing: Bool { existingLink != nil }

    private var canSave: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        for field in providerType.credentialFields {
            let val = credentials[field.key] ?? ""
            // .anyString = champ optionnel (peut être vide) → on saute la check
            if case .anyString = field.validation { continue }
            // Vide ou invalide → blocage
            if val.isEmpty || !field.isValid(val) { return false }
        }
        if providerType.supportsChainSelection && selectedChain.isEmpty { return false }
        return true
    }

    var body: some View {
        // Fond via .background (borné par le Form) et non ZStack+Color gourmand :
        // ce dernier étire la fenêtre à l'infini sur macOS (cf. N.1a SettingsView).
        Form {
                Section("Nom d'affichage") {
                    TextField("Ex: \(suggestedName)", text: $displayName)
                }

                if providerType.supportsChainSelection {
                    Section("Chaîne") {
                        Picker("Chaîne", selection: $selectedChain) {
                            ForEach(providerType.supportedChains) { chain in
                                Label(chain.displayName, systemImage: chain.icon).tag(chain.id)
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
            // Suggestion de nom par défaut (l'utilisateur peut écraser)
            displayName = suggestedName
            // Chaîne par défaut = première dispo si applicable
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
        // Trim toutes les valeurs avant sauvegarde
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
            // CREATE — un compte cible est TOUJOURS assigné dès la création :
            // celui fourni par l'appelant (fiche compte → "Lier une source à
            // ce compte") ou, à défaut, un nouveau compte dédié créé ici même
            // (catalogue du module → aucun compte pré-existant). Avant ce
            // chantier, un lien créé sans accountId restait invisible tant que
            // son premier sync manuel n'avait pas réussi (l'auto-création du
            // compte n'avait lieu que dans `persistPositions`, au moment de la
            // sync) — désormais le compte existe et apparaît dans la liste des
            // comptes Investissements dès l'enregistrement, même si la sync
            // qui suit échoue.
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
                // Rollback : supprimer le lien créé puisque les credentials n'ont pas pu être stockés
                LiveSyncRepository.shared.deleteLink(id: newId)
                saveError = "Erreur Keychain : \(error.localizedDescription)"
                return
            }
            linkId = newId
        }

        // Première synchronisation immédiate (création ET édition) : le compte
        // existe déjà à ce stade, donc même un échec réseau ici laisse un lien
        // pleinement visible et gérable depuis la fiche du compte plutôt qu'un
        // état "en attente" silencieux. Best-effort : on informe par toast mais
        // on ne bloque jamais la fermeture du formulaire dessus (les
        // identifiants, eux, sont déjà correctement persistés).
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

// MARK: - Detail view (statut / sync / modifier / supprimer)

struct LiveSyncLinkDetailView: View {
    let link: InvestmentLiveSyncLink
    let onChange: () -> Void

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS — cette vue
    // est TOUJOURS présentée via `.adaptivePane` (jamais poussée par
    // NavigationLink), donc c'est le seul mécanisme de fermeture pertinent ici.
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    @State private var showDeleteConfirm = false
    /// Remplace l'ancien `NavigationLink` vers le form de credentials : un push
    /// interne depuis cette vue, une fois hébergée dans le panneau macOS (pas
    /// de `NavigationStack` locale dans ce cas), n'aurait aucun contexte de
    /// navigation où pousser. `.adaptivePane` marche dans les deux contextes.
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
                if let message = liveLink.lastSyncMessage, !message.isEmpty {
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
        // Toujours présentée en pane/sheet (jamais poussée) → paneChrome
        // inconditionnel sur les deux plateformes (Fermer / iOS sheet native,
        // macOS panneau ou sheet niveau 2 selon le contexte d'ouverture).
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
        // Re-fetch pour récupérer les nouvelles colonnes last_sync_* mises à jour par le Registry
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
        // Chantier A : le module Investissements doit refléter la sync manuelle
        // (positions persistées même en cas d'erreur partielle) → bump du
        // dataRefreshToken via NemorisApp.
        NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
    }
}
