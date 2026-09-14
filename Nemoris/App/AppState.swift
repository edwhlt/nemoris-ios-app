import Foundation
import SwiftUI
import Observation

enum MainTabItem: String, CaseIterable, Identifiable {
    case dashboard
    case transactions
    case investments
    case patrimoine
    case tricount
    case budget
    case referenceData
    case sqlConsole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:    return "Dashboard"
        case .transactions: return "Transactions"
        case .investments:  return "Investissements"
        case .patrimoine:   return "Patrimoine"
        case .tricount:     return "Tricount"
        case .budget:       return "Budget"
        case .referenceData: return "Données"
        case .sqlConsole:   return "SQL"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:    return "chart.pie"
        case .transactions: return "list.bullet.rectangle"
        case .investments:  return "chart.line.uptrend.xyaxis"
        case .patrimoine:   return "house"
        case .tricount:     return "person.2"
        case .budget:       return "chart.bar"
        case .referenceData: return "square.grid.2x2"
        case .sqlConsole:   return "terminal"
        }
    }

    /// Paid feature that locks this ENTIRE module, if applicable. `nil` = free
    /// access as soon as the Settings toggle is on (Transactions, Patrimoine,
    /// Investments, Tricount, Reference Data — only their advanced layer stays
    /// Pro, gated separately in the relevant view: `.investmentsLiveSync`,
    /// `.patrimoineProjection`, `.filteredDashboard`).
    /// Single source shared by the paywall (`paywallOverlay`/`proToggle`) and
    /// Dashboard card availability (`AppState.isDashboardCardAvailable`) — the
    /// two must never diverge on "which module is paid".
    var paywallFeature: AppFeature? {
        switch self {
        case .budget:      return .budget
        case .sqlConsole:  return .sqlConsole
        default:           return nil
        }
    }
}

@Observable
final class AppState {
    /// Tags for the desktop sidebar (macOS/iPad) "Tools" entries — these are
    /// NOT `MainTabItem` values. Single source reused by `MainTabView`
    /// (sidebar rendering) and any call site that routes to these
    /// destinations (e.g. the Dashboard settings button on Mac). Avoids a
    /// duplicated literal.
    static let sidebarImportTag = "sidebar_import"
    static let sidebarSettingsTag = "sidebar_settings"

    var selectedTab: String = MainTabItem.dashboard.rawValue
    var selectedAccountId: Int? = nil
    var selectedAccountName: String = ""
    /// A payee name to inject into `TransactionsView`'s "Payee" filter
    /// on the next load — written by `ReferenceDataView` (a payee's sheet's
    /// "View transactions" button), consumed then reset to
    /// `nil` by `TransactionsView.loadInitialData()`.
    var pendingPayeeFilterName: String? = nil
    var filterFromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var filterToDate: Date = Date()
    var importStatus: String = "Aucun import lance"
    var dataRefreshToken: UUID = UUID()

    /// Active import session (lightweight summary). Drives the "Import in
    /// progress" banner in MainTabView and the tap to resume.
    var activeImportSession: ImportSessionSummary? = nil

    /// UI toggle: true when the user has requested to see ImportSessionView
    /// from the banner. MainTabView observes this flag to present the sheet.
    var showImportSessionSheet: Bool = false

    /// Global toast shown at the top of the app via the `.appToast(_:)`
    /// modifier. Setter helper: `postToast(.success, "Text")`.
    var currentToast: AppToastMessage? = nil

    /// Posts a global toast. Auto-dismisses after 3 s.
    func postToast(_ kind: AppToastKind, _ text: String) {
        currentToast = AppToastMessage(kind: kind, text: text)
    }

