import SwiftUI

/// Payee group management (`payee_groups`): add, rename, delete, merge, and
/// review a group's payees. Distinct from `PayeeGroupPickerView`, which only
/// PICKS a group for a given payee (creating one on the fly along the way).
///
/// Rows in a `List` + `.rowActions` (iOS swipe / macOS right-click) — same
/// convention as the rest of the screen (`accountRow`, `flatCategoryRow`,
/// `tiersTabContent`) rather than icon buttons permanently visible in the
/// row.
struct PayeeGroupManagerView: View {
    @Environment(\.paneDismiss) private var dismiss
    var onChange: () -> Void = {}
    /// Closes this pane and switches the Payees tab to a group filter —
    /// "see this group's payees" is the same question `TiersFilterSheet`
    /// already knows how to ask, not a separate screen.
    var onSelectGroup: (PayeeGroup) -> Void = { _ in }

    @State private var groups: [PayeeGroup] = []
    @State private var tierCounts: [Int: Int] = [:]
    @State private var search = ""

    @State private var showCreateForm = false
    @State private var renameTarget: PayeeGroup?
    @State private var deleteTarget: PayeeGroup?
    /// A merge's source group — presents the TARGET group picker.
    @State private var mergeSource: PayeeGroup?

    private let repository = TransactionRepository()

    private var filtered: [PayeeGroup] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let q = search.lowercased()
        return groups.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                EmptyStateView(
                    icon: "rectangle.3.group",
                    title: "Aucun groupe",
                    message: "Regroupe plusieurs tiers d'une même enseigne pour les compter ensemble."
                )
                .listRowBackground(Color.clear)
            } else if filtered.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    verbatimMessage: "Aucun résultat pour « \(search) »"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filtered) { group in
                    row(for: group)
                        .macGroupedRow(first: group.id == filtered.first?.id, last: group.id == filtered.last?.id)
                }
            }
        }
        #if os(macOS)
        // Same policy as the other lists on this screen: `.plain` = neutral
        // base for the custom cards drawn by `macGroupedRow`.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .tint(AppTheme.Colors.accent)
        .paneSearchable(text: $search, prompt: "Rechercher un groupe…")
        .paneChrome(
            "Groupes de tiers",
            cancelLabel: "Fermer", onCancel: { dismiss() },
            confirmLabel: "Ajouter", confirmIcon: "plus",
            onConfirm: { showCreateForm = true }
        )
        .adaptivePane(isPresented: $showCreateForm) {
            PayeeGroupFormSheet(title: "Nouveau groupe", initialName: search.trimmingCharacters(in: .whitespaces)) { name in
                if repository.addPayeeGroup(displayName: name) != nil {
                    reload()
                    onChange()
                }
            }
        }
        .adaptivePane(item: $renameTarget) { target in
            PayeeGroupFormSheet(title: "Renommer le groupe", initialName: target.displayName) { name in
                if repository.updatePayeeGroup(id: target.id, displayName: name) {
                    reload()
                    onChange()
                }
            }
        }
        .adaptivePane(item: $mergeSource) { source in
            PayeeGroupMergeTargetPicker(source: source, otherGroups: groups.filter { $0.id != source.id }) { target in
                repository.mergePayeeGroups(sourceId: source.id, intoId: target.id)
                mergeSource = nil
                reload()
                onChange()
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let target = deleteTarget {
                    repository.deletePayeeGroup(id: target.id)
                    onChange()
                }
                deleteTarget = nil
                reload()
            }
            Button("Annuler", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
        .task { reload() }
    }

    // `LocalizedStringKey`, not `String`: built via literal interpolation so
    // the STATIC "Supprimer « » ?" wrapper stays translatable while the
    // embedded group name (raw data) is passed as an argument — cf.
    // CLAUDE.md §5. The previous `.map { ... } ?? ""` produced a plain
    // `String`, which `confirmationDialog` would show verbatim.
    private var deleteConfirmationTitle: LocalizedStringKey {
        guard let target = deleteTarget else { return "" }
        return "Supprimer « \(target.displayName) » ?"
    }

    // `LocalizedStringKey`, not `String`: `Text(deleteMessage)` would stay
    // verbatim with a `String`-typed property — cf. CLAUDE.md §5.
    //
    // Three full branches rather than one skeleton with an interpolated verb
    // conjugation ("seront"/"sera"): that fragment is a raw FRENCH WORD
    // computed at the call site, not a re-translatable lookup — substituting
    // it as a %@ argument into an English template would paste French verb
    // forms into English prose. Fully separate literals keep each branch's
    // grammar self-contained and translatable on its own.
    private var deleteMessage: LocalizedStringKey {
        guard let target = deleteTarget else { return "" }
        let count = tierCounts[target.id] ?? 0
        if count == 0 {
            return "Aucun tier n'est rattaché à ce groupe."
        } else if count == 1 {
            return "1 tier ne sera plus rattaché à aucun groupe."
        } else {
            return "\(count) tiers ne seront plus rattachés à aucun groupe."
        }
    }

    @ViewBuilder
    private func row(for group: PayeeGroup) -> some View {
        let count = tierCounts[group.id] ?? 0
        Button {
            onSelectGroup(group)
        } label: {
            HStack(spacing: 10) {
                // `engineMerchantId` is written nowhere in the app —
                // `addPayeeGroup` is never called with an engine id, so this
                // field is always `nil` in practice. A constant icon, rather
                // than a branch that never fires.
                Image(systemName: "building.2")
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 22)
                Text(group.displayName).foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                Text("\(count) tier\(count > 1 ? "s" : "")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        // Same fix as `accountRow`: without it, macOS paints its own button
        // chrome (accent-tinted) over the card already colored by
        // `macGroupedRow`.
        .buttonStyle(.plain)
        .rowActions(
            leading: [RowAction("Renommer", systemImage: "pencil", tint: AppTheme.Colors.accent) { renameTarget = group }],
            trailing: groups.count > 1
                ? [
                    RowAction("Fusionner…", systemImage: "arrow.triangle.merge", tint: AppTheme.Colors.textSecondary) { mergeSource = group },
                    RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { deleteTarget = group }
                  ]
                : [RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) { deleteTarget = group }],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }

    private func reload() {
        groups = repository.fetchPayeeGroups()
        tierCounts = repository.countPayeesByGroup()
    }
}

/// Single-field form, shared by creation AND renaming — same question
/// ("what name for this group?"), one view.
private struct PayeeGroupFormSheet: View {
    @Environment(\.paneDismiss) private var dismiss
    let title: String
    let initialName: String
    let onSave: (String) -> Void

    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            Section {
                TextField("Ex. : Carrefour", text: $name)
                    .autocorrectionDisabled()
            } footer: {
                Text("Rassemble plusieurs tiers d'une même enseigne (ex. tous les Carrefour Market).")
            }
        }
        .nemorisFormStyle()
        .tint(AppTheme.Colors.accent)
        .paneChrome(
            title,
            cancelLabel: "Annuler", onCancel: { dismiss() },
            confirmLabel: "Enregistrer", confirmIcon: "checkmark",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            onConfirm: {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onSave(trimmed)
                dismiss()
            }
        )
    }
}

