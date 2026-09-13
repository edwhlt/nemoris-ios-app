import SwiftUI

// MARK: - SearchView
//
// A cross-module "Spotlight" sheet — reachable via the Dashboard toolbar's
// magnifying-glass button, and via the macOS sidebar's magnifying-glass button. A
// macOS cmd-K pattern: a focused TextField at launch, results grouped by category,
// a tap = dismiss + contextual navigation.
//
// **Two searches merged HERE**: DATA (`SearchService`,
// transactions/payees/accounts/…/investments/budget/Tricount) AND
// FEATURES/screens (`FeatureCatalog`, a "FEATURES" section at the top
// of the results — "where is X"). Before, this 2nd mechanism only existed in
// `MainTabView.MoreView` (the "More" feature's search, iOS
// only) — macOS therefore had no way to find "where is Budget"
// through search. The two catalogs stay separate files
// (data vs. features have neither the same scoring, nor the same source, nor the
// same cost — SQL vs. an in-memory filter) but share the same screen.
//
// **A 250ms debounce** (DATA only): avoids spamming
// SearchService on every keystroke. 250ms is the standard iOS sweet spot
// (Apple Mail, Notes use ~200-300ms). The FEATURES results,
// on the other hand, are a synchronous filter over a handful of in-memory entries — no
// debounce needed, no I/O to protect.
//
// **Navigation**: tapping a result → dismiss + switches to the
// appropriate tab via `appState.selectedTab`. For the MVP, no deep link into the
// exact sheet (e.g. the Transactions tab opens but not the specific
// transaction's TransactionEditSheet) — that would require a global
// routing mechanism, out of scope. The user sees the filterable list directly.

