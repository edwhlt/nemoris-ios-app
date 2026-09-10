import SwiftUI

/// Gestion des groupes de tiers (`payee_groups`) : ajouter, renommer,
/// supprimer, fusionner, et consulter les tiers d'un groupe. Distinct de
/// `PayeeGroupPickerView`, qui ne fait que CHOISIR un groupe pour un tiers
/// donné (et créer à la volée au passage).
///
/// Rows en `List` + `.rowActions` (swipe iOS / clic droit macOS) — même
/// convention que le reste de l'écran (`accountRow`, `flatCategoryRow`,
/// `tiersTabContent`) plutôt que des boutons icône toujours visibles dans la
/// row (retour d'usage : "quelque chose de plus natif").
struct PayeeGroupManagerView: View {
    @Environment(\.paneDismiss) private var dismiss
    var onChange: () -> Void = {}
    /// Ferme ce panneau et bascule l'onglet Tiers sur un filtre par groupe —
    /// "voir la liste des tiers de ce groupe" est la même question que le
    /// filtre `TiersFilterSheet` sait déjà poser, pas un écran séparé.
    var onSelectGroup: (PayeeGroup) -> Void = { _ in }

    @State private var groups: [PayeeGroup] = []
    @State private var tierCounts: [Int: Int] = [:]
    @State private var search = ""

    @State private var showCreateForm = false
    @State private var renameTarget: PayeeGroup?
    @State private var deleteTarget: PayeeGroup?
    /// Groupe source d'une fusion — présente le picker de groupe CIBLE.
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
        // Même politique que les autres listes de cet écran : `.plain` = base
        // neutre pour les cartes custom dessinées par `macGroupedRow`.
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
            deleteTarget.map { "Supprimer « \($0.displayName) » ?" } ?? "",
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

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let count = tierCounts[target.id] ?? 0
        guard count > 0 else { return "Aucun tier n'est rattaché à ce groupe." }
        return "\(count) tier\(count > 1 ? "s" : "") ne \(count > 1 ? "seront" : "sera") plus rattaché\(count > 1 ? "s" : "") à aucun groupe."
    }

    @ViewBuilder
    private func row(for group: PayeeGroup) -> some View {
        let count = tierCounts[group.id] ?? 0
        Button {
            onSelectGroup(group)
        } label: {
            HStack(spacing: 10) {
                // ⚠️ `engineMerchantId` n'est écrit nulle part dans l'app —
                // `addPayeeGroup` n'est jamais appelé avec un id moteur, ce
                // champ est toujours `nil` en pratique aujourd'hui (retour
                // d'usage : "est-ce vraiment utile ?"). Icône constante,
                // plutôt qu'une branche qui ne se déclenche jamais.
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
        // Même correctif que `accountRow` : sans lui, macOS applique son
        // propre chrome de bouton (teinté accent) par-dessus la carte déjà
        // colorée par `macGroupedRow`.
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

/// Formulaire à un champ, partagé par la création ET le renommage — même
/// question ("quel nom pour ce groupe ?"), une seule vue.
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

/// Sous-écran de fusion : choisit le groupe CIBLE parmi les autres groupes.
/// Tous les tiers de `source` rejoignent le groupe choisi, puis `source` est
/// supprimé. Niveau 2 (`.adaptivePane(item:)` depuis `PayeeGroupManagerView`,
/// elle-même niveau 1) — bascule automatiquement en sheet bornée sur macOS.
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
                    Text(verbatim: "Tous les tiers de « \(source.displayName) » rejoindront le groupe choisi. « \(source.displayName) » sera supprimé.")
                }
            }
        }
        #if os(macOS)
        // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS celui du
        // panneau hôte — sans ce modificateur, le bureau de l'utilisateur
        // transparaît. Même correctif que `PayeeGroupPickerView`.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .tint(AppTheme.Colors.accent)
        .paneSearchable(text: $search, prompt: "Rechercher un groupe…")
        .paneChrome("Fusionner « \(source.displayName) »", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
