import SwiftUI

/// Sheet for picking a brand group (`payee_groups`) for a payee. Also
/// allows creating a new group on the fly.
///
/// Used from `PayeeDetailView`.
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
                                    // `engineMerchantId`: see the comment on
                                    // `PayeeGroupManagerView.row` — always
                                    // `nil` in practice, constant icon.
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
            // On macOS, `List` paints ITS OWN system background OVER the
            // host pane's — without this modifier, the user's desktop shows
            // through.
            .scrollContentBackground(.hidden)
            // A `.frame(maxWidth: .infinity, maxHeight: .infinity)` alone
            // (greedy, merely filling the space already offered) is NOT
            // enough to stop a `List` from collapsing when this view is
            // reached through a bare `.sheet()` WITHOUT an external
            // `.adaptivePaneFrame()` (e.g. `TierUpdateSheet`,
            // `PayeeCreationFormSheet`) — macOS then computes the window
            // height from the content's "natural" size, and a `List` doesn't
            // report it reliably in that context. The NUMERIC `minHeight` is
            // what actually forces a height — same value as
            // `AdaptivePane.adaptivePaneFrame()` (`minHeight: 520`), to stay
            // consistent with the panes that get that constraint from
            // outside.
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
                // Re-injecting \.locale is mandatory for any level-2+
                // `.sheet()` reachable on macOS. Same for
                // `\.paneHostContext`: this picker can itself be hosted in
                // the macOS inspector (`.inspector`, reached via
                // `.adaptivePane` from `PayeeDetailView`) — without a reset
                // to `.modal`, `CreatePayeeGroupSheet`'s `.paneChrome` would
                // publish its buttons into the system bar instead of drawing
                // them in THIS separate window (no button visible in the
                // sheet itself).
                .environment(\.locale, AppLocalization.locale)
                .environment(\.paneHostContext, .modal)
            }
            .task { loadGroups() }
            // `.paneChrome` draws its own bars on a macOS sheet. The earlier
            // attempt (`.toolbarBackground(for: .windowToolbar)`) compiled but
            // had NO visual effect. See the `macSheetChrome` comment in
            // AdaptivePane.swift.
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
            // `.paneChrome` draws its own bars on a macOS sheet. The earlier
            // attempt (`.toolbarBackground(for: .windowToolbar)`) compiled but
            // had NO visual effect. See the `macSheetChrome` comment in
            // AdaptivePane.swift.
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
