import SwiftUI

/// Sheet de réassignation : liste tous les payees existants, filtrable par recherche.
/// Utilisé depuis `ImportSessionView` et `PayeeDetailView` pour les
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
            VStack(spacing: 0) {
                contextHeader
                Divider()
                payeeList
            }
            #if os(macOS)
            // Sans frame explicite, un `List` nesté dans un VStack (par
            // opposition à un `Form` racine, cf. nemorisFormStyle()) prend
            // sa taille intrinsèque quand la vue est présentée en `.sheet`
            // sur macOS — le popup apparaît quasi vide.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .paneSearchable(text: $searchText, prompt: "Rechercher dans vos tiers")
            // `.paneChrome` dessine ses propres barres sur macOS-sheet et
            // fournit son propre fond — la tentative précédente
            // (`.toolbarBackground(for: .windowToolbar)`) compilait mais
            // n'avait AUCUN effet visuel, confirmé par capture d'écran en
            // direct (retour d'usage 2026-08-21). Cf. le commentaire de
            // `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome("Lier à un tiers existant", cancelLabel: "Annuler", onCancel: { dismiss() })
            .task {
                await Task.yield()
                loadPayees()
                hasLoaded = true
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
                .macGroupedListTopGap()
            } else if allPayees.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Aucun tiers existant",
                    message: "Créez d'abord un tiers depuis la liste des données de référence."
                )
            } else if filteredPayees.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    message: "Aucun tiers ne correspond à votre recherche."
                )
            } else {
                List(filteredPayees) { payee in
                    Button {
                        onPick(payee)
                        dismiss()
                    } label: {
                        PayeeRowSummary(payee: payee, allCategories: allCategories)
                    }
                    .buttonStyle(.plain)
                    .macGroupedRow(first: payee.id == filteredPayees.first?.id, last: payee.id == filteredPayees.last?.id)
                }
                .listStyle(.plain)
                .macGroupedListTopGap()
            }
        }
        #if os(macOS)
        // Un `List` sans hauteur idéale explicite, nesté dans un VStack
        // (donc pas racine d'un NavigationStack), se voit attribuer une
        // hauteur idéale quasi nulle par AppKit — même avec un
        // `maxHeight: .infinity` en amont sur le conteneur, ça ne force que
        // la borne haute, pas la taille de départ. D'où les rows invisibles
        // malgré un popup correctement dimensionné.
        .frame(minHeight: 320, maxHeight: .infinity)
        // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS le
        // `.background()` posé sur le VStack parent — sans ce modificateur
        // (propagé aux deux List du Group ci-dessus), le fond de l'app est
        // invisible et le bureau de l'utilisateur transparaît. Cf.
        // `TagSummaryView` (retour d'usage 2026-08-19).
        .scrollContentBackground(.hidden)
        #endif
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
