import SwiftUI

/// `InvestmentAccount` counterpart of `AccountSearchSheet` — same conventions
/// (search + `.macGroupedRow`), but a flat list: `InvestmentAccount` has no
/// equivalent of `AccountType`/`groupedByType`, and in practice a user has
/// far fewer brokerage accounts than deferred-debit accounts.
struct InvestmentAccountSearchSheet: View {
    // `\.paneDismiss`, NOT `\.dismiss` — see the matching comment in
    // `AccountSearchSheet.swift`: opened from root contexts (the import
    // funnel), this sheet can land at level 1 of `.adaptivePane` (the macOS
    // inspector, not a real `.sheet`), where `\.dismiss` walks up and closes
    // the window.
    @Environment(\.paneDismiss) private var dismiss

    let accounts: [InvestmentAccount]
    var selectedId: Int? = nil
    var title: String = "Choisir un compte"
    let onPick: (InvestmentAccount) -> Void

    @State private var search = ""

    private var filteredAccounts: [InvestmentAccount] {
        guard !search.isEmpty else { return accounts }
        return accounts.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.broker.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if accounts.isEmpty {
                EmptyStateView(
                    icon: "chart.pie",
                    title: "Aucun compte",
                    message: "Créez d'abord un compte d'investissement."
                )
            } else if filteredAccounts.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    verbatimMessage: "Aucun résultat pour « \(search) »"
                )
            } else {
                ForEach(filteredAccounts) { a in
                    accountRow(a)
                        .macGroupedRow(first: a.id == filteredAccounts.first?.id, last: a.id == filteredAccounts.last?.id)
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

    private func accountRow(_ a: InvestmentAccount) -> some View {
        Button {
            onPick(a)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(a.broker).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                if selectedId == a.id {
                    Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
