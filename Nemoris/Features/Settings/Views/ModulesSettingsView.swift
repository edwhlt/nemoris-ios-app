import SwiftUI

// MARK: - ModulesSettingsView
//
// A single screen for the 3 questions each module raises: is it active,
// where does it appear (tab/sidebar order), does it have its own setting.
// Before this screen, these 3 questions lived in 3 different places in
// `SettingsView`'s giant Form ("Modules", the conditional
// "Investments" section, "Tab order") — the same row (a module)
// had to be edited in 3 places that had to be kept consistent.
//
// A `Form`, editMode forced on iOS only — the same recipe as
// `DashboardCustomizeView`. A short history (3 attempts):
//
// 1. Originally (before this repo): `Form` + `.onMove`, macOS
//    reordering non-functional (`.onMove` alone only truly reorders
//    inside a real `List`, backed natively by NSTableView on macOS —
//    a `Form { }.formStyle(.grouped)` looks like a list but isn't
//    one, drag does nothing there regardless of nesting).
// 2. Migrated to `List` + `.macGroupedRow` + `macReorderable` (a low-level
//    onDrag/onDrop, see `ReorderableRow.swift`) to get real macOS
//    reordering. It worked… but with a multi-second freeze on every
//    drag release, unresolved by the 2 following attempts
//    (live vs. deferred mutation, `mainTabOrder` made Observable-tracked).
// 3. What `List` on `ModulesSettingsView` (which froze) and `Form` on
//    `DashboardCustomizeView` (which never froze, and had already
//    reverted to `Form` for a purely aesthetic reason, see its own
//    history) had in common ended up pointing to the `.onDrag`/`.onDrop`
//    × `List` (NSTableView) INTERACTION itself on macOS — not to
//    the reordering logic as such, which stayed identical between the
//    two screens. Back on `Form`, the freeze has no reason to
//    recur.
//
// `macReorderable` (`ReorderableRow.swift`) stays the macOS mechanism: it's
// a generic `onDrag`/`onDrop` modifier, NOT tied to `List` — it works
// just as well on a `Form` row. `.onMove` stays wired up, reserved for iOS
// (the ☰ handle of edit mode).
//
// ⚠️ `.background(…)`, never `ZStack { Color.ignoresSafeArea(); Form }`
// (the pitfall documented in CLAUDE.md §N.1).

