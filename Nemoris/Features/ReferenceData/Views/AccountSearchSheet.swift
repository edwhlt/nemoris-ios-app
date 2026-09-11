import SwiftUI

/// Sheet de sélection d'un compte bancaire, filtrable par recherche — remplace
/// les `Picker` plats devenus illisibles avec beaucoup de comptes différés
/// (un par mois de CB, cf. retour user). Même gabarit que `TiersSearchSheet`/
/// `PayeePickerSheet` : `List` + `.paneSearchable` + `.macGroupedRow`.
///
/// Callback plutôt que `Binding<Int>` : certains appelants ont un effet de
/// bord à poser en plus de l'id (ex. `AppState.selectedAccountName` dans
/// `TransactionFiltersSheet`) — `onPick` leur laisse la main plutôt que de
/// baker cette logique ici.
struct AccountSearchSheet: View {
    // `\.paneDismiss`, PAS `\.dismiss` : cette sheet est ouverte depuis des
    // contextes racine (Réglages, entonnoir d'import sur desktop) où elle
    // atterrit en NIVEAU 1 de `.adaptivePane` (inspecteur macOS — pas une
    // vraie `.sheet`). `\.dismiss` n'y trouve alors aucune présentation
    // locale à fermer et remonte fermer LA FENÊTRE (retour d'usage
    // 2026-09-10 : "Fermer" fermait l'app depuis le sélecteur de compte de
    // l'import et du compte par défaut). `\.paneDismiss` est injecté par
    // `.adaptivePane` dans les deux cas (inspecteur ET sheet), cf. le
    // contrat documenté en tête d'`AdaptivePane.swift`.
    @Environment(\.paneDismiss) private var dismiss

    let accounts: [Account]
    /// Id actuellement sélectionné, pour la coche — `nil` si aucun ou si la
    /// ligne spéciale est active.
    var selectedId: Int? = nil
    var title: String = "Choisir un compte"
    /// Ligne fixe en tête de liste (ex. "Tous les comptes", "Aucun",
    /// "Premier disponible") — jamais filtrée par la recherche. `onPick(nil)`
    /// est appelé si elle est tapée. `nil` = pas de ligne spéciale.
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
                        // `specialLabel` est une `String` d'exécution, pas un
                        // littéral : `Text(specialLabel)` resterait verbatim
                        // (jamais localisé) sans ce wrap explicite — cf.
                        // `Text(LocalizedStringKey(group.type.label))`
                        // juste plus bas dans ce même fichier.
                        Text(LocalizedStringKey(specialLabel))
                        Spacer()
                        if selectedId == nil {
                            Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .buttonStyle(.plain)
                // Toujours `last: true` : contrairement à `TiersSearchSheet`/
                // `RemboursementQuickPickSheet` (où la ligne spéciale et le
                // `ForEach` qui suit forment UNE seule carte continue, sans
                // rupture visuelle), ici les comptes qui suivent sont dans
                // un `Section` avec un HEADER (le nom du groupe de comptes)
                // — la continuité de carte est déjà rompue par ce header.
                // `last: groups.isEmpty` faisait tomber le bas de cette ligne
                // à angles droits dès qu'un compte existait, comme si elle
                // se poursuivait dans la section suivante alors qu'aucune
                // carte ne les relie réellement (retour d'usage macOS
                // 2026-09-11, capture à l'appui : bord bas non arrondi collé
                // au header "Checking"). Même raison que le `last: true`
                // fixe de `CategoryQuickPickSheet.noneRow`, suivi lui aussi
                // d'une structure qui n'est pas une carte continue (un arbre).
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
