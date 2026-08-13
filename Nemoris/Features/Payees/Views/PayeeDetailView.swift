import SwiftUI
import NemorisEngine

/// Sheet d'édition complète d'un payee. Remplace l'ancien form
/// minimal (name + regex + categoryId) de ReferenceDataView.
///
/// Sections : Identité | Localisation | Appartenance | Catégorisation | Avancé.
/// Le champ `engine_merchant_id` est lecture seule, avec un bouton "Rechercher
/// dans le moteur" qui re-passe le `name` dans le pipeline et propose un nouvel ID.
struct PayeeDetailView: View {
    // Rebind sur paneDismiss (inspector macOS / sheet iOS) — les appels dismiss() restent valides.
    @Environment(\.paneDismiss) private var dismiss

    let initialPayee: Tiers
    let allCategories: [Category]
    let allAccounts: [Account]
    /// Callback appelé après une sauvegarde réussie. Le parent doit recharger sa liste.
    let onSave: () -> Void

    // Champs éditables
    @State private var name: String
    @State private var regex: String
    @State private var categoryId: Int?
    @State private var linkedAccountId: Int?
    @State private var address: String
    @State private var city: String
    @State private var country: String
    @State private var domain: String
    @State private var groupId: Int?
    @State private var groupDisplayName: String
    @State private var engineMerchantId: String?
    @State private var custom: Bool
    @State private var note: String
    @State private var tierType: TierType
    @State private var contactIdentifier: String?

    // UI state
    @State private var showGroupPicker = false
    @State private var showResolveResult = false
    @State private var resolveFeedback: ResolveFeedback?
    @State private var isResolving = false
    @State private var showContactPicker = false
    @State private var contactPreviewName: String?
    @State private var contactsPermissionDenied = false
    /// Tampon pour stocker le contact pick AVANT que le sheet ContactPicker se ferme.
    /// On applique les changements dans `onDismiss` du sheet pour éviter une race
    /// condition entre la fermeture UIKit du CNContactPickerViewController et les
    /// modifications @State, qui faisait dismiss le parent PayeeDetailView entier.
    @State private var pendingPickedContact: ContactPickerSheet.PickedContact?

    private let repository = TransactionRepository()

    init(payee: Tiers,
         allCategories: [Category],
         allAccounts: [Account],
         onSave: @escaping () -> Void)
    {
        self.initialPayee = payee
        self.allCategories = allCategories
        self.allAccounts = allAccounts
        self.onSave = onSave
        _name             = State(initialValue: payee.name)
        _regex            = State(initialValue: payee.regex ?? "")
        _categoryId       = State(initialValue: payee.categoryId)
        _linkedAccountId  = State(initialValue: payee.linkedCompteId)
        _address          = State(initialValue: payee.address ?? "")
        _city             = State(initialValue: payee.city ?? "")
        _country          = State(initialValue: payee.country ?? "")
        _domain           = State(initialValue: payee.domain ?? "")
        _groupId          = State(initialValue: payee.groupId)
        _groupDisplayName = State(initialValue: "")
        _engineMerchantId = State(initialValue: payee.engineMerchantId)
        _custom           = State(initialValue: payee.custom)
        _note             = State(initialValue: payee.note ?? "")
        _tierType         = State(initialValue: payee.tierType)
        _contactIdentifier = State(initialValue: payee.contactIdentifier)
    }

