import SwiftUI

/// Sheet de sélection d'un groupe de marque (`payee_groups`) pour un payee.
/// Permet aussi de créer un nouveau groupe à la volée.
///
/// utilisé depuis `PayeeDetailView`.
struct PayeeGroupPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let currentGroupId: Int?
    let onSelect: (PayeeGroup?) -> Void  // nil = "Aucun groupe"

    @State private var groups: [PayeeGroup] = []
    @State private var search: String = ""
    @State private var showCreateForm = false

    private let repository = TransactionRepository()

    private var filtered: [PayeeGroup] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let q = search.lowercased()
        return groups.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "minus.circle").foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("Aucun groupe").foregroundStyle(AppTheme.Colors.textPrimary)
                        Spacer()
                        if currentGroupId == nil {
                            Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                }

                if !filtered.isEmpty {
                    Section("Groupes existants") {
                        ForEach(filtered) { g in
                            Button {
                                onSelect(g)
                                dismiss()
                            } label: {
                                HStack {
                                    // `engineMerchantId` : cf. commentaire de
                                    // `PayeeGroupManagerView.row` — toujours
                                    // `nil` en pratique, icône constante.
                                    Image(systemName: "building.2")
                                        .foregroundStyle(AppTheme.Colors.accent)
                                    Text(g.displayName).foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    if currentGroupId == g.id {
                                        Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            #if os(macOS)
            // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS
            // celui du panneau hôte — sans ce modificateur, le bureau de
            // l'utilisateur transparaît (retour d'usage 2026-08-19).
            .scrollContentBackground(.hidden)
            // ⚠️ Vérifié en direct (2026-08-26) sur `ImportActionsHelpSheet` :
            // un `.frame(maxWidth: .infinity, maxHeight: .infinity)` seul
            // (« greedy », qui ne fait que remplir l'espace déjà offert) NE
            // SUFFIT PAS à empêcher un `List` de s'effondrer quand cette vue
            // est atteinte via un `.sheet()` brut SANS `.adaptivePaneFrame()`
            // externe (ex. `TierUpdateSheet`, `PayeeCreationFormSheet`) —
            // macOS calcule alors la hauteur de la fenêtre depuis la taille
            // "naturelle" du contenu, et un `List` ne la reporte pas de façon
            // fiable dans ce contexte. Le `minHeight` NUMÉRIQUE est ce qui
            // force réellement une hauteur — même valeur que
            // `AdaptivePane.adaptivePaneFrame()` (`minHeight: 520`), pour
            // rester cohérent avec les panes qui, eux, obtiennent cette
            // contrainte de l'extérieur.
            .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            #endif
            .paneSearchable(text: $search, prompt: "Rechercher un groupe…")
            .sheet(isPresented: $showCreateForm) {
                CreatePayeeGroupSheet(prefilledName: search.trimmingCharacters(in: .whitespaces)) { name in
                    if let id = repository.addPayeeGroup(displayName: name) {
                        let created = PayeeGroup(id: id, displayName: name, engineMerchantId: nil, custom: true)
                        groups.append(created)
                        groups.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                        onSelect(created)
                        dismiss()
                    }
                }
                // Cf. CLAUDE.md §5 : ré-injection \.locale obligatoire pour toute
                // `.sheet()` niveau 2+ atteignable sur macOS. `\.paneHostContext`
                // itou : ce picker peut lui-même être hébergé dans l'inspecteur
                // macOS (`.inspector`, atteint via `.adaptivePane` depuis
                // `PayeeDetailView`) — sans reset à `.modal`, le `.paneChrome`
                // de `CreatePayeeGroupSheet` publierait ses boutons dans la
                // barre système au lieu de les dessiner dans CETTE fenêtre
                // séparée (aucun bouton visible dans le sheet lui-même).
                .environment(\.locale, AppLocalization.locale)
                .environment(\.paneHostContext, .modal)
            }
            .task { loadGroups() }
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // tentative précédente (`.toolbarBackground(for: .windowToolbar)`)
            // compilait mais n'avait AUCUN effet visuel, confirmé par capture
            // d'écran en direct (retour d'usage 2026-08-21). Cf. le
            // commentaire de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome(
                "Groupe de marque",
                cancelLabel: "Annuler", onCancel: { dismiss() },
                confirmLabel: "Créer", confirmIcon: "plus",
                onConfirm: { showCreateForm = true }
            )
    }

    private func loadGroups() {
        groups = repository.fetchPayeeGroups()
    }
}

private struct CreatePayeeGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prefilledName: String
    let onCreate: (String) -> Void

    @State private var name: String

    init(prefilledName: String, onCreate: @escaping (String) -> Void) {
        self.prefilledName = prefilledName
        self.onCreate = onCreate
        _name = State(initialValue: prefilledName)
    }

    var body: some View {
            Form {
                Section {
                    TextField("Ex. : Carrefour", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Rassemble plusieurs tiers de la même enseigne (ex. tous les Carrefour Market).")
                }
            }
            .nemorisFormStyle()
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // tentative précédente (`.toolbarBackground(for: .windowToolbar)`)
            // compilait mais n'avait AUCUN effet visuel, confirmé par capture
            // d'écran en direct (retour d'usage 2026-08-21). Cf. le
            // commentaire de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome(
                "Nouveau groupe",
                cancelLabel: "Annuler", onCancel: { dismiss() },
                confirmLabel: "Créer",
                confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                onConfirm: {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                }
            )
    }
}
