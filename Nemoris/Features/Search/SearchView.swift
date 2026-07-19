import SwiftUI

// MARK: - SearchView
//
// Sheet "Spotlight" cross-modules — accessible via le bouton loupe du toolbar
// Dashboard. Pattern cmd-K macOS : TextField focused au launch, résultats
// groupés par catégorie, tap = dismiss + navigation contextuelle.
//
// **Debounce 250 ms** : on évite de spammer le SearchService à chaque keystroke.
// 250 ms est le sweet-spot iOS standard (Apple Mail, Notes utilisent ~200-300 ms).
//
// **Navigation** : tap sur un résultat → dismiss + bascule sur l'onglet
// approprié via `appState.selectedTab`. Pour MVP on ne deep-link pas dans la
// fiche exacte (ex : on ouvre l'onglet Transactions mais pas la TransactionEditSheet
// du tx précis) — ça nécessiterait un mécanisme de routing global qui sort du
// scope. L'user voit la liste filtrable directement.

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching: Bool = false
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var queryFieldFocused: Bool

    /// Résultats groupés par catégorie pour le rendu — préserve l'ordre des
    /// catégories de `SearchService` (transactions → tiers → … → goals).
    private var grouped: [(SearchCategory, [SearchResult])] {
        var byCat: [SearchCategory: [SearchResult]] = [:]
        for r in results {
            byCat[r.category, default: []].append(r)
        }
        return SearchCategory.allCases.compactMap { cat in
            guard let items = byCat[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)
                        .padding(.bottom, AppTheme.Spacing.md)

                    if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        emptyHint
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if results.isEmpty && !isSearching {
                        noResults
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(grouped, id: \.0) { (cat, items) in
                                Section {
                                    ForEach(items) { result in
                                        resultRow(result)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 4,
                                                                      leading: AppTheme.Spacing.lg,
                                                                      bottom: 4,
                                                                      trailing: AppTheme.Spacing.lg))
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                navigate(to: result)
                                            }
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Image(systemName: cat.systemIcon)
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(cat.label)
                                            .font(.system(size: 11, weight: .semibold))
                                            .tracking(0.8)
                                    }
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                    .textCase(nil)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(AppTheme.Colors.background)
                    }
                }
            }
            .navigationTitle("Rechercher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear {
                // ⚠️ Pas d'auto-focus sur Mac (Designed for iPad) : le focus
                // programmatique traverse UIScreen dans la couche de compat
                // iOS-sur-Mac → NSInternalInconsistencyException ("Accessing
                // the focus system through UIScreen is no longer supported").
                // Sur Mac l'user clique dans le champ — AppKit gère.
                if !ProcessInfo.processInfo.isiOSAppOnMac {
                    queryFieldFocused = true
                }
            }
        }
    }

    // MARK: - Search bar

    @ViewBuilder private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            TextField("Transaction, tiers, objectif, compte…", text: $query)
                .focused($queryFieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    // MARK: - Empty states

    @ViewBuilder private var emptyHint: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
            Text("Tapez au moins 2 caractères")
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text("La recherche couvre vos transactions, tiers, comptes, catégories, objectifs et éléments du patrimoine.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xxl)
        }
    }

    @ViewBuilder private var noResults: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
            Text("Aucun résultat")
                .font(AppTheme.Typography.titleSmall)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("Aucune correspondance pour « \(query) »")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Result row

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            iconView(for: result)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: result))
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                if let sub = subtitle(for: result) {
                    Text(sub)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let trailing = trailing(for: result) {
                trailing
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    /// Tuple (icon, color) extrait via fonction pure pour ne pas mélanger des
    /// statements dans un @ViewBuilder (qui n'accepte que des Views).
    private func iconStyle(for result: SearchResult) -> (icon: String, color: Color) {
        switch result {
        case .transaction:  return ("creditcard.fill",        AppTheme.Colors.accent)
        case .payee:        return ("person.crop.circle.fill", AppTheme.Colors.accentSecondary)
        case .account:      return ("building.columns.fill",  AppTheme.Colors.accent)
        case .category:     return ("tag.fill",               AppTheme.Colors.accent)
        case .tag:          return ("number",                 AppTheme.Colors.accentSecondary)
        case .asset:        return ("banknote.fill",          AppTheme.Colors.success)
        case .loan:         return ("creditcard.fill",        AppTheme.Colors.danger)
        case .realEstate:   return ("house.fill",             AppTheme.Colors.accentSecondary)
        case .goal:         return ("target",                 AppTheme.Colors.accent)
        }
    }

    @ViewBuilder
    private func iconView(for result: SearchResult) -> some View {
        let style = iconStyle(for: result)
        Image(systemName: style.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(style.color)
            .frame(width: 34, height: 34)
            .background(style.color.opacity(0.13), in: Circle())
    }

    private func title(for result: SearchResult) -> String {
        switch result {
        case .transaction(let t): return t.tiersName.isEmpty ? t.information : t.tiersName
        case .payee(let p):       return p.name
        case .account(let a):     return a.name
        case .category(let c):    return c.name
        case .tag(let t):         return t.name
        case .asset(let a):       return a.name
        case .loan(let l):        return l.name
        case .realEstate(let r):  return r.name
        case .goal(let g):        return g.name
        }
    }

    private func subtitle(for result: SearchResult) -> String? {
        switch result {
        case .transaction(let t):
            let date = t.date.formatted(.dateTime.day().month(.abbreviated).year())
            return "\(date) · \(t.categoryName.isEmpty ? "Sans catégorie" : t.categoryName)"
        case .payee(let p):       return p.city ?? p.address
        case .account(let a):     return a.accountType.label
        case .category:           return nil
        case .tag:                return nil
        case .asset(let a):       return a.assetKind.label
        case .loan(let l):        return l.loanType.label
        case .realEstate(let r):  return r.address
        case .goal(let g):        return g.kind.label
        }
    }

    @ViewBuilder
    private func trailing(for result: SearchResult) -> AnyView? {
        switch result {
        case .transaction(let t):
            return AnyView(MoneyText(
                amount: t.amount,
                font: AppTheme.Typography.titleSmall,
                color: t.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success
            ))
        case .asset(let a):
            return AnyView(MoneyText(
                amount: a.lastKnownValue,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textPrimary
            ))
        case .loan(let l):
            return AnyView(MoneyText(
                amount: l.principal,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.danger
            ))
        case .realEstate(let r):
            return AnyView(MoneyText(
                amount: r.currentValue,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textPrimary
            ))
        case .goal(let g):
            return AnyView(MoneyText(
                amount: g.targetAmount,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textSecondary
            ))
        default:
            return nil
        }
    }

    // MARK: - Search execution

    private func scheduleSearch(_ newValue: String) {
        debounceTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        debounceTask = Task { @MainActor in
            // 250 ms debounce — sweet-spot iOS standard pour search-as-you-type.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            // Recherche HORS main thread : elle recharge toute la base — sur
            // Mac, la faire sur le main actor gelait l'UI dès que le moteur
            // de sync écrivait en parallèle (fix freezes 2026-07-17).
            let r = await Task.detached(priority: .userInitiated) {
                SearchService.shared.search(trimmed)
            }.value
            guard !Task.isCancelled else { return }
            results = r
            isSearching = false
        }
    }

    // MARK: - Navigation

    /// Dismiss la sheet + bascule sur l'onglet contextuel. Pour MVP on n'ouvre
    /// pas la fiche exacte (deep-link complexe avec les nav stacks isolés) —
    /// l'user voit l'écran approprié et trouve son résultat facilement.
    private func navigate(to result: SearchResult) {
        switch result {
        case .transaction, .payee, .account, .category, .tag:
            appState.navigateToTab(.transactions)
        case .asset, .loan, .realEstate, .goal:
            appState.navigateToTab(.patrimoine)
        }
        dismiss()
    }
}
