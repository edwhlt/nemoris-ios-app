import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showCancelImportConfirm = false
    private let moreTag = "more"
    /// Entrées "Outils" propres à la sidebar (pas des MainTabItem).
    private let sidebarImportTag = "sidebar_import"
    private let sidebarSettingsTag = "sidebar_settings"

    /// AXE M — layout desktop : sidebar sur Mac et iPad en paysage, où une
    /// tab bar iPhone dépareille dans une grande fenêtre. iPhone (et iPad
    /// compact / Split View étroit) garde la TabView.
    private var useSidebar: Bool {
        #if os(macOS)
        return true   // AXE N : Mac natif = toujours la sidebar
        #else
        return UIDevice.current.userInterfaceIdiom == .pad && hSizeClass == .regular
        #endif
    }

    var body: some View {
        @Bindable var state = appState
        // Banner en haut (style iOS "appel en cours") — n'interfère plus avec la tab bar.
        // VStack { banner; layout } : le layout garde sa hauteur réelle.
        return VStack(spacing: 0) {
            if let summary = appState.activeImportSession {
                ImportSessionBanner(
                    summary: summary,
                    onTap: { appState.showImportSessionSheet = true },
                    onCancel: { showCancelImportConfirm = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if useSidebar {
                sidebarLayout
            } else {
                tabLayout
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState.activeImportSession?.id)
        .appToast($state.currentToast)
        .sheet(isPresented: $state.showImportSessionSheet) {
            if let summary = appState.activeImportSession {
                NavigationStack {
                    ImportSessionView(sessionId: summary.id)
                }
            }
        }
        .confirmationDialog(
            "Annuler la session d'import ?",
            isPresented: $showCancelImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Annuler la session", role: .destructive) {
                if let id = appState.activeImportSession?.id {
                    ImportSessionRepository().deleteSession(id: id)
                    ImportNotificationService.cancelReminder(forSessionId: id)
                    appState.activeImportSession = nil
                }
            }
            Button("Continuer l'import", role: .cancel) {}
        } message: {
            Text("Les lignes non encore importées seront perdues.")
        }
        .onAppear {
            ensureValidSelection()
            appState.reloadActiveImportSession()
        }
        .onChange(of: appState.mainTabOrder)    { _, _ in ensureValidSelection() }
        .onChange(of: appState.showTricount)    { _, _ in ensureValidSelection() }
        .onChange(of: appState.showInvestments) { _, _ in ensureValidSelection() }
        .onChange(of: appState.showBudget)      { _, _ in ensureValidSelection() }
        .onChange(of: appState.showPatrimoine)  { _, _ in ensureValidSelection() }
        .onChange(of: appState.showSQLConsole)  { _, _ in ensureValidSelection() }
        // Bascule tab bar ↔ sidebar (rotation iPad, resize fenêtre Mac) + capte
        // les navigateToTab(...) → "more" quand la sidebar n'a pas d'onglet Plus.
        .onChange(of: hSizeClass) { _, _ in ensureValidSelection() }
        .onChange(of: appState.selectedTab) { _, _ in
            if useSidebar { ensureValidSelection() }
        }
    }

    // MARK: - Layouts

    /// Layout iPhone : TabView 4 onglets + Plus (comportement historique).
    private var tabLayout: some View {
        @Bindable var state = appState
        return TabView(selection: $state.selectedTab) {
            ForEach(visibleTabs) { tab in
                tabView(for: tab)
                    .tabItem {
                        // Si total slots (visibles + Plus) > 4 → icon only,
                        // sinon label + icon comme avant. iOS tab bar gère
                        // automatiquement le centrage des icônes seules.
                        if iconOnlyMode {
                            Image(systemName: tab.systemImage)
                        } else {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                    .tag(tab.rawValue)
            }

            MoreView(orderedHiddenTabs: hiddenTabs)
                .tabItem {
                    if iconOnlyMode {
                        Image(systemName: "ellipsis.circle")
                    } else {
                        Label("Plus", systemImage: "ellipsis.circle")
                    }
                }
                .tag(moreTag)
        }
        .tint(AppTheme.Colors.accent)
    }

    /// Layout desktop (AXE M) : sidebar avec TOUS les modules (pas de limite
    /// à 4, pas d'onglet Plus) + section Outils. Chaque module garde sa propre
    /// NavigationStack dans le volet détail.
    private var sidebarLayout: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            List(selection: Binding<String?>(
                get: { state.selectedTab },
                set: { if let value = $0 { state.selectedTab = value } }
            )) {
                Section("Modules") {
                    ForEach(availableTabs) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab.rawValue)
                    }
                }
                Section("Outils") {
                    Label("Importer un CSV", systemImage: "square.and.arrow.down")
                        .tag(sidebarImportTag)
                    Label("Réglages", systemImage: "gearshape")
                        .tag(sidebarSettingsTag)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Nemoris")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailView(for: state.selectedTab)
        }
        .tint(AppTheme.Colors.accent)
    }

    @ViewBuilder
    private func detailView(for selection: String) -> some View {
        if selection == sidebarSettingsTag {
            NavigationStack { SettingsView(isEmbedded: true) }
        } else if selection == sidebarImportTag {
            NavigationStack { ImportV3EntryView() }
        } else if let tab = MainTabItem(rawValue: selection) {
            tabView(for: tab)
        } else {
            // Sélection transitoire invalide ("more" pendant la bascule) —
            // ensureValidSelection corrige juste après.
            tabView(for: .dashboard)
        }
    }

    private var availableTabs: [MainTabItem] {
        appState.mainTabOrder.filter { tab in
            if tab == .tricount    { return appState.showTricount }
            if tab == .investments { return appState.showInvestments }
            if tab == .budget      { return appState.showBudget }
            if tab == .patrimoine  { return appState.showPatrimoine }
            if tab == .sqlConsole  { return appState.showSQLConsole }
            return true
        }
    }

    /// Max 4 onglets visibles avant le bouton "Plus" (iOS tab bar tolère 5 slots
    /// total = 4 visibles + Plus). Le mode icon-only se déclenche dès qu'on dépasse
    /// 4 slots, donc à partir de 4 visibles + Plus (= 5).
    private var visibleTabs: [MainTabItem] { Array(availableTabs.prefix(4)) }
    private var hiddenTabs: [MainTabItem]  { Array(availableTabs.dropFirst(4)) }

    /// True si total slots dans la tab bar > 4 → masquer les labels (icon only)
    /// pour éviter le crowding. visibleTabs.count + 1 (slot Plus toujours présent).
    private var iconOnlyMode: Bool {
        visibleTabs.count + 1 > 4
    }

    private func ensureValidSelection() {
        if useSidebar {
            // Pas d'onglet "Plus" en sidebar : une navigation cross-tab qui y
            // visait un onglet caché (navigateToTab → "more" + pending) est
            // redirigée vers l'onglet cible directement.
            if appState.selectedTab == moreTag {
                appState.selectedTab = appState.pendingMoreDestination?.rawValue
                    ?? availableTabs.first?.rawValue
                    ?? MainTabItem.dashboard.rawValue
                appState.pendingMoreDestination = nil
                return
            }
            let allowed = Set(availableTabs.map(\.rawValue) + [sidebarImportTag, sidebarSettingsTag])
            if !allowed.contains(appState.selectedTab) {
                appState.selectedTab = availableTabs.first?.rawValue ?? MainTabItem.dashboard.rawValue
            }
        } else {
            let allowed = Set(visibleTabs.map(\.rawValue) + [moreTag])
            if !allowed.contains(appState.selectedTab) {
                appState.selectedTab = visibleTabs.first?.rawValue ?? moreTag
            }
        }
    }

    @ViewBuilder
    private func tabView(for tab: MainTabItem) -> some View {
        switch tab {
        case .dashboard:    DashboardView()
        case .transactions: TransactionsView()
        case .investments:  InvestmentsView()
        case .patrimoine:   PatrimoineView()
        case .tricount:     TricountListView()
        case .budget:       BudgetView()
        case .referenceData: ReferenceDataView()
        case .sqlConsole:   NavigationStack { SQLFilesListView() }
        }
    }
}

// MARK: - MoreView

private struct MoreView: View {
    @Environment(AppState.self) private var appState
    let orderedHiddenTabs: [MainTabItem]
    @State private var searchText = ""
    /// Path de navigation contrôlé. Sert à push programmatiquement quand l'user
    /// arrive ici via `appState.pendingMoreDestination` (ex : bandeau Patrimoine
    /// sur le Dashboard).
    @State private var navPath: [MainTabItem] = []

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.lg) {
                        if searchText.isEmpty {
                            if !orderedHiddenTabs.isEmpty {
                                moreSection(
                                    title: "Onglets",
                                    items: orderedHiddenTabs.map { tab in
                                        MoreItem(
                                            label: tab.title,
                                            icon: tab.systemImage,
                                            color: AppTheme.Colors.accent,
                                            destination: { AnyView(destinationView(for: tab)) }
                                        )
                                    }
                                )
                            }
                            moreSection(
                                title: "Outils",
                                items: toolItems
                            )
                        } else {
                            featureSearchResults
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.sm)
                    .padding(.bottom, AppTheme.Spacing.xxxl)
                }
            }
            .navigationTitle("Plus")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Rechercher une fonctionnalité…")
            // Destination programmatique : consommée par MoreView quand une
            // autre View pousse `appState.pendingMoreDestination` (ex : tap sur
            // le bandeau Patrimoine du Dashboard alors que Patrimoine est dans
            // les onglets cachés).
            .navigationDestination(for: MainTabItem.self) { tab in
                destinationView(for: tab)
            }
            .onChange(of: appState.pendingMoreDestination) { _, newValue in
                guard let tab = newValue else { return }
                // On reset le path avant de pousser pour ne pas empiler si la
                // destination était déjà ouverte (l'user fait 2 fois la navigation).
                navPath = [tab]
                // Consommé → clear pour ne pas re-push à chaque rebuild.
                appState.pendingMoreDestination = nil
            }
            .onAppear {
                // Cas où l'user atteint MoreView avec une destination déjà pending
                // (helper appelé avant que MoreView soit instancié).
                if let pending = appState.pendingMoreDestination {
                    navPath = [pending]
                    appState.pendingMoreDestination = nil
                }
            }
        }
    }

    // MARK: - Tool items

    private var toolItems: [MoreItem] {
        var items = [
            MoreItem(
                label: "Import CSV",
                icon: "square.and.arrow.down",
                color: AppTheme.Colors.success,
                destination: { AnyView(ImportV3EntryView()) }
            ),
            MoreItem(
                label: "Paramètres",
                icon: "gearshape.fill",
                color: AppTheme.Colors.textSecondary,
                destination: { AnyView(SettingsView(isEmbedded: true)) }
            )
        ]
        #if DEBUG
        items.insert(
            MoreItem(
                label: "Rapport fiscal Binance",
                icon: "doc.text.magnifyingglass",
                color: AppTheme.Colors.warning,
                destination: { AnyView(BinanceTaxView()) }
            ),
            at: 1
        )
        #endif
        return items
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func moreSection(title: String, items: [MoreItem]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title.uppercased())
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    NavigationLink(destination: item.destination()) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(item.color.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: item.icon)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(item.color)
                            }
                            Text(item.label)
                                .font(AppTheme.Typography.bodyMedium)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .background(AppTheme.Colors.surface)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Colors.surfaceSecondary)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .softShadow()
        }
    }

    @ViewBuilder
    private func destinationView(for tab: MainTabItem) -> some View {
        switch tab {
        case .dashboard:    DashboardView(isEmbedded: true)
        case .transactions: TransactionsView(isEmbedded: true)
        case .investments:  InvestmentsView(isEmbedded: true)
        case .patrimoine:   PatrimoineView(isEmbedded: true)
        case .tricount:     TricountListView(isEmbedded: true)
        case .budget:       BudgetView(isEmbedded: true)
        case .referenceData: ReferenceDataView(isEmbedded: true)
        case .sqlConsole:   SQLFilesListView()  // déjà push via NavigationLink (parent NavigationStack)
        }
    }

    // MARK: - Feature Search

    private var featureEntries: [FeatureEntry] {
        var entries: [FeatureEntry] = [
            FeatureEntry(
                title: "Dashboard",
                description: "Vue annuelle de vos revenus, dépenses et répartition par catégorie.",
                icon: MainTabItem.dashboard.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["graphique", "bilan", "statistiques", "recettes", "dépenses", "année", "catégorie", "résumé"],
                target: .tab(.dashboard)
            ),
            FeatureEntry(
                title: "Transactions",
                description: "Historique complet de vos opérations bancaires. Filtrez par catégorie, tiers ou montant.",
                icon: MainTabItem.transactions.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["liste", "historique", "opérations", "banque", "filtrer", "recherche", "tiers", "solde", "chercher"],
                target: .tab(.transactions)
            ),
            FeatureEntry(
                title: "Import CSV",
                description: "Importez un relevé de compte bancaire au format CSV pour alimenter l'application.",
                icon: "square.and.arrow.down",
                color: AppTheme.Colors.success,
                keywords: ["importer", "relevé", "banque", "fichier", "csv", "charger", "données", "démarrage", "ajouter"],
                target: .importCSV
            ),
            FeatureEntry(
                title: "Données de référence",
                description: "Gérez vos tiers, catégories et moyens de paiement utilisés lors de l'import.",
                icon: MainTabItem.referenceData.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["tiers", "catégorie", "moyen de paiement", "regex", "fournisseur", "référentiel", "compte", "règle"],
                target: .tab(.referenceData)
            ),
            FeatureEntry(
                title: "Paramètres",
                description: "Configurez l'application : thème, langue, sauvegarde et base de données.",
                icon: "gearshape.fill",
                color: AppTheme.Colors.textSecondary,
                keywords: ["réglages", "configuration", "thème", "langue", "sauvegarde", "exporter", "base de données", "couleur"],
                target: .settings
            ),
        ]
        if appState.showInvestments {
            entries.append(FeatureEntry(
                title: "Investissements",
                description: "Consulter vos investissements, planifier vos investissements et suivre vos rendements.",
                icon: MainTabItem.investments.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["investir", "investissement", "actifs", "valeur", "taux de rendement", "retour", "gain"],
                target: .tab(.investments)
            ))
        }
        if appState.showPatrimoine {
            entries.append(FeatureEntry(
                title: "Patrimoine",
                description: "Consulter et gérer votre patrimoine, en incluant actifs financiers et personnels.",
                icon: MainTabItem.patrimoine.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["actifs", "valeur", "taux de rendement", "retour", "gain"],
                target: .tab(.patrimoine)
            ))
        }
        if appState.showBudget {
            entries.append(FeatureEntry(
                title: "Budget",
                description: "Définissez des enveloppes budgétaires par catégorie et suivez vos dépenses en temps réel.",
                icon: MainTabItem.budget.systemImage,
                color: AppTheme.Colors.warning,
                keywords: ["enveloppe", "limite", "prévision", "plafond", "mensuel", "contrôle", "objectif"],
                target: .tab(.budget)
            ))
        }
        if appState.showTricount {
            entries.append(FeatureEntry(
                title: "Tricount",
                description: "Gérez les dépenses partagées en groupe et calculez qui doit rembourser qui.",
                icon: MainTabItem.tricount.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["partage", "groupe", "remboursement", "partager", "dépenses communes", "équité"],
                target: .tab(.tricount)
            ))
        }
        if appState.showSQLConsole {
            entries.append(FeatureEntry(
                title: "Console SQL",
                description: "Exécutez des requêtes SQL directes sur votre base de données. Assistant IA disponible.",
                icon: MainTabItem.sqlConsole.systemImage,
                color: AppTheme.Colors.textSecondary,
                keywords: ["sql", "requête", "base", "données", "schéma", "query", "console", "avancé"],
                target: .tab(.sqlConsole)
            ))
        }
        return entries
    }

    private func filteredFeatures() -> [FeatureEntry] {
        let q = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return featureEntries }
        return featureEntries.filter { entry in
            let corpus = ([entry.title, entry.description] + entry.keywords).joined(separator: " ").lowercased()
            return q.components(separatedBy: " ").filter { !$0.isEmpty }.allSatisfy { corpus.contains($0) }
        }
    }

    @ViewBuilder private var featureSearchResults: some View {
        let results = filteredFeatures()
        if results.isEmpty {
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Aucun résultat")
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Essayez un autre mot-clé.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                    featureResultRow(entry)
                    if index < results.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Colors.surfaceSecondary)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .softShadow()
        }
    }

    @ViewBuilder private func featureResultRow(_ entry: FeatureEntry) -> some View {
        switch entry.target {
        case .tab(let tab):
            Button {
                appState.selectedTab = tab.rawValue
                searchText = ""
            } label: {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        case .importCSV:
            NavigationLink(destination: ImportV3EntryView()) {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        case .settings:
            NavigationLink(destination: SettingsView(isEmbedded: true)) {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        }
    }

    private func featureRowLabel(_ entry: FeatureEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(entry.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: entry.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(entry.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(entry.description)
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface)
    }
}

// MARK: - MoreItem model

private struct MoreItem {
    let label: String
    let icon: String
    let color: Color
    let destination: () -> AnyView
}

// MARK: - Feature search models

private enum FeatureTarget {
    case tab(MainTabItem)
    case importCSV
    case settings
}

private struct FeatureEntry: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color
    let keywords: [String]
    let target: FeatureTarget
}
