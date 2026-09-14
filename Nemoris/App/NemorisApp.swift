import SwiftUI
import UniformTypeIdentifiers
import TipKit

@main
struct NemorisApp: App {
    @State private var appState = AppState()
    @State private var purchaseManager = PurchaseManager.shared
    /// Dashboard aggregate cache. Injected here rather than as `@State` in the
    /// view: `DashboardView` is instantiated twice (iOS TabView + macOS
    /// sidebar detail pane), and two separate caches would mean computing
    /// everything twice.
    @State private var dashboardStore = DashboardSnapshotStore()
    /// Injected ONCE, like `dashboardStore`: `DashboardView` is
    /// instantiated twice (the iOS TabView + the macOS detail pane), and two copies
    /// would launch two AI analyses in parallel on the same domain.
    @State private var coachStore = CoachStore()
    @State private var hasDatabase: Bool
    /// Unlock state. Starts at `false` if the lock is enabled AND there is a
    /// pending auth request (typical case: resuming from background).
    /// Otherwise `true` (lock disabled OR nothing to request).
    @State private var isUnlocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if targetEnvironment(simulator)
        if !DatabaseManager.shared.hasDatabase() {
            try? DatabaseManager.shared.createNewDatabase()
        }
        SimulatorSeeder.seedIfNeeded()
        #endif
        #if DEBUG
        // Marketing-screenshot automation: seeds a fully-populated demo database
        // (redirected to an isolated `FinanceMobileIOS-Screenshots` folder by
        // `DatabaseManager.fallbackURL()` — never touches a real user database,
        // notably on native macOS) and unlocks every paid module so XCUITest can
        // navigate the whole app headlessly. Debug-only, opt-in via a launch
        // argument.
        // (Feature-flag enabling lives further down: it touches `self.appState`,
        // which isn't definitely initialized yet at this point in a struct init.)
        let screenshotMode = CommandLine.arguments.contains("-nemorisScreenshotMode")
        if screenshotMode {
            #if os(macOS)
            if !DatabaseManager.shared.hasDatabase() {
                try? DatabaseManager.shared.createNewDatabase()
            }
            SimulatorSeeder.seedIfNeeded()
            #endif
            PurchaseManager.shared.devOverrideEnabled = true
        }
        #endif
        // Applies any pending migrations to an existing database.
        if DatabaseManager.shared.hasDatabase() {
            DatabaseManager.shared.migrateIfNeeded()
        }
        _hasDatabase = State(initialValue: DatabaseManager.shared.hasDatabase())
        // On a cold launch (init), auth is considered necessary whenever the
        // lock is enabled. This is stricter than reading `needsAuthentication`
        // (which could have been left `false` by a crash) — the app always
        // relocks on cold start. The flag is set back to true on backgrounding
        // to also cover warm launches (see the scenePhase handler).
        let lockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        _isUnlocked = State(initialValue: !lockEnabled)
        #if DEBUG
        // `self` is fully initialized past this point — safe to touch `appState`.
        if screenshotMode {
            appState.showTransactions = true
            appState.showTricount = true
            appState.showInvestments = true
            appState.showBudget = true
            appState.showPatrimoine = true
            appState.showSQLConsole = true
            // Driven from the app's OWN language/theme overrides rather than
            // `simctl ui appearance` or `-AppleLanguages`: `xcodebuild test` runs
            // UI tests against a cloned simulator that doesn't reliably inherit
            // either, but these two `AppState` properties are read directly by
            // `.environment(\.locale, …)` / `.preferredColorScheme(…)` in this
            // file's `body`, so they always take effect regardless of the host
            // simulator's own settings.
            let args = CommandLine.arguments
            if args.contains("-nemorisLangEN") { appState.preferredLanguage = "en" }
            if args.contains("-nemorisLangFR") { appState.preferredLanguage = "fr" }
            if args.contains("-nemorisThemeDark") { appState.colorSchemeRaw = "dark" }
            if args.contains("-nemorisThemeLight") { appState.colorSchemeRaw = "light" }
        }
        #endif
        try? Tips.configure([
            .datastoreLocation(.applicationDefault),
            .displayFrequency(.immediate)
        ])
        // Boots NemorisEngine in the background: ~300 ms (ONNX MiniLM model +
        // merchant index). Preloaded here so it's warm by the time the user
        // opens the import flow.
        Task { @MainActor in
            EngineBootstrap.shared.bootIfNeeded(withEmbeddings: true)
        }
        // Boots the CloudKit sync engine — no-op if the user hasn't enabled
        // iCloud sync in Settings (strict opt-in).
        Task {
            await CloudSyncEngine.shared.bootIfEnabled()
        }
    }

    var body: some Scene {
        WindowGroup {
            if hasDatabase {
                // ⚠️ `.environment(\.locale, …)` set HERE, on the REAL root of the
                // window's content (this `ZStack`) — NOT on `MainTabView()` (a
                // child of the ZStack) as before. Two distinct real bugs,
                // found on 2026-08-25:
                //
                // 1. `AppLockGate` is a SIBLING of `MainTabView` in this `ZStack`,
                //    not a descendant — it inherited NOTHING set only on
                //    `MainTabView`. "Locked" stayed shown in the system's English
                //    whatever language was chosen in the app.
                // 2. More insidious: even set on `MainTabView()` (so above
                //    `AppLockGate`), `\.locale` did NOT reliably reach the
                //    content of level-2+ `.sheet()`s opened from a macOS pane
                //    (e.g. "Sync details" from a position's sheet) —
                //    verified with a debug `@Environment(\.locale)` showing
                //    `en_US` on a Mac with an English system locale even though the app was
                //    set to French. A macOS sheet is backed by a REAL, separate
                //    `NSWindow` (unlike iOS, where it shares the same
                //    window) — environment inheritance for this kind of window
                //    seems to be computed relative to the WindowGroup's content's REAL
                //    root, not relative to the node where the modifier was
                //    set if that node is a CHILD of that root. Moving the
                //    modifier up onto the `ZStack` (the real root) fixes both
                //    bugs at once and avoids the earlier duplication on every
                //    sibling.
                ZStack {
                    MainTabView()
                        .environment(appState)
                        .environment(purchaseManager)
                        .environment(dashboardStore)
                        .environment(coachStore)
                        .preferredColorScheme(appState.preferredColorScheme)
                        .tipViewStyle(NemorisTipViewStyle())

                    // Lock overlay — above ALL app content (including sheets)
                    // as long as `isUnlocked == false`. Smooth transition to
                    // avoid an abrupt cut when unlocking.
                    if !isUnlocked {
                        AppLockGate(isUnlocked: $isUnlocked)
                            .preferredColorScheme(appState.preferredColorScheme)
                            .transition(.opacity)
                            .zIndex(100)
                    }
                }
                .environment(\.locale, appState.locale)
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .background {
                            // CloudKit sync: pushes local writes accumulated
                            // during the session to the engine, which sends
                            // them in the background. No-op if sync is disabled.
                            Task { await CloudSyncEngine.shared.notifyLocalChanges() }
                            // Immediate relock as soon as the app backgrounds.
                            // Standard strict policy (banking apps): no grace
                            // period, to avoid leaking financial data in the
                            // app switcher or if the screen stays on.
                            if AppLockService.shared.isLockEnabled {
                                AppLockService.shared.markNeedsAuthentication()
                                isUnlocked = false
                            }
                            // Suspends the motion monitor so it doesn't drain
                            // the battery while the app isn't visible.
                            PrivacyMotionMonitor.shared.suspend()
                        }
                        if newPhase == .active {
                            // Refreshes entitlements on every foreground
                            // transition (e.g. subscription expired, purchase
                            // made from another device).
                            Task { await purchaseManager.refreshEntitlements() }
                            // Pushes a fresh snapshot to the widget.
                            let prefId = appState.defaultAccountId > 0 ? appState.defaultAccountId : nil
                            Task.detached(priority: .utility) {
                                await WidgetDataStore.refresh(preferredAccountId: prefId)
                            }
                            // Daily auto-backup (24h gate internal to the
                            // service). Deferred to background priority so it
                            // doesn't compete with UI startup; on disk it's a
                            // plain copy.
                            Task.detached(priority: .background) { @MainActor in
                                BackupService.shared.runAutoBackupIfDue()
                            }
                            // Resumes the motion monitor (no-op if the user
                            // hasn't enabled `hideAmountsOnFaceDown`).
                            PrivacyMotionMonitor.shared.resume()
                            // Investment auto-sync (LiveSync exchanges/wallets
                            // + prices). The service bails out on its own:
                            // feature off, toggle off, already running, or
                            // last pass < 4h ago.
                            Task { await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .appActive) }
                            // Notifies the Dashboard if new Apple Pay expenses
                            // arrived in the background (the Shortcuts
                            // automation) since the last foreground.
                            // No automatic resolution (removed for now, to revisit later).
                            ApplePayDashboardSync.syncIfNeeded()
                            // An investment document dropped by a Siri
                            // shortcut (ImportInvestmentDocumentIntent) is
                            // consumed here, opening the smart import flow
                            // pre-filled with it.
                            let pendingInvest = PendingImportInbox.consumePendingInvestmentImports()
                            if !pendingInvest.isEmpty {
                                appState.pendingInvestmentImportURLs = pendingInvest
                                appState.navigateToTab(.investments)
                            }
                            // Statements dropped by the "Import transactions"
                            // shortcut or the Transactions share extension:
                            // MainTabView presents ImportEntryView pre-filled.
                            let pendingTx = PendingImportInbox.consumePendingTransactionImports()
                            if !pendingTx.isEmpty {
                                appState.pendingTransactionImportURLs = pendingTx
                            }
                        }
                    }
                    .task { await purchaseManager.initialize() }
                    .task {
                        // Attaches the motion monitor to the AppState. No-op
                        // as long as `hideAmountsOnFaceDown == false`. Must be
                        // called exactly once at launch (idempotent).
                        PrivacyMotionMonitor.shared.attach(to: appState)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisSyncDidApplyRemoteChanges)) { _ in
                        // CloudKit sync: REMOTE changes have been applied to
                        // the database → invalidate all VMs.
                        appState.dataRefreshToken = UUID()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisApplePayDataDidChange)) { _ in
                        // An Apple Pay expense was just dropped (by
                        // the Shortcuts automation, in the background — this
                        // separate process can't bump `dataRefreshToken`
                        // itself), dismissed, or purged: the
                        // Dashboard's banner must reflect the change.
                        appState.dataRefreshToken = UUID()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisImportSessionsDidChange)) { _ in
                        // The import coordinator created or deleted a session
                        // in the database → reload the in-memory mirror that
                        // drives the banner, so it never survives the row it
                        // represents (a ghost banner after an aborted import).
                        appState.reloadActiveImportSession()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisInvestmentsDidSync)) { _ in
                        // An investment sync pass (automatic or manual) just
                        // completed → invalidate the VMs so the dashboard
                        // reflects the new values.
                        appState.dataRefreshToken = UUID()
                    }
            } else {
                OnboardingFlowView {
                    hasDatabase = true
                    appState.dataRefreshToken = UUID()
                }
                .environment(purchaseManager)
                .environment(\.locale, appState.locale)
                .preferredColorScheme(appState.preferredColorScheme)
            }
        }
        #if os(macOS)
        // Desktop shortcuts: ⌘1…⌘9 switch between modules in sidebar order.
        // Injected via hidden buttons in a CommandGroup to drive
        // appState.selectedTab from the menu.
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(appState.mainTabOrder.prefix(9).enumerated()), id: \.element) { index, tab in
                    Button(LocalizedStringKey(tab.title)) { appState.navigateToTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
