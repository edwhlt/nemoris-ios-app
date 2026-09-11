import SwiftUI
import NemorisEngine

/// Full editing sheet for a payee. Replaces the earlier minimal form
/// (name + regex + categoryId) in ReferenceDataView.
///
/// Sections: Identity | Location | Membership | Categorization | Advanced.
/// The `engine_merchant_id` field is read-only, with a "search the engine"
/// button that runs `name` back through the pipeline and offers a new ID.
struct PayeeDetailView: View {
    // Rebound onto paneDismiss (macOS inspector / iOS sheet) — dismiss() calls stay valid.
    @Environment(\.paneDismiss) private var dismiss

    let initialPayee: Tiers
    /// `payee` was nil at init (creation): `save()` first inserts a minimal
    /// row (to obtain an id), then persists every field filled in during
    /// THIS SAME session — rather than forcing the user to create a minimal
    /// payee and reopen this sheet to complete it.
    let isCreating: Bool
    let allCategories: [Category]
    let allAccounts: [Account]
    /// Callback invoked after a successful save. The parent must reload its list.
    let onSave: () -> Void

    // Editable fields
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
    @State private var showLinkedAccountPicker = false
    @State private var showResolveResult = false
    @State private var resolveFeedback: ResolveFeedback?
    @State private var isResolving = false
    @State private var showContactPicker = false
    @State private var contactPreviewName: String?
    @State private var contactsPermissionDenied = false
    /// Buffer holding the picked contact BEFORE the ContactPicker sheet
    /// closes. The changes are applied in the sheet's `onDismiss` to avoid a
    /// race between UIKit dismissing CNContactPickerViewController and the
    /// @State mutations, which dismissed the whole parent PayeeDetailView.
    @State private var pendingPickedContact: ContactPickerSheet.PickedContact?

    private let repository = TransactionRepository()

    /// `payee` nil = creation (blank sheet, every rich field available from
    /// the start — no separate minimal form any more).
    init(payee: Tiers? = nil,
         allCategories: [Category],
         allAccounts: [Account],
         onSave: @escaping () -> Void)
    {
        let payee = payee ?? Tiers(id: 0, name: "")
        self.initialPayee = payee
        self.isCreating = payee.id <= 0
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
            .adaptivePane(isPresented: $showLinkedAccountPicker) {
                AccountSearchSheet(
                    accounts: allAccounts,
                    selectedId: linkedAccountId,
                    title: "Compte interne lié",
                    specialLabel: "Aucun",
                    specialIcon: "xmark.circle"
                ) { picked in
                    linkedAccountId = picked?.id
                }
            }
            .sheet(isPresented: $showContactPicker, onDismiss: applyPickedContact) {
                ContactPickerSheet { picked in
                    // CRITICAL: NEVER mutate @State here, and never touch
                    // `showContactPicker`. CNContactPickerViewController
                    // dismisses its own UIKit sheet, and any @State mutation
                    // during that dismissal cascades up to the parent
                    // PayeeDetailView, which then closes by mistake. Only
                    // store into the buffer here.
                    pendingPickedContact = picked
                }
                // Re-injecting \.locale is mandatory — on macOS this sheet
                // shows a text placeholder ("coming soon on Mac").
                .environment(\.locale, AppLocalization.locale)
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
            .paneChrome(isCreating ? "Nouveau tiers" : "Tiers",
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
                    Label(LocalizedStringKey(type.displayName), systemImage: type.systemIcon).tag(type)
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

    // MARK: Contact section (visible only when tierType == .contact)

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
        // Reset the buffer before each opening to avoid re-applying a
        // previous pick (unlikely, but safe).
        pendingPickedContact = nil
        let granted = await ContactsService.shared.requestAccess()
        if granted {
            showContactPicker = true
        } else {
            contactsPermissionDenied = true
        }
    }

    /// Run by `.sheet(onDismiss:)` AFTER ContactPickerSheet has fully
    /// closed. Makes the @State mutations safe: the parent PayeeDetailView
    /// is stable again, so there's no more cascading-dismiss risk.
    private func applyPickedContact() {
        guard let picked = pendingPickedContact else { return }
        pendingPickedContact = nil
        contactIdentifier = picked.identifier
        contactPreviewName = picked.name
        // Auto-fill the name when empty or identical to the initial one (placeholder)
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
                Button {
                    showLinkedAccountPicker = true
                } label: {
                    HStack {
                        Text("Compte interne lié (virement)").foregroundStyle(AppTheme.Colors.textPrimary)
                        Spacer()
                        // Wrap requis : coalescing avec `.name` rend
                        // l'expression entière `String` — `Text(String)`
                        // reste verbatim sans lui, cf. CLAUDE.md §5.
                        Text(LocalizedStringKey(allAccounts.first(where: { $0.id == linkedAccountId })?.name ?? "Aucun"))
                            .foregroundStyle(linkedAccountId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.accent)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
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
        // These 2 fields must be remapped explicitly: writing the
        // initialPayee values instead of the current @State would mean the
        // tierType picker and the contact link never persist.
        updated.tierType         = tierType
        // If the user explicitly unlinked, store nil. Otherwise take the
        // current value (which may be nil if never linked). The contact is
        // kept only when tier_type == .contact, so a payee re-typed as
        // .merchant doesn't keep an orphaned link.
        updated.contactIdentifier = (tierType == .contact) ? contactIdentifier : nil

        if isCreating {
            // `updatePayeeFull` does an UPDATE by id — a real row must
            // exist first to obtain one. The remaining rich fields
            // (location, group, type, note…) are then persisted by the SAME
            // `updatePayeeFull` as the editing path, right away: no
            // "create minimal then reopen" round trip. `id` is a `let` on
            // `Tiers` — rebuild rather than mutate.
            guard let newId = repository.addTiersAndGetId(
                name: cleanName, regex: updated.regex ?? "", categoryId: updated.categoryId
            ) else { return }
            updated = Tiers(
                id: newId,
                name: updated.name,
                regex: updated.regex,
                categoryId: updated.categoryId,
                linkedCompteId: updated.linkedCompteId,
                engineMerchantId: updated.engineMerchantId,
                domain: updated.domain,
                address: updated.address,
                city: updated.city,
                country: updated.country,
                groupId: updated.groupId,
                custom: updated.custom,
                note: updated.note,
                tierType: updated.tierType,
                contactIdentifier: updated.contactIdentifier
            )
        }

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
