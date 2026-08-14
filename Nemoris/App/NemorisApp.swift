import SwiftUI
import UniformTypeIdentifiers
import TipKit

@main
struct NemorisApp: App {
    @State private var appState = AppState()
    @State private var purchaseManager = PurchaseManager.shared
    /// Cache des agrégats du Dashboard. Injecté ici et pas en `@State` dans la vue :
    /// `DashboardView` est instanciée deux fois (TabView iOS + volet détail de la
    /// sidebar macOS), et deux caches voudraient dire tout calculer deux fois.
    @State private var dashboardStore = DashboardSnapshotStore()
    @State private var hasDatabase: Bool
    /// État de déverrouillage. Démarre à `false` si le lock est activé ET qu'on
    /// a une demande d'auth pending (cas typique : reprise depuis background).
    /// Sinon `true` (lock désactivé OU rien à demander).
    @State private var isUnlocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if targetEnvironment(simulator)
        if !DatabaseManager.shared.hasDatabase() {
            try? DatabaseManager.shared.createNewDatabase()
        }
        SimulatorSeeder.seedIfNeeded()
        #endif
        // Applique les migrations en attente sur toute base existante
        if DatabaseManager.shared.hasDatabase() {
            DatabaseManager.shared.migrateIfNeeded()
        }
        _hasDatabase = State(initialValue: DatabaseManager.shared.hasDatabase())
        // Au lancement à froid (init), on considère que l'auth est nécessaire si
        // le lock est activé. C'est plus strict que de regarder `needsAuthentication`
        // (qui peut avoir été oublié à `false` lors d'un crash) → on relock toujours
        // au cold-start. Au passage en background, on remettra le flag à true
        // pour gérer aussi les chauds (cf. scenePhase handler).
        let lockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        _isUnlocked = State(initialValue: !lockEnabled)
        try? Tips.configure([
            .datastoreLocation(.applicationDefault),
            .displayFrequency(.immediate)
        ])
        // Boot NemorisEngine en arrière-plan : ~300 ms (modèle ONNX MiniLM + index merchants).
        // On précharge ici pour qu'il soit chaud quand l'utilisateur ouvre l'import (import).
        Task { @MainActor in
            EngineBootstrap.shared.bootIfNeeded(withEmbeddings: true)
        }
        // Boot du moteur de sync CloudKit — no-op si l'utilisateur n'a pas
        // activé la synchronisation iCloud dans les Settings (opt-in strict).
        Task {
            await CloudSyncEngine.shared.bootIfEnabled()
        }
    }

    var body: some Scene {
        WindowGroup {
            if hasDatabase {
                ZStack {
                    MainTabView()
                        .environment(appState)
                        .environment(purchaseManager)
                        .environment(dashboardStore)
                        .environment(\.locale, appState.locale)
                        .preferredColorScheme(appState.preferredColorScheme)
                        .tipViewStyle(NemorisTipViewStyle())

                    // Overlay de verrouillage — au-dessus de TOUT le contenu app
                    // (y compris sheets) tant que `isUnlocked == false`. Transition
                    // douce pour éviter un cut sec quand on déverrouille.
                    if !isUnlocked {
                        AppLockGate(isUnlocked: $isUnlocked)
                            .preferredColorScheme(appState.preferredColorScheme)
                            .transition(.opacity)
                            .zIndex(100)
                    }
                }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .background {
                            // Sync CloudKit : pousse les écritures locales
                            // accumulées pendant la session vers le moteur, qui les
                            // enverra en arrière-plan. No-op si sync désactivée.
                            Task { await CloudSyncEngine.shared.notifyLocalChanges() }
                            // Relock immédiat dès que l'app passe en background.
                            // Politique stricte standard (apps bancaires) : pas de
                            // grace period pour éviter de leak des données financières
                            // dans l'app switcher ou si l'écran reste allumé.
                            if AppLockService.shared.isLockEnabled {
                                AppLockService.shared.markNeedsAuthentication()
                                isUnlocked = false
                            }
                            // Suspend le monitor de motion pour ne pas drainer la
                            // batterie quand l'app n'est pas visible.
                            PrivacyMotionMonitor.shared.suspend()
                        }
                        if newPhase == .active {
                            // Rafraîchit les droits à chaque passage en premier plan
                            // (ex. : abonnement expiré, achat depuis un autre appareil)
                            Task { await purchaseManager.refreshEntitlements() }
                            // Pousse un snapshot frais vers le widget
                            let prefId = appState.defaultAccountId > 0 ? appState.defaultAccountId : nil
                            Task.detached(priority: .utility) {
                                WidgetDataStore.refresh(preferredAccountId: prefId)
                            }
                            // Auto-backup quotidien (gate 24 h interne au service).
                            // Décalé sur background priority pour ne pas concurrencer
                            // le démarrage UI ; côté disque c'est une simple copie.
                            Task.detached(priority: .background) { @MainActor in
                                BackupService.shared.runAutoBackupIfDue()
                            }
                            // Relance le monitor de motion (no-op si l'utilisateur n'a
                            // pas activé `hideAmountsOnFaceDown`).
                            PrivacyMotionMonitor.shared.resume()
                            // Chantier A — auto-sync investissements (LiveSync
                            // exchanges/wallets + cours). Le service se dégage
                            // seul : feature off, toggle off, déjà en cours,
                            // ou dernière passe < 4 h.
                            Task { await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .appActive) }
                            // Chantier D — document d'investissement déposé par un
                            // raccourci Siri (ImportInvestmentDocumentIntent) : on le
                            // consomme et on ouvre l'import intelligent pré-rempli.
                            let pendingInvest = PendingImportInbox.consumePendingInvestmentImports()
                            if !pendingInvest.isEmpty {
                                appState.pendingInvestmentImportURLs = pendingInvest
                                appState.navigateToTab(.investments)
                            }
                            // relevés déposés par le raccourci "Importer des
                            // transactions" ou la share extension Transactions :
                            // MainTabView présente ImportEntryView pré-rempli.
                            let pendingTx = PendingImportInbox.consumePendingTransactionImports()
                            if !pendingTx.isEmpty {
                                appState.pendingTransactionImportURLs = pendingTx
                            }
                        }
                    }
                    .task { await purchaseManager.initialize() }
                    .task {
                        // Attache le monitor de motion à l'AppState. No-op tant
                        // que `hideAmountsOnFaceDown == false`. Doit être appelé
                        // une seule fois au lancement (idempotent).
                        PrivacyMotionMonitor.shared.attach(to: appState)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisSyncDidApplyRemoteChanges)) { _ in
                        // Sync CloudKit : des changements DISTANTS ont
                        // été appliqués à la base → invalide tous les VMs.
                        appState.dataRefreshToken = UUID()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisImportSessionsDidChange)) { _ in
                        // Le coordinateur d'import a créé ou supprimé une
                        // session en base → recharger le miroir en mémoire qui
                        // pilote le bandeau, sans quoi il survit à la ligne
                        // qu'il représente (bandeau fantôme après un abandon).
                        appState.reloadActiveImportSession()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .nemorisInvestmentsDidSync)) { _ in
                        // Chantier A : une passe de sync investissements (auto ou
                        // manuelle) vient de se terminer → invalide les VMs pour
                        // que le dashboard reflète les nouvelles valeurs.
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
        // raccourcis desktop : ⌘1…⌘9 basculent sur les modules dans
        // l'ordre de la sidebar. Injectés via des boutons cachés dans une
        // CommandGroup pour piloter appState.selectedTab depuis le menu.
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(appState.mainTabOrder.prefix(9).enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { appState.navigateToTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}

// (Ancienne struct OnboardingView retirée — remplacée par `OnboardingFlowView`
//  dans Features/Onboarding/. Refonte 2026-06 : welcome enrichi avec 3 promesses,
//  step modules opt-in, écran final récap.)
