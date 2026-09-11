import SwiftUI

/// Pendant `InvestmentAccount` d'`AccountSearchSheet` — mêmes conventions
/// (recherche + `.macGroupedRow`), mais liste plate : `InvestmentAccount`
/// n'a pas d'équivalent de `AccountType`/`groupedByType`, et un utilisateur a
/// en pratique bien moins de comptes-titres que de comptes différés.
struct InvestmentAccountSearchSheet: View {
    // `\.paneDismiss`, PAS `\.dismiss` — cf. le commentaire équivalent dans
    // `AccountSearchSheet.swift` : ouverte depuis des contextes racine
    // (entonnoir d'import), cette sheet peut atterrir en niveau 1 de
    // `.adaptivePane` (inspecteur macOS, pas une vraie `.sheet`), où
    // `\.dismiss` remonte fermer la fenêtre.
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
