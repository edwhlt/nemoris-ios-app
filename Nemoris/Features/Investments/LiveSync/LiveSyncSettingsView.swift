import SwiftUI

// MARK: - AXE I Couche 0g — Écran de gestion des liens live sync (Settings)
//
// 3 niveaux :
//   1. LiveSyncSettingsView          : liste des liens existants + bouton "+ Ajouter"
//   2. LiveSyncProviderPickerView    : catalogue des providers disponibles
//   3. LiveSyncLinkFormView          : form de credentials + config (généré dynamiquement)
//
// Couche 0 = squelette UI fonctionnel. Pas de bouton "Sync now" actif (les providers
// renvoient providerNotImplemented). Mais la création/suppression de liens et le
// stockage Keychain marchent réellement.

struct LiveSyncSettingsView: View {
    @State private var links: [InvestmentLiveSyncLink] = []
    @State private var showAddSheet = false
    #if os(macOS)
    /// macOS : le détail d'un lien s'ouvre dans le panneau, pas un push — un
    /// `NavigationLink` ici masquerait le panneau "Ajouter une source" s'il
    /// était déjà ouvert quand l'user clique une row (le panneau est un volet
    /// latéral non modal, la liste reste cliquable pendant qu'il est affiché).
    /// Même bug que documenté dans CLAUDE.md AXE N.1 « Panneau macOS masqué
    /// par du contenu poussé ». `LiveSyncLinkDetailView` est une feuille
    /// (détail d'UN lien), pas un conteneur → panneau, cohérent avec le reste
    /// de l'app (Tricount, tiers, comptes Investissements…).
    @State private var selectedLink: InvestmentLiveSyncLink?
    #endif

    var body: some View {
        // Form (pas List) : boxes arrondies natives macOS via nemorisFormStyle,
        // identique sur iOS. Fond via .background (pas de ZStack+Color, cf. N.1).
        Form {
            explanationSection
            if links.isEmpty {
                emptyStateSection
            } else {
                linksSection
            }
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Synchronisation auto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(AppTheme.Colors.accent)
            }
        }
        .adaptivePane(isPresented: $showAddSheet, onDismiss: load) {
            NavigationStack {
                LiveSyncProviderPickerView()
            }
        }
        #if os(macOS)
        .adaptivePane(item: $selectedLink, onDismiss: load) { link in
            LiveSyncLinkDetailView(link: link, onChange: load)
        }
        #endif
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vos clés restent sur cet iPhone", systemImage: "lock.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                Text("Les clés API et adresses publiques sont stockées dans le Keychain iOS, chiffrées par le système. Aucune donnée n'est envoyée à un serveur Nemoris — les appels vont directement à Binance, Etherscan, CoinGecko, etc.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(AppTheme.Colors.surface)
    }

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                Text("Aucune source synchronisée")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Touchez + en haut à droite pour lier un exchange ou un wallet.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.lg)
            .listRowBackground(Color.clear)
        }
    }

    private var linksSection: some View {
        Section("Sources synchronisées") {
            ForEach(links) { link in
                #if os(macOS)
                Button {
                    selectedLink = link
                } label: {
                    HStack {
                        linkRow(link)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #else
                NavigationLink {
                    LiveSyncLinkDetailView(link: link, onChange: load)
                } label: {
                    linkRow(link)
                }
                #endif
            }
        }
        .listRowBackground(AppTheme.Colors.surface)
    }

    private func linkRow(_ link: InvestmentLiveSyncLink) -> some View {
        let providerType = LiveSyncRegistry.provider(for: link.providerId)
        return HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: providerType?.iconName ?? "questionmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(link.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                HStack(spacing: 4) {
                    Text(providerType?.displayName ?? link.providerId)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if let chain = link.config["chain"] {
                        Text("·")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(chain.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            statusBadge(link)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ link: InvestmentLiveSyncLink) -> some View {
        if !link.enabled {
            Text("Désactivé")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(AppTheme.Colors.textSecondary.opacity(0.15), in: Capsule())
                .foregroundStyle(AppTheme.Colors.textSecondary)
        } else if link.lastSyncStatus == .error {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.danger)
        } else if link.lastSyncStatus == .ok {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.success)
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Load

    private func load() {
        links = LiveSyncRepository.shared.fetchLinks()
    }
}

// MARK: - Provider picker (catalogue)

struct LiveSyncProviderPickerView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
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
                LiveSyncLinkFormView(providerType: providerType, existingLink: nil)
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

    let providerType: InvestmentLiveSyncProvider.Type
    let existingLink: InvestmentLiveSyncLink?

    @State private var displayName: String = ""
    @State private var credentials: [String: String] = [:]
    @State private var selectedChain: String = ""
    @State private var saveError: String?

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
                    confirmLabel: isEditing ? "Mettre à jour" : "Enregistrer",
                    confirmDisabled: !canSave,
                    onConfirm: { save() })
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
            // Suggestion de nom par défaut (l'user peut écraser)
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

    private func save() {
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
        } else {
            // CREATE
            guard let newId = LiveSyncRepository.shared.addLink(
                providerId: providerType.id,
                displayName: displayName,
                accountId: nil,
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
        }
        dismiss()
    }

    private func encodeConfig(_ dict: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Detail view (modifier / supprimer)

struct LiveSyncLinkDetailView: View {
    let link: InvestmentLiveSyncLink
    let onChange: () -> Void

    // dismiss : pop natif (iOS, poussée depuis LiveSyncSettingsView). paneDismiss :
    // ferme le panneau (macOS, cf. `.adaptivePane(item: $selectedLink)` dans
    // LiveSyncSettingsView) — no-op de chaque côté hors de son contexte.
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    @State private var showDeleteConfirm = false
    /// Remplace l'ancien `NavigationLink` vers le form de credentials : un push
    /// interne depuis cette vue, une fois hébergée dans le panneau macOS (pas
    /// de `NavigationStack` locale dans ce cas), n'aurait aucun contexte de
    /// navigation où pousser. `.adaptivePane` marche dans les deux contextes,
    /// cohérent avec `LiveSyncProviderPickerView` qui présente déjà ce même
    /// `LiveSyncLinkFormView` de cette façon pour la création.
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

            // AXE I Couche 1c — Bouton sync now + feedback inline
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
        // Chrome adaptatif : NavigationStack+toolbar natifs avec bouton "Fermer"
        // (iOS poussée / macOS niveau 2) ou barre système du panneau (macOS
        // niveau 1) — cf. `.paneChrome`.
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
        dismiss()
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