    var body: some View {
            Form {
                typeSection
                identitySection
                if tierType == .contact { contactSection }
                localizationSection
                groupSection
                classificationSection
                if tierType != .contact { advancedSection }
            }
            .nemorisFormStyle()
            .adaptivePane(isPresented: $showGroupPicker) {
                PayeeGroupPickerView(currentGroupId: groupId) { group in
                    groupId = group?.id
                    groupDisplayName = group?.displayName ?? ""
                }
            }
            .sheet(isPresented: $showContactPicker, onDismiss: applyPickedContact) {
                ContactPickerSheet { picked in
                    // CRITIQUE : ne JAMAIS modifier les @State ici ni toucher
                    // `showContactPicker`. CNContactPickerViewController dismisses
                    // lui-même son sheet UIKit, et toute mutation @State pendant
                    // cette dismissal cascade jusqu'au parent PayeeDetailView qui
                    // se ferme à tort. On ne fait QUE stocker dans le tampon.
                    pendingPickedContact = picked
                }
            }
            .alert("Résolution moteur", isPresented: $showResolveResult, presenting: resolveFeedback) { _ in
                Button("OK", role: .cancel) {}
            } message: { feedback in
                Text(feedback.message)
            }
            .alert("Accès au carnet refusé", isPresented: $contactsPermissionDenied) {
                Button("OK", role: .cancel) {}
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Ouvrir Réglages") { UIApplication.shared.open(url) }
                }
                #else
                Button("Ouvrir Réglages Système") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif
            } message: {
                Text("Va dans Réglages > Nemoris > Contacts pour autoriser l'accès.")
            }
            .task {
                loadGroupName()
                await loadContactPreview()
            }
            .paneChrome("Tiers",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                        onConfirm: { save() })
    }

    // MARK: Type section

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $tierType) {
                ForEach(TierType.allCases) { type in
                    Label(type.displayName, systemImage: type.systemIcon).tag(type)
                }
            }
            .pickerStyle(.menu)
        } header: { Text("Type") }
        footer: {
            switch tierType {
            case .merchant:     Text("Commerce identifié par une marque canonique (Carrefour, Apple…).")
            case .contact:      Text("Personne physique. Tu peux lier ce tier à un contact iOS pour récupérer sa photo.")
            case .internal:     Text("Représente un de tes propres comptes (virement interne).")
            case .organization: Text("CAF, école, employeur — entité publique ou privée non commerciale.")
            }
        }
    }

    // MARK: Contact section (visible seulement si tierType == .contact)

    @ViewBuilder
    private var contactSection: some View {
        Section {
            if let contactId = contactIdentifier, !contactId.isEmpty {
                HStack(spacing: 12) {
                    MerchantLogo(domain: nil, engineMerchantId: nil,
                                 fallbackIcon: "person.crop.circle.fill",
                                 contactIdentifier: contactId, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contactPreviewName ?? "Contact lié").font(.subheadline.weight(.semibold))
                        Text("Photo et nom synchronisés depuis ton carnet iOS")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        contactIdentifier = nil
                        contactPreviewName = nil
                    } label: {
                        Image(systemName: "link.badge.minus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                Task { await openContactPicker() }
            } label: {
                Label(contactIdentifier == nil ? "Lier au carnet de contacts" : "Changer de contact",
                      systemImage: "person.crop.circle.badge.plus")
            }
        } header: { Text("Carnet de contacts iOS") }
        footer: {
            Text("100% local — aucune donnée n'est envoyée. La permission est demandée au premier lien.")
        }
    }

    private func openContactPicker() async {
        // Reset du tampon avant chaque ouverture pour éviter de ré-appliquer
        // un pick précédent (improbable mais sécuritaire).
        pendingPickedContact = nil
        let granted = await ContactsService.shared.requestAccess()
        if granted {
            showContactPicker = true
        } else {
            contactsPermissionDenied = true
        }
    }

    /// Exécuté par `.sheet(onDismiss:)` APRÈS la fermeture complète du
    /// ContactPickerSheet. Sécurise les mutations @State : le parent
    /// PayeeDetailView est de nouveau stable, donc plus de risque de
    /// dismiss en cascade.
    private func applyPickedContact() {
        guard let picked = pendingPickedContact else { return }
        pendingPickedContact = nil
        contactIdentifier = picked.identifier
        contactPreviewName = picked.name
        // Auto-fill du nom si vide ou identique au nom initial (placeholder)
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name == initialPayee.name {
            name = picked.name
        }
    }

    private func loadContactPreview() async {
        guard let id = contactIdentifier, !id.isEmpty else { return }
        contactPreviewName = await ContactsService.shared.fetchName(identifier: id)
    }

    // MARK: Sections

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                MerchantLogo(domain: domain.nilIfEmpty,
                             engineMerchantId: engineMerchantId,
                             fallbackIcon: categoryIcon,
                             size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Nom", text: $name)
                        .font(.headline)
                        .autocorrectionDisabled()
                    Toggle("Tiers personnalisé", isOn: $custom)
                        .font(.caption)
                        .toggleStyle(.switch)
                }
            }
            .padding(.vertical, 4)
        } header: { Text("Identité") }
        footer: {
            if custom {
                Text("Un tiers personnalisé ne sera pas réassigné automatiquement par le moteur lors des futurs imports.")
            }
        }
    }

    private var localizationSection: some View {
        Section {
            TextField("Adresse postale", text: $address, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
            TextField("Ville", text: $city)
                .autocorrectionDisabled()
            TextField("Pays (code ISO, ex. FR)", text: $country)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: country) { _, newValue in
                    if newValue.count > 2 { country = String(newValue.prefix(2)) }
                }
        } header: { Text("Localisation") }
    }

    private var groupSection: some View {
        Section {
            Button {
                showGroupPicker = true
            } label: {
                HStack {
                    Text("Groupe").foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    Text(groupId == nil ? "Aucun" : (groupDisplayName.isEmpty ? "Groupe #\(groupId!)" : groupDisplayName))
                        .foregroundStyle(groupId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.accent)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
        } header: { Text("Appartenance") }
        footer: {
            Text("Regroupe plusieurs tiers d'une même enseigne (ex. tous les Carrefour Market).")
        }
    }

    private var classificationSection: some View {
        Section {
            Picker("Catégorie", selection: $categoryId) {
                Text("Aucune").tag(Int?.none)
                ForEach(allCategories) { c in
                    Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                }
            }
            TextField("Domaine web (pour le logo)", text: $domain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 4) {
                Text("Regex de détection (optionnel)")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                TextEditor(text: $regex)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 60)
            }
        } header: { Text("Catégorisation") }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            LabeledContent("ID moteur") {
                Text(engineMerchantId ?? "—")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(engineMerchantId == nil ? .secondary : .primary)
            }
            Button {
                Task { await resolveWithEngine() }
            } label: {
                if isResolving {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Recherche en cours…")
                    }
                } else {
                    Label("Rechercher dans le moteur", systemImage: "wand.and.stars")
                }
            }
            .disabled(isResolving || name.trimmingCharacters(in: .whitespaces).isEmpty)

            if engineMerchantId != nil {
                Button(role: .destructive) {
                    engineMerchantId = nil
                } label: {
                    Label("Délier du moteur", systemImage: "link.badge.minus")
                }
            }

            if !allAccounts.isEmpty {
                Picker("Compte interne lié (virement)", selection: $linkedAccountId) {
                    Text("Aucun").tag(Int?.none)
                    ForEach(allAccounts) { a in
                        Text(a.name).tag(Int?.some(a.id))
                    }
                }
            }
        } header: { Text("Avancé") }
        footer: {
            Text("Le compte interne lié indique que ce tiers représente un virement entre vos propres comptes.")
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $note)
                    .frame(minHeight: 80)
            }
        } header: { Text("Note") }
    }

    // MARK: Helpers

    private var categoryIcon: String? {
        allCategories.first(where: { $0.id == categoryId })?.displayIcon
    }

    private func loadGroupName() {
        guard let gid = groupId else { groupDisplayName = ""; return }
        let groups = repository.fetchPayeeGroups()
        groupDisplayName = groups.first(where: { $0.id == gid })?.displayName ?? ""
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty else { return }

        var updated = initialPayee
        updated.name             = cleanName
        updated.regex            = regex.trimmingCharacters(in: .whitespaces).nilIfEmpty
        updated.categoryId       = categoryId
        updated.linkedCompteId   = linkedAccountId
        updated.engineMerchantId = engineMerchantId?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        updated.domain           = domain.trimmingCharacters(in: .whitespaces).nilIfEmpty
        updated.address          = address.trimmingCharacters(in: .whitespaces).nilIfEmpty
        updated.city             = city.trimmingCharacters(in: .whitespaces).nilIfEmpty
        updated.country          = country.trimmingCharacters(in: .whitespaces).uppercased().nilIfEmpty
        updated.groupId          = groupId
        updated.custom           = custom
        updated.note             = note.trimmingCharacters(in: .whitespaces).nilIfEmpty
        // ces 2 champs étaient oubliés du remap → le picker tierType et
        // le lien contact ne se persistaient jamais (on écrivait les valeurs
        // initialPayee, pas les @State courants). Bug fix critique.
        updated.tierType         = tierType
        // Si l'utilisateur a explicitement délié, on stocke nil. Sinon on prend la valeur courante
        // (peut être nil si jamais lié). On ne garde le contact que si tier_type == .contact
        // pour éviter qu'un tier qu'on re-type en .merchant garde un lien orphelin.
        updated.contactIdentifier = (tierType == .contact) ? contactIdentifier : nil

        if repository.updatePayeeFull(updated) {
            onSave()
            dismiss()
        }
    }

    private func resolveWithEngine() async {
        guard let engine = EngineBootstrap.shared.engine else {
            resolveFeedback = ResolveFeedback(message: "Le moteur n'est pas encore prêt — réessaie dans un instant.")
            showResolveResult = true
            return
        }
        isResolving = true
        defer { isResolving = false }

        let label = name.trimmingCharacters(in: .whitespaces)
        let resolution = await Task.detached(priority: .userInitiated) { () -> ResolvedTransaction? in
            try? engine.resolve(label)
        }.value

        guard let resolved = resolution else {
            resolveFeedback = ResolveFeedback(message: "Aucune correspondance trouvée pour « \(label) ».")
            showResolveResult = true
            return
        }

        switch resolved.decision {
        case .autoValidated, .suggested:
            guard let top = resolved.topCandidate else {
                resolveFeedback = ResolveFeedback(message: "Le moteur n'a pas proposé de marque pour « \(label) ».")
                showResolveResult = true
                return
            }
            engineMerchantId = top.merchantId
            if !top.canonicalName.isEmpty,
               name.lowercased() == initialPayee.name.lowercased() {
                name = top.canonicalName.titleCased
            }
            if domain.isEmpty,
               let suggested = MerchantDomains.domain(for: top.merchantId) {
                domain = suggested
            }
            if city.isEmpty, let c = resolved.parsed.cityCandidate {
                city = c.titleCased
            }
            if country.isEmpty, let cc = resolved.parsed.countryCandidate {
                country = cc.uppercased()
            }
            let label = resolved.decision == .autoValidated ? "auto-validé" : "suggéré"
            resolveFeedback = ResolveFeedback(
                message: "Trouvé : \(top.canonicalName) (\(top.merchantId)) — \(label), score \(String(format: "%.2f", top.score))."
            )
            showResolveResult = true
        default:
            resolveFeedback = ResolveFeedback(
                message: "Pas assez de confiance pour proposer une marque (décision : \(resolved.decision))."
            )
            showResolveResult = true
        }
    }
}

private struct ResolveFeedback: Identifiable {
    let id = UUID()
    let message: String
}

private extension String {
    var nilIfEmpty: String? {
        let t = self.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
