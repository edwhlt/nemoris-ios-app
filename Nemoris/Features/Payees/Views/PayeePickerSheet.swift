import SwiftUI

/// Sheet de réassignation : liste tous les payees existants, filtrable par recherche.
/// Utilisé depuis `ImportSessionView` (AXE D) et `PayeeDetailView` (AXE C) pour les
/// lignes/payees que l'utilisateur veut lier à un payee existant.
struct PayeePickerSheet: View {

    let rawLabel: String
    let onPick: (Tiers) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allPayees: [Tiers] = []
    @State private var allCategories: [Category] = []
    @State private var searchText: String = ""
    @State private var sortByRecent: Bool = false
    @State private var hasLoaded = false

    private let repository = TransactionRepository()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextHeader
                Divider()
                payeeList
            }
            .navigationTitle("Lier à un tiers existant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Rechercher dans vos tiers")
            .task {
                await Task.yield()
                loadPayees()
                hasLoaded = true
            }
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Libellé à classer")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(rawLabel)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.Colors.textSecondary.opacity(0.08))
    }

    private var filteredPayees: [Tiers] {
        let query = searchText
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allPayees }
        return allPayees.filter {
            $0.name
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
                .contains(query)
        }
    }

    private var payeeList: some View {
        Group {
            if !hasLoaded {
                List {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonCandidateRow()
                    }
                }
                .listStyle(.plain)
            } else if allPayees.isEmpty {
                ContentUnavailableView(
                    "Aucun tiers existant",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Créez d'abord un tiers depuis la liste des données de référence.")
                )
            } else if filteredPayees.isEmpty {
                ContentUnavailableView.search
            } else {
                List(filteredPayees) { payee in
                    Button {
                        onPick(payee)
                        dismiss()
                    } label: {
                        PayeeRowSummary(payee: payee, allCategories: allCategories)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func loadPayees() {
        allPayees = repository.fetchTiers()
        allCategories = repository.fetchCategories()
    }
}

private struct PayeeRowSummary: View {
    let payee: Tiers
    let allCategories: [Category]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MerchantLogo(tiers: payee, allCategories: allCategories, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(payee.name).font(.body)
                if let regex = payee.regex, !regex.isEmpty {
                    Text(regex)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }
}
