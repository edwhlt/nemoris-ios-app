import SwiftUI

// MARK: - ModulesSettingsView
//
// Écran unique pour les 3 questions posées par chaque module : est-il actif,
// où apparaît-il (ordre des onglets/sidebar), a-t-il un réglage propre.
// Avant cet écran, ces 3 questions vivaient à 3 endroits différents dans le
// Form géant de `SettingsView` ("Modules", section conditionnelle
// "Investissements", "Ordre des onglets") — la même ligne (un module) se
// modifiait à 3 endroits qu'il fallait garder cohérents.
//
// `List` + `.onMove`, editMode forcé sur iOS uniquement — le drag&drop de
// réordonnancement sur macOS a besoin d'une vraie `List` (backing natif type
// NSTableView) ; un `Form { }.formStyle(.grouped)` a l'air d'une liste mais
// n'en est pas une, le drag n'y fait rien quelle que soit l'imbrication (une
// hypothèse antérieure de ce commentaire, jamais vérifiée sur device,
// blâmait l'imbrication dans le Form géant de réglages — c'était le Form
// lui-même). Convention déjà en place ailleurs (ReferenceDataView,
// TransactionsView…) : `List` + `.listStyle(.plain)` sur macOS +
// `.macGroupedRow(first:last:)` par row pour les cartes arrondies que `Form`
// donnait gratuitement.
//
// ⚠️ Contrepartie : `Form(.grouped)` stylait automatiquement tout `Toggle`
// simple en switch macOS ; `List` ne le fait pas (défaut = case à cocher,
// cf. `PayeeDetailView`/`InvestmentPDFImportView` qui doivent déjà le
// préciser hors Form). D'où `.toggleStyle(.switch)` explicite ci-dessous.
//
// ⚠️ `.background(…)`, jamais `ZStack { Color.ignoresSafeArea(); List }`
// (piège documenté CLAUDE.md §N.1, à l'origine décrit pour `Form`).

