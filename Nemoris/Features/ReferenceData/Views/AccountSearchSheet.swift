import SwiftUI

/// Sheet for picking a bank account, filterable by search — replaces the
/// flat `Picker`s that became unreadable with many deferred-debit accounts
/// (one per credit-card month). Same template as `TiersSearchSheet`/
/// `PayeePickerSheet`: `List` + `.paneSearchable` + `.macGroupedRow`.
///
/// A callback rather than `Binding<Int>`: some callers have a side
/// effect to apply besides the id (e.g. `AppState.selectedAccountName` in
/// `TransactionFiltersSheet`) — `onPick` leaves that to them instead of
/// baking that logic in here.
struct AccountSearchSheet: View {
    // `\.paneDismiss`, NOT `\.dismiss`: this sheet is opened from root
    // contexts (Settings, the desktop import funnel) where it
    // lands at LEVEL 1 of `.adaptivePane` (the macOS inspector — not a
    // real `.sheet`). `\.dismiss` then finds no local
    // presentation to close and bubbles up to close THE WINDOW ("Close"
    // used to close the whole app from the account picker of import
    // and of the default account). `\.paneDismiss` is injected by
    // `.adaptivePane` in both cases (inspector AND sheet), see the
    // contract documented at the top of `AdaptivePane.swift`.
    @Environment(\.paneDismiss) private var dismiss

    let accounts: [Account]
    /// Currently selected id, for the checkmark — `nil` if none or if the
    /// special row is active.
    var selectedId: Int? = nil
    var title: String = "Choisir un compte"
    /// A fixed row at the top of the list (e.g. "All accounts", "None",
    /// "First available") — never filtered by search. `onPick(nil)`
    /// is called if it's tapped. `nil` = no special row.
    var specialLabel: String? = nil
    var specialIcon: String = "rectangle.stack.fill"
    let onPick: (Account?) -> Void

    @State private var search = ""

    private var filteredAccounts: [Account] {
        guard !search.isEmpty else { return accounts }
        return accounts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var groups: [(type: AccountType, accounts: [Account])] {
        filteredAccounts.groupedByType
    }

    var body: some View {
        List {
            if let specialLabel {
                Button {
                    onPick(nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: specialIcon)
                        // `specialLabel` is a runtime `String`, not a
                        // literal: `Text(specialLabel)` would stay verbatim
                        // (never localized) without this explicit wrap — see
                        // `Text(LocalizedStringKey(group.type.label))`
                        // further down in this same file.
                        Text(LocalizedStringKey(specialLabel))
                        Spacer()
                        if selectedId == nil {
                            Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .buttonStyle(.plain)
                // Always `last: true`: unlike `TiersSearchSheet`/
                // `RemboursementQuickPickSheet` (where the special row and the
                // following `ForEach` form ONE continuous card, with no
                // visual break), here the accounts that follow sit in
                // a `Section` with a HEADER (the account group's name)
                // — card continuity is already broken by that header.
                // `last: groups.isEmpty` made this row's bottom edge
                // square as soon as an account existed, as if it
                // continued into the next section even though no
                // card actually connects them. Same reason as the
                // fixed `last: true` on `CategoryQuickPickSheet.noneRow`, also
                // followed by a structure that isn't a continuous card (a tree).
                .macGroupedRow(first: true, last: true)
            }

            if accounts.isEmpty {
                EmptyStateView(
                    icon: "building.columns",
                    title: "Aucun compte",
                    message: "Créez d'abord un compte depuis Données."
                )
            } else if filteredAccounts.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    verbatimMessage: "Aucun résultat pour « \(search) »"
                )
            } else {
                ForEach(groups, id: \.type) { group in
                    Section {
                        ForEach(group.accounts) { a in
                            accountRow(a)
                                .macGroupedRow(first: a.id == group.accounts.first?.id, last: a.id == group.accounts.last?.id)
                        }
                    } header: {
                        Text(LocalizedStringKey(group.type.label))
                            .macGroupedSectionHeader()
                    }
                    .listSectionSeparator(.hidden)
                    .listRowSeparator(.hidden)
                }
            }
        }
        #if os(macOS)
        .listStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #endif
        .macGroupedListTopGap()
        .scrollContentBackground(.hidden)
        .paneSearchable(text: $search, prompt: "Rechercher un compte…")
        .paneChrome(title, cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    private func accountRow(_ a: Account) -> some View {
        Button {
            onPick(a)
            dismiss()
        } label: {
            HStack {
                Text(a.name).foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                if selectedId == a.id {
                    Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