struct ModulesSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true
    @State private var showPaywall = false
    #if os(macOS)
    /// Module currently being dragged — see `macReorderable` (`ReorderableRow.swift`).
    @State private var draggedTab: MainTabItem?
    #endif

    /// `nil` on iOS (the `NavigationLink` that pushes this screen already
    /// provides its own native back button). On macOS, provided by the
    /// caller — see `DashboardCustomizeView.onBack`, the same doctrine: this
    /// screen REPLACES the parent's content (not a push), so `dismiss()`
    /// alone has nothing to close.
    var onBack: (() -> Void)? = nil

    /// Modules with a setting of their own beyond a plain on/off — receive a
    /// "Settings" link when they're active.
    private let configurableModules: Set<MainTabItem> = [.transactions, .investments, .budget]

    #if os(macOS)
    /// Same doctrine as `SettingsView.pushedSection`: the sub-page REPLACES
    /// the content (not a push) — this screen is itself already reached by an
    /// on macOS state replacement, a real push here would fall right back into
    /// the pitfall documented in CLAUDE.md §N.1 (a masked pane/content).
    @State private var configuredModule: MainTabItem?
    #else
    /// ⚠️ NOT a `NavigationLink` embedded in the row — `content` forces
    /// `\.editMode` to `.active` permanently (for drag&drop with no "Edit"
    /// button, see `content`'s docs) and a `List` in edit mode does NOT route
    /// a nested `NavigationLink`'s tap to its navigation (the row switches
    /// to "reorder" mode instead — the ☰ handle confirms it visually).
    /// A plain `Button`, on the other hand, stays interactive in edit mode (it's
    /// already what makes the module's `Toggle` right above it in the same
    /// row work): a push is therefore done via `@State` + `.navigationDestination(item:)`
    /// rather than relying on `NavigationLink`. The duplicated chevron had
    /// indeed been fixed, but the tap itself stayed dead.
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

    // ⚠️ `$appState.mainTabOrder` directly, NO local `@State` mirror
    // (unlike an earlier version of this screen): `mainTabOrder`
    // is a STORED property on `AppState` (the same doctrine as
    // `dashboardLayout`) — a local mirror would only delay
    // propagation by one step to the sidebar/`MainTabView`'s `.onChange`.
    private var content: some View {
        @Bindable var appState = appState
        return Form {
            Section {
                ForEach(appState.mainTabOrder) { tab in
                    row(for: tab)
                        #if os(macOS)
                        .macReorderable(tab, items: $appState.mainTabOrder, dragged: $draggedTab) {}
                        #endif
                }
                .onMove(perform: moveTab)
            } header: {
                Text("Modules")
            } footer: {
                Text("Glissez pour réordonner. Les 4 premiers s'affichent dans la barre du bas (iPhone) ; tous apparaissent dans la barre latérale (Mac/iPad). L'interrupteur active ou désactive le module.")
            }

            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    // The icon colored EXPLICITLY: a `Label` used as a `Toggle`'s
                    // label on macOS renders its icon in the system's "control"
                    // accent (blue) rather than the app's color,
                    // `.tint(...)` on the `Toggle` not propagating to it
                    // (a blue icon while every other row was in accent green). The
                    // structure is aligned with `row(for:)` below to stay
                    // visually consistent with the module list.
                    Image(systemName: "arrow.uturn.left.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 26)
                    Text("Remboursements")
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer(minLength: 0)
                    Toggle("", isOn: $reimbursementsEnabled)
                        .labelsHidden()
                        .tint(AppTheme.Colors.accent)
                        .toggleStyle(.switch)
                }
            } header: {
                Text("Autres fonctionnalités")
            } footer: {
                Text("Pas un onglet à part : ce suivi apparaît directement dans Transactions et Tricount.")
            }
        }
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Modules")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        // Same choice as `DashboardCustomizeView`: permanent edit mode
        // avoids an "Edit" button for a list whose only function that is.
        .environment(\.editMode, .constant(.active))
        #else
        // On macOS this screen REPLACES `SettingsView`'s content (not a
        // push): it's on us, not the caller, to provide the back
        // button — otherwise (see `SettingsView.settingsSectionPage`) the two
        // `.toolbar`s merge and two chevrons show up next to each
        // other.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { onBack?() } label: {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Réglages")
                .localizedAccessibilityLabel("Réglages")
            }
        }
        #endif
        .adaptivePane(isPresented: $showPaywall) {
            PaywallView().environment(store)
        }
        #if os(iOS)
        .navigationDestination(item: $pushedModuleConfig) { tab in
            moduleConfigDestination(tab)
                .localizedNavigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    // MARK: - A module's row

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
                    Text(LocalizedStringKey(tab.title))
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

                #if os(macOS)
                ReorderHandle()
                #endif
            }

            // A link to the module's own setting — only shown when it makes
            // sense (a configurable, active AND unlocked module).
            //
            // ⚠️ Manual chevron, MACOS ONLY: on iOS, `configLink` is a
            // real `NavigationLink` inside a `List`, which ALREADY adds its own
            // system chevron — even nested in a `VStack`, not only as
            // a row's direct content. Adding a second one here produced two
            // arrows AND a tap target (the manual `HStack`) narrower
            // than the actually tappable zone the system paints around
            // its own chevron — hence taps near the right edge that
            // seemed to do nothing. On macOS `configLink` is a plain `Button`, which
            // has no automatic indicator at all — the manual chevron stays
            // necessary there, the same doctrine as `SettingsView.settingsLink`.
            if configurableModules.contains(tab), isOn, !locked {
                configLink(tab) {
                    HStack {
                        (Text("Réglages de ") + Text(LocalizedStringKey(tab.title)))
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

    /// A binding to the module's `showXxx` flag, `nil` for a tab that has
    /// no switch of its own (Dashboard always active, Data following
    /// Transactions — see `AppState.availableTabsResolved`).
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

    private func fixedSubtitle(for tab: MainTabItem) -> LocalizedStringKey? {
        switch tab {
        case .dashboard:     return "Toujours actif"
        case .referenceData: return "Suit le module Transactions"
        default:              return nil
        }
    }

    // MARK: - Navigation to the settings sub-page

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
            .localizedNavigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        configuredModule = nil
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .localizedHelp("Modules")
                    .localizedAccessibilityLabel("Modules")
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
        appState.mainTabOrder.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - TransactionsModuleSettingsView

/// The default account — moved from the settings Form's old "General"
/// section, which stayed visible even when the Transactions module was
/// disabled (the setting then has no observable effect: it only
/// pre-fills `AddTransactionSheet`, import, and the Siri shortcut). Here,
/// as for Investments and Budget, access only exists if the module
/// is active.
struct TransactionsModuleSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var accounts: [Account] = []
    @State private var showAccountPicker = false
    private let repository = TransactionRepository()

    var body: some View {
        @Bindable var appState = appState
        Form {
            if !accounts.isEmpty {
                Section {
                    Button {
                        showAccountPicker = true
                    } label: {
                        HStack {
                            Text("Compte par défaut").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            // Wrap required: the fallback is a literal but
                            // the whole expression is of type `String`
                            // (coalescing with `.name`) — `Text(String)`
                            // stays verbatim without this wrap, see CLAUDE.md §5.
                            Text(LocalizedStringKey(accounts.first(where: { $0.id == appState.defaultAccountId })?.name ?? "Premier disponible"))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
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
        .localizedNavigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if DatabaseManager.shared.hasDatabase() {
                accounts = repository.fetchAccounts()
            }
        }
        .adaptivePane(isPresented: $showAccountPicker) {
            AccountSearchSheet(
                accounts: accounts,
                selectedId: appState.defaultAccountId == 0 ? nil : appState.defaultAccountId,
                title: "Compte par défaut",
                specialLabel: "Premier disponible",
                specialIcon: "sparkles"
            ) { picked in
                appState.defaultAccountId = picked?.id ?? 0
            }
        }
    }
}

// MARK: - InvestmentsModuleSettingsView

/// Settings specific to the Investments module — moved from the settings
/// Form's old conditional section (visible only when
/// `showInvestments` was active). Here access itself is already gated
/// by the active module (the link only exists if the module is).
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
        .localizedNavigationTitle("Investissements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - BudgetModuleSettingsView

/// The Budget module's alert threshold — moved from the settings Form's
/// old "Budget" section, which was (wrongly) not gated on
/// `showBudget`. Here, as for Investments, access only exists if the
/// module is active.
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
        .localizedNavigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
    }
}
