import SwiftUI
import NemorisEngine

/// Sheet présentée APRÈS le `PayeePickerSheet` quand l'utilisateur choisit de lier
/// une row d'import à un tier existant.
///
/// **Mode édition complète** (V2-style) : tous les champs du tier sont éditables
/// directement. Pour chaque champ où la résolution moteur / l'enrichissement propose
/// une valeur différente, une chip "Ajouter / Remplacer" permet de l'appliquer d'un tap.
/// Pour le regex, l'append (avec séparateur `|`) est privilégié pour ne pas perdre
/// les patterns déjà appris.
struct TierUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let row: ImportSessionRow
    let existingPayee: Tiers
    let onApply: (Tiers) -> Void

    // Champs édités
    @State private var name: String
    @State private var regex: String
    @State private var domain: String
    @State private var city: String
    @State private var country: String
    @State private var address: String
    @State private var engineMerchantId: String
    @State private var categoryId: Int?
    @State private var groupId: Int?

    // Référentiels chargés à la volée
    @State private var allCategories: [Category] = []
    @State private var payeeGroups: [PayeeGroup] = []
    @State private var showGroupPicker = false

    // Candidats issus de l'import (computed once à l'init)
    private let candidate: UpdateCandidate

    private let repository = TransactionRepository()

    init(row: ImportSessionRow, existingPayee: Tiers, onApply: @escaping (Tiers) -> Void) {
        self.row = row
        self.existingPayee = existingPayee
        self.onApply = onApply
        self.candidate = UpdateCandidate(row: row)

        _name             = State(initialValue: existingPayee.name)
        _regex            = State(initialValue: existingPayee.regex ?? "")
        _domain           = State(initialValue: existingPayee.domain ?? "")
        _city             = State(initialValue: existingPayee.city ?? "")
        _country          = State(initialValue: existingPayee.country ?? "")
        _address          = State(initialValue: existingPayee.address ?? "")
        _engineMerchantId = State(initialValue: existingPayee.engineMerchantId ?? "")
        _categoryId       = State(initialValue: existingPayee.categoryId)
        _groupId          = State(initialValue: existingPayee.groupId)
    }

    var body: some View {
        NavigationStack {
            Form {
                contextSection
                identitySection
                classificationSection
                localizationSection
                advancedSection
            }
            .nemorisFormStyle()
            .navigationTitle("Vérifier le tier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ⚠️ Volontairement en texte, PAS d'icône : contrairement à un
                    // vrai "Annuler", ce bouton APPLIQUE quand même la ligne
                    // (`onApply(existingPayee)`) — juste sans les modifications
                    // proposées. Un xmark serait lu comme "ne rien faire", alors
                    // qu'un clic ici valide bel et bien l'import de la ligne.
                    Button("Sans modif") {
                        onApply(existingPayee)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply(buildUpdatedPayee())
                        dismiss()
                    } label: {
                        Label("Enregistrer", systemImage: "checkmark")
                    }
                }
            }
            .sheet(isPresented: $showGroupPicker) {
                PayeeGroupPickerView(currentGroupId: groupId) { group in
                    groupId = group?.id
                }
            }
            .task {
                if allCategories.isEmpty { allCategories = repository.fetchCategories() }
                if payeeGroups.isEmpty { payeeGroups = repository.fetchPayeeGroups() }
            }
        }
    }

    // MARK: - Sections

    private var contextSection: some View {
        Section {
            HStack(spacing: 12) {
                MerchantLogo(domain: domain.nilIfEmpty,
                             engineMerchantId: engineMerchantId.nilIfEmpty,
                             fallbackIcon: allCategories.first(where: { $0.id == categoryId })?.displayIcon,
                             size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existingPayee.name).font(.headline)
                    Text("Tier #\(existingPayee.id)")
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
                Spacer()
            }
            LabeledContent("Libellé d'import") {
                Text(row.rawLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
    }

    private var identitySection: some View {
        Section("Identité") {
            editableField(title: "Nom",
                          value: $name,
                          suggestion: candidate.name,
                          suggestionLabel: "Renommer")
        }
    }

    private var classificationSection: some View {
        Section("Catégorisation") {
            Picker("Catégorie", selection: $categoryId) {
                Text("Aucune").tag(Int?.none)
                ForEach(allCategories) { c in
                    Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                }
            }

            editableField(title: "Domaine",
                          value: $domain,
                          suggestion: candidate.domain,
                          suggestionLabel: "Utiliser",
                          keyboardURL: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Regex de détection").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                TextEditor(text: $regex)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 60)
                if let suggested = candidate.regex, !regex.contains(suggested) {
                    HStack(spacing: 6) {
                        SuggestionChip(text: "Ajouter |\(suggested.prefix(28))…",
                                       icon: "plus.circle.fill",
                                       tint: AppTheme.Colors.accent) {
                            regex = combineRegex(old: regex, new: suggested)
                        }
                        SuggestionChip(text: "Remplacer",
                                       icon: "arrow.triangle.2.circlepath",
                                       tint: AppTheme.Colors.warning) {
                            regex = suggested
                        }
                    }
                }
            }
        }
    }

    private var localizationSection: some View {
        Section("Localisation") {
            editableField(title: "Ville",
                          value: $city,
                          suggestion: candidate.city,
                          suggestionLabel: "Utiliser")
            editableField(title: "Pays (ISO)",
                          value: $country,
                          suggestion: candidate.country?.uppercased(),
                          suggestionLabel: "Utiliser",
                          uppercased: true,
                          maxLength: 2)
            editableField(title: "Adresse",
                          value: $address,
                          suggestion: candidate.address,
                          suggestionLabel: "Utiliser",
                          axisVertical: true)
        }
    }

    private var advancedSection: some View {
        Section("Avancé") {
            Button {
                showGroupPicker = true
            } label: {
                HStack {
                    Text("Groupe").foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    Text(groupId == nil ? "Aucun"
                         : payeeGroups.first(where: { $0.id == groupId })?.displayName ?? "Groupe #\(groupId!)")
                        .foregroundStyle(groupId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.accent)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }

            editableField(title: "ID moteur",
                          value: $engineMerchantId,
                          suggestion: candidate.engineMerchantId,
                          suggestionLabel: "Lier",
                          monospaced: true)
        }
    }

    // MARK: - Helpers

    /// Champ texte éditable + chip de suggestion (si différente de la valeur actuelle).
    @ViewBuilder
    private func editableField(title: String,
                               value: Binding<String>,
                               suggestion: String?,
                               suggestionLabel: String,
                               keyboardURL: Bool = false,
                               uppercased: Bool = false,
                               maxLength: Int? = nil,
                               axisVertical: Bool = false,
                               monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                if let suggestion, !suggestion.isEmpty, suggestion != value.wrappedValue {
                    SuggestionChip(text: "\(suggestionLabel) « \(suggestion.prefix(20))\(suggestion.count > 20 ? "…" : "") »",
                                   icon: "wand.and.stars",
                                   tint: AppTheme.Colors.accent) {
                        value.wrappedValue = suggestion
                    }
                }
            }
            if axisVertical {
                TextField(title, text: value, axis: .vertical)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
            } else {
                TextField(title, text: value)
                    .keyboardType(keyboardURL ? .URL : .default)
                    .textInputAutocapitalization(uppercased ? .characters : .sentences)
                    .autocorrectionDisabled()
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .onChange(of: value.wrappedValue) { _, newVal in
                        var v = newVal
                        if uppercased { v = v.uppercased() }
                        if let max = maxLength, v.count > max { v = String(v.prefix(max)) }
                        if v != newVal { value.wrappedValue = v }
                    }
            }
        }
        .padding(.vertical, 2)
    }

    private func buildUpdatedPayee() -> Tiers {
        var u = existingPayee
        u.name             = name.trimmingCharacters(in: .whitespaces)
        u.regex            = regex.trimmingCharacters(in: .whitespaces).nilIfEmpty
        u.domain           = domain.trimmingCharacters(in: .whitespaces).nilIfEmpty
        u.city             = city.trimmingCharacters(in: .whitespaces).nilIfEmpty
        u.country          = country.trimmingCharacters(in: .whitespaces).uppercased().nilIfEmpty
        u.address          = address.trimmingCharacters(in: .whitespaces).nilIfEmpty
        u.engineMerchantId = engineMerchantId.trimmingCharacters(in: .whitespaces).nilIfEmpty
        u.categoryId       = categoryId
        u.groupId          = groupId
        return u
    }

    private func combineRegex(old: String, new: String) -> String {
        let o = old.trimmingCharacters(in: .whitespaces)
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return o }
        if o.isEmpty { return n }
        if o.contains(n) { return o }
        return "\(o)|\(n)"
    }
}