    /// Refreshes `activeImportSession` from the DB. Call at app launch and
    /// after any action that can change the state (create, commit, cancel).
    /// `@MainActor`: also reloads the import coordinator, which is main-actor.
    @MainActor
    func reloadActiveImportSession() {
        let summary = ImportSessionRepository().fetchActiveSummary()
        activeImportSession = summary
        // An INVESTMENTS session must be reloaded into the coordinator HERE,
        // not when the review screen opens: that screen captures the result
        // into a `@State` at init, so a restore performed afterward would
        // have no visible effect.
        if let summary, summary.destination == .investments,
           DocumentImportCoordinator.shared.batch.isEmpty {
            DocumentImportCoordinator.shared.restore(sessionId: summary.id)
        }
    }

    // Persisted: "system" | "light" | "dark"
    var colorSchemeRaw: String = UserDefaults.standard.string(forKey: "appColorScheme") ?? "system" {
        didSet { UserDefaults.standard.set(colorSchemeRaw, forKey: "appColorScheme") }
    }

    /// Transactions module (operations list + Reference Data screen).
    ///
    /// ON by default, unlike other modules: it is the app's historical core,
    /// disabling it by default would break every existing installation. But
    /// it MUST still be toggle-able — someone who only uses Nemoris for their
    /// portfolio has no reason to see an empty transactions list.
    ///
    /// `featureTransactions` does not exist in already-installed databases,
    /// and `UserDefaults.bool` would return `false`: the key is therefore
    /// seeded to `true` on first launch (see `seedDefaultFlagsIfNeeded`).
    var showTransactions: Bool = UserDefaults.standard.bool(forKey: "featureTransactions") {
        didSet { UserDefaults.standard.set(showTransactions, forKey: "featureTransactions") }
    }

    /// Tricount feature toggle (opt-in, off by default).
    var showTricount: Bool = UserDefaults.standard.bool(forKey: "featureTricount") {
        didSet { UserDefaults.standard.set(showTricount, forKey: "featureTricount") }
    }

    /// Investments feature toggle (opt-in, off by default).
    /// Like Tricount/Budget: the persisted value is re-read on every launch.
    /// Paid access stays locked by `proToggle` (Settings) + `paywallOverlay`
    /// (InvestmentsView) + the `availableTabs` filter (MainTabView) — a free
    /// user therefore cannot enable the toggle nor see the content.
    var showInvestments: Bool = UserDefaults.standard.bool(forKey: "featureInvestments") {
        didSet { UserDefaults.standard.set(showInvestments, forKey: "featureInvestments") }
    }

    /// Budget & Forecasts feature toggle (opt-in, off by default).
    var showBudget: Bool = UserDefaults.standard.bool(forKey: "featureBudget") {
        didSet { UserDefaults.standard.set(showBudget, forKey: "featureBudget") }
    }

    /// Patrimoine / Net Worth feature toggle (opt-in, off by default).
    /// Module that aggregates investments + savings accounts + real estate
    /// minus loans into a global net worth figure. Optional link to existing
    /// accounts to avoid manual entry.
    var showPatrimoine: Bool = UserDefaults.standard.bool(forKey: "featurePatrimoine") {
        didSet { UserDefaults.standard.set(showPatrimoine, forKey: "featurePatrimoine") }
    }

    /// Automatic investments sync (LiveSync exchanges/wallets + price
    /// history) on foreground and on opening the module, at most once every
    /// 4 hours. On by default: an ABSENT key means true (also read by
    /// InvestmentAutoSyncService).
    var investmentsAutoSyncEnabled: Bool = UserDefaults.standard.object(forKey: "investments.autoSyncEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "investments.autoSyncEnabled") {
        didSet { UserDefaults.standard.set(investmentsAutoSyncEnabled, forKey: "investments.autoSyncEnabled") }
    }

    // MARK: - Privacy (amount masking)

    /// When `true`, every `MoneyText` component shows a masked string
    /// (`•• ••• €`) instead of the real value. Deliberately NOT persisted —
    /// it is a session toggle, reset to `false` on every cold launch so the
    /// user is never caught out (otherwise they reopen the app and can't
    /// tell why nothing shows). Persistence is handled separately by the
    /// face-down mode if the user opts into it.
    var amountsHidden: Bool = false