/// Merge sub-screen: picks the TARGET group among the other groups. All of
/// `source`'s payees join the chosen group, then `source` is deleted. Level 2
/// (`.adaptivePane(item:)` from `PayeeGroupManagerView`, itself level 1) —
/// automatically falls back to a bounded sheet on macOS.
private struct PayeeGroupMergeTargetPicker: View {
    let source: PayeeGroup
    let otherGroups: [PayeeGroup]
    let onSelect: (PayeeGroup) -> Void

    @Environment(\.paneDismiss) private var dismiss
    @State private var search = ""

    private var filtered: [PayeeGroup] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return otherGroups }
        let q = search.lowercased()
        return otherGroups.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                EmptyStateView(
                    icon: "rectangle.3.group",
                    title: "Aucun autre groupe",
                    message: "Crée d'abord un second groupe pour pouvoir fusionner."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { g in
                        Button {
                            onSelect(g)
                        } label: {
                            HStack {
                                Image(systemName: "building.2")
                                    .foregroundStyle(AppTheme.Colors.accent)
                                Text(g.displayName).foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    // Literal interpolation (not `verbatim:`): the static
                    // wrapper prose is genuinely translatable, only the
                    // embedded group name is raw data — `verbatim:` here was
                    // an oversight that permanently pinned this footer to
                    // French, cf. CLAUDE.md §5.
                    Text("Tous les tiers de « \(source.displayName) » rejoindront le groupe choisi. « \(source.displayName) » sera supprimé.")
                }
            }
        }
        #if os(macOS)
        // On macOS, `List` paints ITS OWN system background OVER the host
        // pane's — without this modifier the user's desktop shows through.
        // Same fix as `PayeeGroupPickerView`.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .tint(AppTheme.Colors.accent)
        .paneSearchable(text: $search, prompt: "Rechercher un groupe…")
        // `paneChrome`'s `title:` param is `String` — native Swift
        // interpolation here would bake the name in and permanently skip
        // translation of "Fusionner « » ". `AppLocalization.string(...)`
        // resolves the STATIC template via `String.LocalizationValue`
        // interpolation (which preserves the %@ placeholder) BEFORE handing
        // an already-resolved string to `paneChrome` — the "chrome native"
        // remedy documented in `AppLocalization.swift`, not the plain-Text one.
        .paneChrome(AppLocalization.string("Fusionner « \(source.displayName) »"), cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
