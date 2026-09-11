import SwiftUI

/// Final step (and the only step, for a bulk merge) of a DUPLICATE payee
/// merge: resolves the fields that DIVERGE between `candidates` (≥2), then
/// commits the merge — THIS view writes to the database, not
/// `PayeeMergeTargetPicker` upstream.
///
/// Asking the user to choose a "target" in a separate picker made no sense
/// for an already-explicit bulk selection (2+ payees ticked): they want to
/// resolve the FIELDS that diverge, not search for a payee already in front
/// of them. A field that does NOT diverge asks no question (resolved
/// silently) — only real disagreements reach the screen.
struct PayeeMergeResolverView: View {
    /// ≥2 payees to merge into one.
    let candidates: [Tiers]
    let allCategories: [Category]
    let payeeGroups: [PayeeGroup]
    /// Used to pick the KEPT record by default — the one with the most
    /// history is the most "established".
    let transactionCounts: [Int: Int]
    var onMerged: () -> Void = {}

    @Environment(\.paneDismiss) private var dismiss
    private let repository = TransactionRepository()

    /// The record whose id SURVIVES — its internal fields not resolved here
    /// (payee type, linked transfer…) are kept as-is.
    private let keeper: Tiers

    @State private var resolvedName: String
    @State private var resolvedCategoryId: Int?
    @State private var resolvedGroupId: Int?
    @State private var resolvedCity: String
    @State private var resolvedCountry: String
    @State private var resolvedAddress: String
    @State private var resolvedDomain: String
    @State private var resolvedNote: String
    @State private var resolvedRegex: String

    init(candidates: [Tiers], allCategories: [Category], payeeGroups: [PayeeGroup],
         transactionCounts: [Int: Int], onMerged: @escaping () -> Void = {}) {
        self.candidates = candidates
        self.allCategories = allCategories
        self.payeeGroups = payeeGroups
        self.transactionCounts = transactionCounts
        self.onMerged = onMerged

        let keeper = candidates.sorted { a, b in
            let ca = transactionCounts[a.id] ?? 0, cb = transactionCounts[b.id] ?? 0
            return ca != cb ? ca > cb : a.id < b.id
        }.first!
        self.keeper = keeper

        func resolve(_ keeperValue: String?, _ all: [String?]) -> String {
            if let k = keeperValue?.trimmingCharacters(in: .whitespaces), !k.isEmpty { return k }
            for v in all {
                if let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            }
            return ""
        }

        _resolvedName     = State(initialValue: resolve(keeper.name, candidates.map { $0.name }))
        _resolvedCity     = State(initialValue: resolve(keeper.city, candidates.map { $0.city }))
        _resolvedCountry  = State(initialValue: resolve(keeper.country, candidates.map { $0.country }))
        _resolvedAddress  = State(initialValue: resolve(keeper.address, candidates.map { $0.address }))
        _resolvedDomain   = State(initialValue: resolve(keeper.domain, candidates.map { $0.domain }))
        _resolvedNote     = State(initialValue: resolve(keeper.note, candidates.map { $0.note }))
        _resolvedRegex    = State(initialValue: resolve(keeper.regex, candidates.map { $0.regex }))
        _resolvedCategoryId = State(initialValue: keeper.categoryId ?? candidates.compactMap { $0.categoryId }.first)
        _resolvedGroupId    = State(initialValue: keeper.groupId ?? candidates.compactMap { $0.groupId }.first)
    }

    // MARK: - Conflict detection

    /// Non-empty values, deduplicated case-insensitively (keeps the first
    /// spelling encountered).
    private func distinct(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values {
            guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty,
                  !seen.contains(v.lowercased()) else { continue }
            seen.insert(v.lowercased())
            out.append(v)
        }
        return out
    }

    private var nameOptions: [String] { distinct(candidates.map { $0.name }) }
    private var cityOptions: [String] { distinct(candidates.map { $0.city }) }
    private var countryOptions: [String] { distinct(candidates.map { $0.country }) }
    private var addressOptions: [String] { distinct(candidates.map { $0.address }) }
    private var domainOptions: [String] { distinct(candidates.map { $0.domain }) }
    private var noteOptions: [String] { distinct(candidates.map { $0.note }) }
    private var regexOptions: [String] { distinct(candidates.map { $0.regex }) }
    private var categoryOptions: [Int] { Array(Set(candidates.compactMap { $0.categoryId })) }
    private var groupOptions: [Int] { Array(Set(candidates.compactMap { $0.groupId })) }

    private var hasAnyConflict: Bool {
        nameOptions.count > 1 || cityOptions.count > 1 || countryOptions.count > 1
            || addressOptions.count > 1 || domainOptions.count > 1 || noteOptions.count > 1
            || regexOptions.count > 1 || categoryOptions.count > 1 || groupOptions.count > 1
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Fiche conservée", value: keeper.name)
                LabeledContent("Tiers fusionnés", value: "\(candidates.count)")
            } footer: {
                Text("« \(keeper.name) » a le plus de transactions (\(transactionCounts[keeper.id] ?? 0)) : c'est elle qui subsiste, avec les valeurs choisies ci-dessous. Les \(candidates.count - 1) autre\(candidates.count > 2 ? "s" : "") seront supprimée\(candidates.count > 2 ? "s" : "") après réaffectation des transactions, récurrents et remboursements. Action irréversible.")
            }