    /// When `true`, PrivacyMotionMonitor watches the phone's orientation and
    /// flips `amountsHidden` to `true` when the iPhone is placed face down.
    /// Persisted because it is a permanent setting, not session state.
    var hideAmountsOnFaceDown: Bool = UserDefaults.standard.bool(forKey: "hideAmountsOnFaceDown") {
        didSet { UserDefaults.standard.set(hideAmountsOnFaceDown, forKey: "hideAmountsOnFaceDown") }
    }

    /// Global haptic feedback. Defaults to `true` (standard expectation for a
    /// modern app). The user can disable it in Settings → Privacy.
    var hapticsEnabled: Bool = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    /// Display density for Transactions rows. Drives logo size, vertical
    /// padding, and the prominence of secondary info. Persisted.
    var transactionDensity: TransactionDensity =
        TransactionDensity(rawValue: UserDefaults.standard.string(forKey: "transactionDensity") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(transactionDensity.rawValue, forKey: "transactionDensity") }
    }

    /// Preferred currency for display / ad-hoc conversions. Defaults to EUR.
    /// **Note**: not yet propagated to every MoneyText component (which stay
    /// in EUR). Used by CurrencyConverterSheet as the default conversion
    /// target.
    var preferredCurrency: String = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "EUR" {
        didSet { UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency") }
    }

    // MARK: - Programmatic navigation (cross-tab)

    /// Tab to push in MoreView when the navigation target is among the
    /// hidden tabs (≥ 5th position in tabOrder). Set by `navigateToTab(_:)`,
    /// consumed by MoreView via `.navigationDestination`.
    var pendingMoreDestination: MainTabItem? = nil

    /// Investment document dropped by a Siri shortcut
    /// (`ImportInvestmentDocumentIntent`) or the Portfolio share extension,
    /// to be opened in the smart import flow.
    /// Set by NemorisApp on foreground (consuming `PendingImportInbox`),
    /// consumed by `InvestmentsView`, which presents the sheet.
    var pendingInvestmentImportURLs: [URL] = []

    /// Bank statements dropped by the `ImportFileIntent` shortcut or the
    /// Transactions share extension, to be opened in the pre-filled V3
    /// import flow. Set by NemorisApp on foreground (consuming
    /// `PendingImportInbox`), consumed by `MainTabView`, which presents the sheet.
    var pendingTransactionImportURLs: [URL] = []

    /// List of tabs actually active (filtered by the `showXxx` feature
    /// flags). Derived from `mainTabOrder` + flags. The first **4** are
    /// directly addressable via the TabView, the rest live in MoreView.
    /// Single source of truth for both `MainTabView` and `navigateToTab`.
    var availableTabsResolved: [MainTabItem] {
        mainTabOrder.filter { tab in
            switch tab {
            case .tricount:    return showTricount
            case .investments: return showInvestments
            case .budget:      return showBudget
            case .patrimoine:  return showPatrimoine
            case .sqlConsole:  return showSQLConsole
            // "Reference Data" is the reference set FOR transactions (payees,
            // categories, metadata): it follows the module, otherwise a
            // management screen would remain for data no longer visible.
            case .transactions, .referenceData: return showTransactions
            default:           return true
            }
        }
    }

    /// The first 4 tabs shown directly in the TabView (the rest live in
    /// MoreView). iOS supports a max of 5 slots = 4 tabs + "More" button.
    var visibleTabsResolved: [MainTabItem] {
        Array(availableTabsResolved.prefix(4))
    }

    // MARK: - Dashboard layout

    /// Order, visibility, and size of Dashboard cards.
    ///
    /// This is a **stored** property with `didSet` (same doctrine as
    /// `mainTabOrder` below, since 2026-09 — see its doc for why a computed
    /// get/set over `UserDefaults` doesn't work here): the `@Observable`
    /// macro only instruments stored properties, so mutating a computed
    /// property notifies no observer, and the grid must refresh live from
    /// the customization screen.
    var dashboardLayout: [DashboardCardPreference] = DashboardLayoutStore.load() {
        didSet { DashboardLayoutStore.save(dashboardLayout) }
    }

    /// A card is only displayable if its module is active AND, when that
    /// module is paid, the Pro entitlement is still valid. Filtering happens
    /// **at read time** without ever touching the stored preference:
    /// disabling then re-enabling the module, or renewing the subscription,
    /// therefore restores the chosen position and size.
    ///
    /// The module flag (`showBudget`/`showInvestments`, persisted in
    /// UserDefaults) and `PurchaseManager.accessLevel` (NEVER persisted,
    /// recomputed from StoreKit on every launch — see PurchaseManager) can
    /// diverge: an expired subscription leaves the flag at `true`. Without
    /// the `purchaseManager.isUnlocked` check, a user whose Pro entitlement
    /// expired could still toggle — and see the content of — a card for a
    /// module they can no longer open from the tab bar.
    @MainActor
    func isDashboardCardAvailable(_ card: DashboardCardID, purchaseManager: PurchaseManager) -> Bool {
        guard let module = card.requiredModule else { return true }
        guard availableTabsResolved.contains(module) else { return false }
        guard let feature = module.paywallFeature else { return true }
        return purchaseManager.isUnlocked(feature)
    }

    /// Cards that are actually displayable, in the order chosen by the user.
    @MainActor
    func visibleDashboardCards(purchaseManager: PurchaseManager) -> [DashboardCardPreference] {
        dashboardLayout.filter { $0.isVisible && isDashboardCardAvailable($0.card, purchaseManager: purchaseManager) }
    }

    /// Cross-tab navigation from anywhere in the app (e.g. Dashboard banner
    /// → Patrimoine tab). Handles 2 cases:
    ///   - Target tab among the first 4 visible → simple `selectedTab = …`
    ///   - Target tab among the hidden tabs → switch to `more` + set
    ///     `pendingMoreDestination` so MoreView pushes the target screen
    func navigateToTab(_ tab: MainTabItem) {
        if visibleTabsResolved.contains(tab) {
            selectedTab = tab.rawValue
            // Clear any pending More destination so it isn't mistakenly
            // consumed on the next switch to More.
            pendingMoreDestination = nil
        } else {
            selectedTab = "more"
            pendingMoreDestination = tab
        }
    }

    /// Request to open the import tool, with the destination pre-filled by
    /// the module that requested it.
    ///
    /// A module does not present the import flow itself: on desktop, doing
    /// so opened it in the side pane next to the module — but import is a
    /// full multi-step flow, not a detail sheet. A module posts a request,
    /// and the root navigation decides where to show it (sidebar
    /// destination on desktop, sheet on iPhone).
    var importToolRequest: ImportDestination?

    func openImportTool(destination: ImportDestination) {
        importToolRequest = destination
    }

    /// Root-level SQL Console tab (opt-in Pro, off by default).
    /// Access is only through this tab — no shortcut from Reference Data anymore.
    var showSQLConsole: Bool = UserDefaults.standard.bool(forKey: "featureSQLConsole") {
        didSet { UserDefaults.standard.set(showSQLConsole, forKey: "featureSQLConsole") }
    }

    /// Whether cash is included in the total valuation shown by the heroes
    /// (account + global dashboard). OFF: hero shows only the positions'
    /// value, cash is listed separately. ON: hero shows positions + cash
    /// combined. PnL/variation % never factors in cash, regardless of this
    /// flag (otherwise performance would be artificially inflated).
    var investmentsIncludeCashInTotal: Bool = UserDefaults.standard.bool(forKey: "investmentsIncludeCashInTotal") {
        didSet { UserDefaults.standard.set(investmentsIncludeCashInTotal, forKey: "investmentsIncludeCashInTotal") }
    }

    /// Default account selected at startup. 0 = no preference (first available account).
    var defaultAccountId: Int = UserDefaults.standard.integer(forKey: "defaultAccountId") {
        didSet { UserDefaults.standard.set(defaultAccountId, forKey: "defaultAccountId") }
    }

    /// Interface language: "system" | "fr" | "en". Defaults to system.
    var preferredLanguage: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        didSet { UserDefaults.standard.set(preferredLanguage, forKey: "appLanguage") }
    }

    var locale: Locale {
        switch preferredLanguage {
        case "fr": return Locale(identifier: "fr_FR")
        case "en": return Locale(identifier: "en_US")
        default:   return Locale.current
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    private static let tabOrderKey = "mainTabOrder"

    /// Order of the modules (sidebar on Mac/iPad, first 4 = tab bar on
    /// iPhone).
    ///
    /// **Stored** property with `didSet`, NOT a computed get/set directly
    /// over `UserDefaults` (as it was until 2026-09) — `@Observable` only
    /// instruments STORED properties: a computed property's setter can
    /// write to `UserDefaults` all it wants, nothing about that mutation is
    /// ever seen as "the property changed" by any observer. That was masked
    /// for `ModulesSettingsView` itself (its list is driven by a plain
    /// `@State`, unaffected either way) but left every OTHER reader —
    /// `MainTabView`'s `.onChange(of: appState.mainTabOrder)`, the macOS
    /// sidebar order, `availableTabsResolved` — waiting for some UNRELATED
    /// re-render to happen to "catch up" with the new order, since nothing
    /// forced one right away. Retour d'usage 2026-09: reordering modules in
    /// Settings felt like the app froze for a few seconds after releasing
    /// the drag — that's the delay before some coincidental re-render
    /// finally noticed the change. Storing it (same doctrine as
    /// `dashboardLayout` above, which never had this problem) makes the
    /// update immediate.
    var mainTabOrder: [MainTabItem] = AppState.sanitizeTabOrder(
        (UserDefaults.standard.stringArray(forKey: AppState.tabOrderKey) ?? []).compactMap(MainTabItem.init(rawValue:))
    ) {
        didSet {
            // Self-correcting: any caller assigning an unsanitized array
            // (duplicates, or missing a `MainTabItem` case added since the
            // value was saved) gets normalized here — the computed setter
            // used to guarantee this on every write, and callers (`.move(...)`
            // in `ModulesSettingsView`) still rely on it never producing a
            // malformed order. Re-`didSet`-ing with an already-sanitized
            // value is idempotent, so this converges in at most one extra pass.
            let sanitized = Self.sanitizeTabOrder(mainTabOrder)
            guard sanitized == mainTabOrder else {
                mainTabOrder = sanitized
                return
            }
            UserDefaults.standard.set(mainTabOrder.map(\.rawValue), forKey: Self.tabOrderKey)
        }
    }

    init() {
        Self.seedDefaultFlagsIfNeeded()
        // Re-read AFTER seeding: the property was initialized earlier, with
        // the value of a key that may not have existed yet.
        showTransactions = UserDefaults.standard.bool(forKey: "featureTransactions")
    }

    /// Seeds the flags whose default is NOT `false`.
    ///
    /// `UserDefaults.bool(forKey:)` returns `false` for a missing key. A
    /// module that is on by default therefore cannot just read its key:
    /// on first launch after an update, `featureTransactions` does not exist
    /// and the core module would disappear from everyone's navigation. It is
    /// written once, guarded, which then leaves the user free to disable it
    /// — an explicit `false` is never rewritten.
    private static func seedDefaultFlagsIfNeeded() {
        let defaults = UserDefaults.standard
        let seededKey = "featureFlags.seeded.v1"
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        defaults.set(true, forKey: "featureTransactions")
    }

    private static func sanitizeTabOrder(_ input: [MainTabItem]) -> [MainTabItem] {
        var unique: [MainTabItem] = []
        for tab in input where !unique.contains(tab) {
            unique.append(tab)
        }
        for tab in MainTabItem.allCases where !unique.contains(tab) {
            unique.append(tab)
        }
        return unique
    }
}