// MARK: - Suggestion chip

private struct SuggestionChip: View {
    let text: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2.weight(.bold))
                Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.13), in: Capsule())
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Candidate from import row

private struct UpdateCandidate {
    let name: String?
    let regex: String?
    let domain: String?
    let city: String?
    let country: String?
    let address: String?
    let engineMerchantId: String?

    init(row: ImportSessionRow) {
        // Regex : pattern simple insensible casse à partir du libellé brut
        let escaped = NSRegularExpression.escapedPattern(for: row.rawLabel)
            .trimmingCharacters(in: .whitespaces)
        self.regex = escaped.isEmpty ? nil : "(?i)\(escaped)"

        switch row.resolution {
        case .matched(_, let eid, let name, let city, _):
            self.name = name
            self.engineMerchantId = eid
            self.city = city
            self.country = nil
            self.address = nil
            self.domain = eid.flatMap { MerchantDomains.domain(for: $0) }
        case .suggestCreate(let eid, let name, let city, let country, _):
            self.name = name
            self.engineMerchantId = eid
            self.city = city
            self.country = country
            self.address = nil
            self.domain = MerchantDomains.domain(for: eid)
        case .needsManualPick(_, let eid, let topName, _):
            self.name = topName
            self.engineMerchantId = eid
            self.city = nil
            self.country = nil
            self.address = nil
            self.domain = eid.flatMap { MerchantDomains.domain(for: $0) }
        case .suggestContact(let name, _):
            self.name = name
            self.engineMerchantId = nil
            self.city = nil
            self.country = nil
            self.address = nil
            self.domain = nil
        case .systemOperation, .pending:
            self.name = nil
            self.engineMerchantId = nil
            self.city = nil
            self.country = nil
            self.address = nil
            self.domain = nil
        }
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? {
        let t = self.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