struct ModulesSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true
    @State private var tabOrder: [MainTabItem] = []
    @State private var showPaywall = false

    /// `nil` sur iOS (le `NavigationLink` qui pousse cet écran fournit déjà
    /// son bouton retour natif). Sur macOS, fourni par l'appelant — cf.
    /// `DashboardCustomizeView.onBack`, même doctrine : cet écran REMPLACE le
    /// contenu du parent (pas un push), donc `dismiss()` seul n'a rien à
    /// fermer.
    var onBack: (() -> Void)? = nil

    /// Modules avec un réglage propre au-delà du simple on/off — reçoivent un
    /// lien "Réglages" quand ils sont actifs.
    private let configurableModules: Set<MainTabItem> = [.transactions, .investments, .budget]

    #if os(macOS)
    /// Même doctrine que `SettingsView.pushedSection` : la sous-page REMPLACE
    /// le contenu (pas un push) — cet écran est lui-même déjà atteint par un
    /// remplacement d'état côté macOS, un vrai push ici retomberait dans le
    /// piège documenté CLAUDE.md §N.1 (panneau/contenu masqué).
    @State private var configuredModule: MainTabItem?
    #else
    /// ⚠️ PAS un `NavigationLink` embarqué dans le row — `content` force
    /// `\.editMode` à `.active` en permanence (pour le drag&drop sans bouton
    /// "Modifier", cf. doc `content`) et un `List` en édition n'achemine PAS
    /// le tap d'un `NavigationLink` nesté vers sa navigation (le row bascule
    /// en mode "réordonner" à la place — la poignée ☰ le confirme visuellement).
    /// Un `Button` classique, lui, reste interactif en edit mode (c'est déjà
    /// ce qui fait marcher le `Toggle` du module juste au-dessus dans le même
    /// row) : on pousse donc via `@State` + `.navigationDestination(item:)`
    /// plutôt que de compter sur `NavigationLink`. retour d'usage 2026-08-12 :
    /// le chevron dupliqué était bien réparé, mais le tap restait mort.
    @State private var pushedModuleConfig: MainTabItem?
    #endif

    var body: some View {
        #if os(macOS)
        if let module = configuredModule {
            moduleConfigPage(module)
        } else {
            content
        }
        #else
        content
        #endif
    }

    // MARK: - Contenu principal

    // ⚠️ `List`, PAS `Form` : `.onMove` ne réordonne réellement qu'à l'intérieur
    // d'une vraie `List` (backing natif type NSTableView côté macOS). Le
    // `Form { }.formStyle(.grouped)` posé par `nemorisFormStyle()` a l'AIR
    // d'une liste mais n'est pas construit dessus — le drag n'y a jamais
    // d'effet, indépendamment de l'imbrication (contrairement à ce que
    // supposait un commentaire antérieur sur `DashboardCustomizeView`, jamais
    // vérifié sur device). Convention déjà en place ailleurs (ReferenceDataView,
    // TransactionsView…) : `List` + `.listStyle(.plain)` sur macOS +
    // `.macGroupedRow(first:last:)` par row pour retrouver les cartes arrondies
    // que `Form` donne gratuitement.
    private var content: some View {
        List {
            Section {
                ForEach(tabOrder) { tab in
                    row(for: tab)
                        .macGroupedRow(first: tab == tabOrder.first, last: tab == tabOrder.last)
                }
                .onMove(perform: moveTab)
            } header: {
                Text("Modules")
                    .macGroupedSectionHeader()
            } footer: {
                Text("Glissez pour réordonner. Les 4 premiers s'affichent dans la barre du bas (iPhone) ; tous apparaissent dans la barre latérale (Mac/iPad). L'interrupteur active ou désactive le module.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .macGroupedSectionHeader()
            }

            Section {
                Toggle(isOn: $reimbursementsEnabled) {
                    Label("Remboursements", systemImage: "arrow.uturn.left.circle")
                }
                .tint(AppTheme.Colors.accent)
                .toggleStyle(.switch)
                .macGroupedRow()
            } header: {
                Text("Autres fonctionnalités")
                    .macGroupedSectionHeader()
            } footer: {
                Text("Pas un onglet à part : ce suivi apparaît directement dans Transactions et Tricount.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .macGroupedSectionHeader()
            }
        }
        #if os(macOS)
        // .plain = base neutre pour les cartes custom dessinées par
        // macGroupedRow. contentMargins décolle la 1ʳᵉ carte de la toolbar
        // (iOS insetGrouped ajoute cet espace automatiquement, pas .plain) —
        // même recette que TransactionsView/PatrimoineView.
        .listStyle(.plain)
        .contentMargins(.top, AppTheme.Spacing.md, for: .scrollContent)
        #endif
        .scrollContentBackground(.hidden)
        .tint(AppTheme.Colors.accent)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Modules")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        // editMode n'existe pas sur macOS — le drag&drop de réordonnancement
        // marche nativement sur Mac sans mode édition (cf. DashboardCustomizeView).
        .environment(\.editMode, .constant(.active))
        #else
        // Sur macOS cet écran REMPLACE le contenu de `SettingsView` (pas un
        // push) : c'est nous, pas l'appelant, qui devons fournir le bouton
        // retour — sinon (cf. `SettingsView.settingsSectionPage`) les deux
        // `.toolbar` fusionnent et deux chevrons s'affichent l'un à côté de
        // l'autre.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { onBack?() } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Réglages")
                .accessibilityLabel("Réglages")
            }
        }
        #endif
        .onAppear { tabOrder = appState.mainTabOrder }
        .adaptivePane(isPresented: $showPaywall) {
            PaywallView().environment(store)
        }
        #if os(iOS)
        .navigationDestination(item: $pushedModuleConfig) { tab in
            moduleConfigDestination(tab)
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    // MARK: - Ligne d'un module

    @ViewBuilder
    private func row(for tab: MainTabItem) -> some View {
        let toggleBinding = flagBinding(for: tab)
        let isOn = toggleBinding?.wrappedValue ?? true
        let locked = tab.paywallFeature.map { !store.isUnlocked($0) } ?? false

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if let subtitle = fixedSubtitle(for: tab) {
                        Text(subtitle)
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                if let toggleBinding {
                    if locked {
                        Button { showPaywall = true } label: { ProBadge() }
                            .buttonStyle(.plain)
                    } else {
                        Toggle("", isOn: toggleBinding)
                            .labelsHidden()
                            .tint(AppTheme.Colors.accent)
                            .toggleStyle(.switch)
                            .onChange(of: toggleBinding.wrappedValue) { _, _ in
                                HapticService.shared.toggle()
                            }
                    }
                }
            }

            // Lien vers le réglage propre du module — seulement quand il a du
            // sens (module configurable ET actif ET débloqué).
            //
            // ⚠️ Chevron manuel MACOS UNIQUEMENT : sur iOS, `configLink` est un
            // vrai `NavigationLink` dans une `List`, qui ajoute DÉJÀ son propre
            // chevron système — même nesté dans un `VStack`, pas seulement en
            // contenu direct de row. En ajouter un second ici produisait deux
            // flèches ET un tap-target étroit (le `HStack` manuel) plus petit
            // que la zone réellement tappable que le système peint autour de
            // son chevron — d'où les taps qui semblaient ne rien faire près du
            // bord droit. Sur macOS `configLink` est un simple `Button`, qui
            // n'a aucune indication automatique — le chevron manuel y reste
            // nécessaire, même doctrine que `SettingsView.settingsLink`.
            if configurableModules.contains(tab), isOn, !locked {
                configLink(tab) {
                    HStack {
                        Text("Réglages de \(tab.title)")
                            .font(AppTheme.Typography.labelMedium)
                        Spacer()
                        #if os(macOS)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                        #endif
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.leading, 26 + AppTheme.Spacing.md)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isOn ? 1 : 0.7)
    }

    /// Binding vers le flag `showXxx` du module, `nil` pour un onglet qui n'a
    /// pas d'interrupteur propre (Dashboard toujours actif, Données qui suit
    /// Transactions — cf. `AppState.availableTabsResolved`).
    private func flagBinding(for tab: MainTabItem) -> Binding<Bool>? {
        switch tab {
        case .transactions: return Binding(get: { appState.showTransactions }, set: { appState.showTransactions = $0 })
        case .tricount:     return Binding(get: { appState.showTricount }, set: { appState.showTricount = $0 })
        case .investments:  return Binding(get: { appState.showInvestments }, set: { appState.showInvestments = $0 })
        case .budget:       return Binding(get: { appState.showBudget }, set: { appState.showBudget = $0 })
        case .patrimoine:   return Binding(get: { appState.showPatrimoine }, set: { appState.showPatrimoine = $0 })
        case .sqlConsole:   return Binding(get: { appState.showSQLConsole }, set: { appState.showSQLConsole = $0 })
        case .dashboard, .referenceData: return nil
        }
    }

    private func fixedSubtitle(for tab: MainTabItem) -> String? {
        switch tab {
        case .dashboard:     return "Toujours actif"
        case .referenceData: return "Suit le module Transactions"
        default:              return nil
        }
    }

    // MARK: - Navigation vers la sous-page de réglages

    @ViewBuilder
    private func configLink(_ tab: MainTabItem, @ViewBuilder label: () -> some View) -> some View {
        #if os(macOS)
        Button { configuredModule = tab } label: { label() }
            .buttonStyle(.plain)
        #else
        Button { pushedModuleConfig = tab } label: { label() }
            .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func moduleConfigPage(_ tab: MainTabItem) -> some View {
        moduleConfigDestination(tab)
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        configuredModule = nil
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Modules")
                    .accessibilityLabel("Modules")
                }
            }
    }
    #endif

    @ViewBuilder
    private func moduleConfigDestination(_ tab: MainTabItem) -> some View {
        switch tab {
        case .transactions: TransactionsModuleSettingsView()
        case .investments:  InvestmentsModuleSettingsView()
        case .budget:        BudgetModuleSettingsView()
        default:              EmptyView()
        }
    }

    // MARK: - Mutations

    private func moveTab(from source: IndexSet, to destination: Int) {
        tabOrder.move(fromOffsets: source, toOffset: destination)
        appState.mainTabOrder = tabOrder
    }
}

// MARK: - TransactionsModuleSettingsView

/// Compte par défaut — déplacé depuis l'ancienne section "Général" du Form de
/// réglages, qui restait visible même quand le module Transactions était
/// désactivé (le réglage n'a alors aucun effet observable : il ne fait que
/// pré-remplir `AddTransactionSheet`, l'import et le raccourci Siri). Ici,
/// comme pour Investissements et Budget, l'accès n'existe que si le module
/// est actif.
struct TransactionsModuleSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var accounts: [Account] = []
    private let repository = TransactionRepository()

    var body: some View {
        @Bindable var appState = appState
        Form {
            if !accounts.isEmpty {
                Section {
                    Picker("Compte par défaut", selection: $appState.defaultAccountId) {
                        Text("Premier disponible").tag(0)
                        ForEach(accounts.groupedByType, id: \.type) { group in
                            Section(group.type.label) {
                                ForEach(group.accounts) { a in
                                    Text(a.name).tag(a.id)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Utilisé pour pré-remplir une nouvelle transaction (ajout manuel, import, raccourci).")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if DatabaseManager.shared.hasDatabase() {
                accounts = repository.fetchAccounts()
            }
        }
    }
}

// MARK: - InvestmentsModuleSettingsView

/// Réglages propres au module Investissements — déplacés depuis l'ancienne
/// section conditionnelle du Form de réglages (visible seulement quand
/// `showInvestments` était actif). Ici l'accès lui-même est déjà conditionné
/// par le module actif (le lien n'existe que si le module l'est).
struct InvestmentsModuleSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                Toggle(isOn: $appState.investmentsIncludeCashInTotal) {
                    Label("Inclure la trésorerie dans la valorisation", systemImage: "eurosign.circle")
                }
                .tint(AppTheme.Colors.accent)
                Toggle(isOn: $appState.investmentsAutoSyncEnabled) {
                    Label("Synchronisation automatique des cours", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(AppTheme.Colors.accent)
            } footer: {
                Text("Si activé, la trésorerie (cash disponible) est ajoutée au gros chiffre de valorisation. Le calcul de performance reste basé uniquement sur les positions, peu importe ce réglage. La synchronisation automatique actualise portefeuilles et cours à l'ouverture de l'app ou du module, au plus toutes les 4 heures.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Investissements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - BudgetModuleSettingsView

/// Seuil d'alerte du module Budget — déplacé depuis l'ancienne section
/// "Budget" du Form de réglages, qui n'était (à tort) pas conditionnée sur
/// `showBudget`. Ici, comme pour Investissements, l'accès n'existe que si le
/// module est actif.
struct BudgetModuleSettingsView: View {
    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct = 20.0

    var body: some View {
        Form {
            Section {
                Stepper(value: $budgetRedOverPct, in: 0...100, step: 5) {
                    HStack {
                        Label("Seuil rouge budget", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Spacer()
                        Text("+\(Int(budgetRedOverPct)) %")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .font(.subheadline)
                    }
                }
            } footer: {
                Text("Orange de 0 % à +\(Int(budgetRedOverPct)) % de dépassement, rouge au-delà.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
    }
}