struct SearchView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching: Bool = false
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var queryFieldFocused: Bool

    /// Results grouped by category for rendering — preserves `SearchService`'s
    /// category order (transactions → payees → … → goals).
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

    /// "Where is X" — the MODULES/screens matching the query, not the
    /// data they contain (see `FeatureCatalog`). A synchronous computation,
    /// no debounce: it's a plain filter over an in-memory list of
    /// a few entries, no I/O — unlike `SearchService.search`.
    ///
    /// `.settings` excluded: see `FeatureCatalog.FeatureTarget`'s docs — no
    /// generic hook to open Settings from a view presented as a
    /// sheet/pane from anywhere.
    private var featureMatches: [FeatureEntry] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return FeatureCatalog.matching(query, in: appState).filter {
            if case .settings = $0.target { return false }
            return true
        }
    }

    var body: some View {
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
                    } else if results.isEmpty && featureMatches.isEmpty && !isSearching {
                        noResults
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            // "Where is X" — matching modules/screens, before
                            // data: that's often WHAT's being looked for on a
                            // short query ("budget", "sql").
                            if !featureMatches.isEmpty {
                                Section {
                                    ForEach(featureMatches) { entry in
                                        featureRow(entry)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 4,
                                                                      leading: AppTheme.Spacing.lg,
                                                                      bottom: 4,
                                                                      trailing: AppTheme.Spacing.lg))
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                navigate(to: entry.target)
                                            }
                                    }
                                } header: {
                                    sectionHeader(icon: "square.grid.2x2", label: "FONCTIONNALITÉS")
                                }
                            }
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
                                    sectionHeader(icon: cat.systemIcon, label: cat.label)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(AppTheme.Colors.background)
                    }
                }
            }
            .onAppear {
                // ⚠️ No auto-focus on Mac (Designed for iPad): programmatic
                // focus goes through UIScreen in the iOS-on-Mac
                // compatibility layer → an NSInternalInconsistencyException ("Accessing
                // the focus system through UIScreen is no longer supported").
                // On Mac the user clicks into the field — AppKit handles it.
                if !ProcessInfo.processInfo.isiOSAppOnMac {
                    queryFieldFocused = true
                }
            }
            .paneChrome("Rechercher", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    // MARK: - Search bar

    @ViewBuilder private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            TextField("Transaction, tiers, budget, investissement…", text: $query)
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
            Text("La recherche couvre vos transactions, tiers, comptes, catégories, objectifs, patrimoine, investissements, budget et Tricount.")
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

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
        }
        .foregroundStyle(AppTheme.Colors.textSecondary)
        .textCase(nil)
    }

    // MARK: - Feature row ("where is X")

    @ViewBuilder
    private func featureRow(_ entry: FeatureEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(entry.color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: entry.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(entry.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(entry.title))
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(LocalizedStringKey(entry.description))
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
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
                    sub
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

    /// A (icon, color) tuple extracted via a pure function, so as not to mix
    /// statements into a @ViewBuilder (which only accepts Views).
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
        case .investmentAccount:  return ("building.columns.fill",     AppTheme.Colors.accent)
        case .investmentPosition: return ("chart.line.uptrend.xyaxis", AppTheme.Colors.success)
        case .budgetEnvelope:     return ("chart.pie.fill",            AppTheme.Colors.warning)
        case .recurringPattern:   return ("arrow.triangle.2.circlepath", AppTheme.Colors.warning)
        case .tricountGroup:      return ("person.2.fill",             AppTheme.Colors.accent)
        case .tricountEntry:      return ("receipt.fill",              AppTheme.Colors.accentSecondary)
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
        case .investmentAccount(let a):  return a.name
        case .investmentPosition(let p): return p.assetName.isEmpty ? p.ticker : p.assetName
        case .budgetEnvelope(let e):     return e.name
        case .recurringPattern(let p):   return p.name
        case .tricountGroup(let g):      return g.title
        case .tricountEntry(let e):      return e.description.isEmpty ? e.whoPaid : e.description
        }
    }

    private func subtitle(for result: SearchResult) -> Text? {
        switch result {
        case .transaction(let t):
            let date = t.date.formatted(.dateTime.day().month(.abbreviated).year().locale(appState.locale))
            let categoryLabel: Text = t.categoryName.isEmpty ? Text("Sans catégorie") : Text(t.categoryName)
            return Text("\(date) · ") + categoryLabel
        case .payee(let p):       return (p.city ?? p.address).map { Text($0) }
        case .account(let a):     return Text(LocalizedStringKey(a.accountType.label))
        case .category:           return nil
        case .tag:                return nil
        case .asset(let a):       return Text(LocalizedStringKey(a.assetKind.label))
        case .loan(let l):        return Text(LocalizedStringKey(l.loanType.label))
        case .realEstate(let r):  return r.address.map { Text($0) }
        case .goal(let g):        return Text(LocalizedStringKey(g.kind.label))
        case .investmentAccount(let a):  return Text(a.broker)
        case .investmentPosition(let p): return p.ticker.isEmpty ? nil : Text(p.ticker)
        case .budgetEnvelope(let e):     return Text(LocalizedStringKey(e.period.label))
        case .recurringPattern(let p):   return Text(LocalizedStringKey(p.frequency.label))
        case .tricountGroup(let g):      return Text("\(g.entryCount) dépense\(g.entryCount > 1 ? "s" : "")")
        case .tricountEntry(let e):      return Text("Payé par \(e.whoPaid)")
        }
    }

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
        case .investmentAccount(let a):
            return AnyView(MoneyText(
                amount: a.totalValuation,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textPrimary
            ))
        case .investmentPosition(let p):
            return AnyView(MoneyText(
                amount: p.currentValue,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textPrimary
            ))
        case .budgetEnvelope(let e):
            return AnyView(MoneyText(
                amount: e.amount,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textSecondary
            ))
        case .recurringPattern(let p):
            return AnyView(MoneyText(
                amount: p.amountAvg,
                font: AppTheme.Typography.titleSmall,
                color: p.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success
            ))
        case .tricountEntry(let e):
            return AnyView(MoneyText(
                amount: e.total,
                font: AppTheme.Typography.titleSmall,
                color: AppTheme.Colors.textPrimary
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
        // ⚠️ Captured HERE (the main actor): `AppState` isn't `Sendable`, these
        // 3 value `Bool`s are — this is what lets `search()` run
        // off the main thread with no touching of `appState` from that thread.
        let showInvestments = appState.showInvestments
        let showBudget = appState.showBudget
        let showTricount = appState.showTricount
        debounceTask = Task { @MainActor in
            // A 250ms debounce — the standard iOS sweet spot for search-as-you-type.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            // A search OFF the main thread: it reloads the whole database — on
            // Mac, running it on the main actor used to freeze the UI as soon as the
            // sync engine wrote in parallel (a fix from 2026-07-17).
            let r = await Task.detached(priority: .userInitiated) {
                SearchService.shared.search(trimmed,
                                             showInvestments: showInvestments,
                                             showBudget: showBudget,
                                             showTricount: showTricount)
            }.value
            guard !Task.isCancelled else { return }
            results = r
            isSearching = false
        }
    }

    // MARK: - Navigation

    /// Dismisses the sheet + switches to the contextual tab. For the MVP the
    /// exact sheet isn't opened (a complex deep link with isolated nav stacks) —
    /// the user sees the right screen and finds their result easily.
    private func navigate(to result: SearchResult) {
        switch result {
        case .transaction, .payee, .account, .category, .tag:
            appState.navigateToTab(.transactions)
        case .asset, .loan, .realEstate, .goal:
            appState.navigateToTab(.patrimoine)
        case .investmentAccount, .investmentPosition:
            appState.navigateToTab(.investments)
        case .budgetEnvelope, .recurringPattern:
            appState.navigateToTab(.budget)
        case .tricountGroup, .tricountEntry:
            appState.navigateToTab(.tricount)
        }
        dismiss()
    }

    /// A "Features" result — the same dismiss, a different target. `.settings`
    /// never reaches this point (filtered out by `featureMatches`), but the switch
    /// stays exhaustive so that adding a future `FeatureTarget` case breaks the
    /// build here rather than silently doing nothing.
    private func navigate(to target: FeatureTarget) {
        switch target {
        case .tab(let tab):
            appState.navigateToTab(tab)
        case .importCSV:
            appState.openImportTool(destination: .transactions)
        case .settings:
            break
        }
        dismiss()
    }
}