            if nameOptions.count > 1 { conflictField("Nom", value: $resolvedName, options: nameOptions) }

            if categoryOptions.count > 1 {
                Section("Catégorie") {
                    Picker("Catégorie", selection: $resolvedCategoryId) {
                        Text("Aucune").tag(Int?.none)
                        ForEach(categoryOptions, id: \.self) { id in
                            if let cat = allCategories.first(where: { $0.id == id }) {
                                Text(cat.name).tag(Int?.some(id))
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            }

            if groupOptions.count > 1 {
                Section("Groupe") {
                    Picker("Groupe", selection: $resolvedGroupId) {
                        Text("Aucun").tag(Int?.none)
                        ForEach(groupOptions, id: \.self) { id in
                            if let g = payeeGroups.first(where: { $0.id == id }) {
                                Text(g.displayName).tag(Int?.some(id))
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            }

            if cityOptions.count > 1 { conflictField("Ville", value: $resolvedCity, options: cityOptions) }
            if countryOptions.count > 1 { conflictField("Pays", value: $resolvedCountry, options: countryOptions) }
            if addressOptions.count > 1 { conflictField("Adresse", value: $resolvedAddress, options: addressOptions) }
            if domainOptions.count > 1 { conflictField("Domaine", value: $resolvedDomain, options: domainOptions) }
            if regexOptions.count > 1 { conflictField("Regex", value: $resolvedRegex, options: regexOptions) }
            if noteOptions.count > 1 { conflictField("Note", value: $resolvedNote, options: noteOptions) }

            if !hasAnyConflict {
                Section {
                    Text("Aucun champ ne diverge entre ces tiers.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .nemorisFormStyle()
        .tint(AppTheme.Colors.accent)
        // `AppLocalization.string(...)`: `paneChrome`'s `title:` is `String`,
        // and native Swift interpolation here would bake the count in and
        // permanently skip translation of "Fusionner … tiers" — same remedy
        // as the two group/payee merge pickers above.
        .paneChrome(
            AppLocalization.string("Fusionner \(candidates.count) tiers"),
            cancelLabel: "Annuler", onCancel: { dismiss() },
            confirmLabel: "Fusionner", confirmIcon: "arrow.triangle.merge",
            onConfirm: performMerge
        )
    }

    /// A conflicting text field: free entry plus chips to adopt one of the
    /// merged payees' values in a tap. Free text rather than a plain
    /// `Picker`: sometimes neither original value is the right one (e.g.
    /// merging "Carrefour Mkt" and "CARREFOUR MARKET" into "Carrefour
    /// Market").
    // `title: LocalizedStringKey`, not `String`: every call site passes a
    // literal ("Nom", "Ville"…), which converts fine either way, but INSIDE
    // this function `title` was a plain runtime `String` — `Section(title)`/
    // `TextField(title, ...)` would resolve to their verbatim overloads and
    // never localize, cf. CLAUDE.md §5.
    @ViewBuilder
    private func conflictField(_ title: LocalizedStringKey, value: Binding<String>, options: [String]) -> some View {
        Section(title) {
            TextField(title, text: value)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            value.wrappedValue = option
                        } label: {
                            Text(option)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(
                                    value.wrappedValue == option ? AppTheme.Colors.accent : AppTheme.Colors.accent.opacity(0.12),
                                    in: Capsule()
                                )
                                .foregroundStyle(value.wrappedValue == option ? .white : AppTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func performMerge() {
        var updated = keeper
        updated.name = resolvedName.isEmpty ? keeper.name : resolvedName
        updated.categoryId = resolvedCategoryId
        updated.groupId = resolvedGroupId
        updated.city = resolvedCity.isEmpty ? nil : resolvedCity
        updated.country = resolvedCountry.isEmpty ? nil : resolvedCountry
        updated.address = resolvedAddress.isEmpty ? nil : resolvedAddress
        updated.domain = resolvedDomain.isEmpty ? nil : resolvedDomain
        updated.note = resolvedNote.isEmpty ? nil : resolvedNote
        updated.regex = resolvedRegex.isEmpty ? nil : resolvedRegex
        // Internal fields not surfaced above: filled in from the other
        // candidates when the kept record has none.
        updated.engineMerchantId = keeper.engineMerchantId ?? candidates.compactMap { $0.engineMerchantId }.first
        updated.linkedCompteId   = keeper.linkedCompteId ?? candidates.compactMap { $0.linkedCompteId }.first
        updated.contactIdentifier = keeper.contactIdentifier ?? candidates.compactMap { $0.contactIdentifier }.first
        updated.custom = keeper.custom || candidates.contains { $0.custom }

        repository.updatePayeeFull(updated)
        let sourceIds = Set(candidates.map(\.id)).subtracting([keeper.id])
        repository.mergeTiers(sourceIds: sourceIds, intoId: keeper.id)
        onMerged()
        dismiss()
    }
}
