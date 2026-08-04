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
        case .patrimoine:   return "house.fill"
        case .tricount:     return "person.2.fill"
        case .budget:       return "chart.bar.fill"
        case .referenceData: return "square.grid.2x2"
        case .sqlConsole:   return "terminal"
        }
    }

    /// Fonctionnalité payante qui verrouille ce module, si applicable. `nil` = accès
    /// libre dès que le toggle des Réglages est actif (Patrimoine, Tricount, Données).
    /// Source unique partagée par le paywall (`paywallOverlay`/`proToggle`) et la
    /// disponibilité des cartes Dashboard (`AppState.isDashboardCardAvailable`) — les
    /// deux ne doivent jamais diverger sur "quel module est payant".
    var paywallFeature: AppFeature? {
        switch self {
        case .investments: return .investments
        case .budget:      return .budget
        case .sqlConsole:  return .sqlConsole
        default:           return nil
        }
    }
}

@Observable
final class AppState {
    /// Tags des entrées "Outils" de la sidebar desktop (macOS/iPad) — ce ne
    /// sont PAS des `MainTabItem`. Source unique réutilisée par `MainTabView`
    /// (rendu sidebar) et tout call site qui route vers ces destinations
    /// (ex : le bouton réglages du Dashboard sur Mac). Évite un literal dupliqué.
    static let sidebarImportTag = "sidebar_import"
    static let sidebarSettingsTag = "sidebar_settings"

    // TEMP DEBUG (bissection crash macOS fiche position) — À RETIRER : avec
    // l'argument -nemorisCrashRepro, ouvre directement l'onglet Investissements
    // pour une reproduction scriptée sans interaction. Sans l'argument : dashboard.
    var selectedTab: String = CommandLine.arguments.contains("-nemorisCrashRepro")
        ? MainTabItem.investments.rawValue
        : MainTabItem.dashboard.rawValue
    var selectedAccountId: Int? = nil
    var selectedAccountName: String = ""
    var filterFromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var filterToDate: Date = Date()
    var importStatus: String = "Aucun import lance"
    var dataRefreshToken: UUID = UUID()

    /// AXE E — session d'import active (résumé léger). Pilote l'affichage du bandeau
    /// "Import en cours" dans MainTabView et le tap pour reprendre.
    var activeImportSession: ImportSessionSummary? = nil

    /// Toggle UI : si true, l'utilisateur a demandé à voir ImportSessionView depuis le bandeau.
    /// MainTabView observe ce flag pour présenter la sheet.
    var showImportSessionSheet: Bool = false

    /// Toast global affiché en haut de l'app via le modifier `.appToast(_:)`.
    /// Setter helper : `postToast(.success, "Texte")`.
    var currentToast: AppToastMessage? = nil

    /// Post un toast global. Auto-disparait après 3 s.
    func postToast(_ kind: AppToastKind, _ text: String) {
        currentToast = AppToastMessage(kind: kind, text: text)
    }

    /// Rafraîchit `activeImportSession` depuis la DB. À appeler au lancement de l'app
    /// et après toute action qui peut changer l'état (création, commit, cancel).
    func reloadActiveImportSession() {
        activeImportSession = ImportSessionRepository().fetchActiveSummary()
    }

    // Persisté : "system" | "light" | "dark"
    var colorSchemeRaw: String = UserDefaults.standard.string(forKey: "appColorScheme") ?? "system" {
        didSet { UserDefaults.standard.set(colorSchemeRaw, forKey: "appColorScheme") }
    }

    /// Fonctionnalité Tricount activée (opt-in, désactivée par défaut).
    var showTricount: Bool = UserDefaults.standard.bool(forKey: "featureTricount") {
        didSet { UserDefaults.standard.set(showTricount, forKey: "featureTricount") }
    }

    /// Fonctionnalité Investissements (opt-in, désactivée par défaut).
    /// Comme Tricount/Budget : la valeur persistée est relue à chaque lancement.
    /// L'accès payant reste verrouillé par `proToggle` (Settings) + `paywallOverlay`
    /// (InvestmentsView) + filtre `availableTabs` (MainTabView) — un user gratuit
    /// ne peut donc pas activer le toggle ni voir le contenu.
    var showInvestments: Bool = UserDefaults.standard.bool(forKey: "featureInvestments") {
        didSet { UserDefaults.standard.set(showInvestments, forKey: "featureInvestments") }
    }

    /// Fonctionnalité Budget & Prévisions (opt-in, désactivée par défaut).
    var showBudget: Bool = UserDefaults.standard.bool(forKey: "featureBudget") {
        didSet { UserDefaults.standard.set(showBudget, forKey: "featureBudget") }
    }

    /// Fonctionnalité Patrimoine / Net Worth (opt-in, désactivée par défaut).
    /// Module qui agrège investissements + comptes épargne + immobilier − prêts
    /// pour donner la valeur nette globale. Lien optionnel vers les comptes
    /// existants pour éviter la saisie manuelle.
    var showPatrimoine: Bool = UserDefaults.standard.bool(forKey: "featurePatrimoine") {
        didSet { UserDefaults.standard.set(showPatrimoine, forKey: "featurePatrimoine") }
    }

    /// Chantier A — synchronisation automatique des investissements (LiveSync
    /// exchanges/wallets + historique des cours) au passage en premier plan et
    /// à l'ouverture du module, au plus une fois toutes les 4 h. Activée par
    /// défaut : la clé ABSENTE vaut true (lue aussi par InvestmentAutoSyncService).
    var investmentsAutoSyncEnabled: Bool = UserDefaults.standard.object(forKey: "investments.autoSyncEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "investments.autoSyncEnabled") {
        didSet { UserDefaults.standard.set(investmentsAutoSyncEnabled, forKey: "investments.autoSyncEnabled") }
    }

    // MARK: - Confidentialité (masquage des montants)

    /// Quand `true`, tous les composants `MoneyText` affichent une chaîne masquée
    /// (`•• ••• €`) au lieu de la valeur réelle. Volontairement NON persisté —
    /// c'est un toggle de session, l'état repart à `false` à chaque cold launch
    /// pour ne pas piéger l'user (sinon il rouvre l'app et ne comprend pas
    /// pourquoi rien ne s'affiche). Persistance gérée séparément via le mode
    /// face-down si l'user le souhaite.
    var amountsHidden: Bool = false

    /// Si `true`, le PrivacyMotionMonitor surveille l'orientation du téléphone
    /// et bascule `amountsHidden` à `true` quand l'iPhone est posé face contre
    /// la table. Persisté car c'est un réglage permanent, pas un état de session.
    var hideAmountsOnFaceDown: Bool = UserDefaults.standard.bool(forKey: "hideAmountsOnFaceDown") {
        didSet { UserDefaults.standard.set(hideAmountsOnFaceDown, forKey: "hideAmountsOnFaceDown") }
    }

    /// Retours haptiques globaux. Default `true` (attente standard d'une app
    /// moderne). L'user peut désactiver dans Settings → Confidentialité.
    var hapticsEnabled: Bool = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    /// Densité d'affichage des rows Transactions. Pilote la taille du logo,
    /// les paddings verticaux et la prominence des sous-infos. Persisté.
    var transactionDensity: TransactionDensity =
        TransactionDensity(rawValue: UserDefaults.standard.string(forKey: "transactionDensity") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(transactionDensity.rawValue, forKey: "transactionDensity") }
    }

    /// Devise préférée pour l'affichage / conversions ad-hoc. Default EUR.
    /// **Note** : MVP — la devise n'est pas encore propagée à tous les
    /// composants MoneyText (qui restent en EUR). Utilisée par le
    /// CurrencyConverterSheet pour la cible de conversion par défaut.
    var preferredCurrency: String = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "EUR" {
        didSet { UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency") }
    }

    // MARK: - Navigation programmatique (cross-tab)

    /// Tab à pousser dans MoreView quand la cible de navigation est dans les
    /// onglets cachés (≥ 5e position du tabOrder). Setté par `navigateToTab(_:)`,
    /// consommé par MoreView via `.navigationDestination`.
    var pendingMoreDestination: MainTabItem? = nil

    /// Chantier D — document d'investissement déposé par un raccourci Siri
    /// (`ImportInvestmentDocumentIntent`) ou la share extension Portefeuille,
    /// à ouvrir dans l'import intelligent.
    /// Setté par NemorisApp au passage au premier plan (consommation de
    /// `PendingImportInbox`), consommé par `InvestmentsView` qui présente la sheet.
    var pendingInvestmentImportURLs: [URL] = []

    /// AXE P — relevés bancaires déposés par le raccourci `ImportFileIntent` ou
    /// la share extension Transactions, à ouvrir dans l'import V3 pré-rempli.
    /// Setté par NemorisApp au passage au premier plan (consommation de
    /// `PendingImportInbox`), consommé par `MainTabView` qui présente la sheet.
    var pendingTransactionImportURLs: [URL] = []

    /// Liste des tabs effectivement actifs (filtrés selon les feature flags
    /// `showXxx`). Dérivé de `mainTabOrder` + flags. Le **4 premiers** sont
    /// directement adressables via TabView, les suivants vivent dans MoreView.
    /// Source unique de vérité pour `MainTabView` ET pour `navigateToTab`.
    var availableTabsResolved: [MainTabItem] {
        mainTabOrder.filter { tab in
            switch tab {
            case .tricount:    return showTricount
            case .investments: return showInvestments
            case .budget:      return showBudget
            case .patrimoine:  return showPatrimoine
            case .sqlConsole:  return showSQLConsole
            default:           return true
            }
        }
    }

    /// Les 4 premiers tabs visibles directement dans la TabView (les autres
    /// vivent dans MoreView). iOS gère 5 slots max = 4 tabs + bouton "Plus".
    var visibleTabsResolved: [MainTabItem] {
        Array(availableTabsResolved.prefix(4))
    }

    // MARK: - Mise en page du Dashboard

    /// Ordre, visibilité et taille des cartes du Dashboard.
    ///
    /// ⚠️ Propriété **stockée** avec `didSet`, et surtout PAS une computed property
    /// get/set sur UserDefaults comme `mainTabOrder` juste au-dessus : le macro
    /// `@Observable` n'instrumente que les propriétés stockées, donc muter une
    /// computed ne notifie aucun observateur. Ça ne se voit pas pour `mainTabOrder`
    /// parce que son écran de réglages garde une copie `@State` locale, mais ici la
    /// grille doit se rafraîchir en direct depuis l'écran de personnalisation.
    var dashboardLayout: [DashboardCardPreference] = DashboardLayoutStore.load() {
        didSet { DashboardLayoutStore.save(dashboardLayout) }
    }

    /// Une carte n'est affichable que si son module est actif ET, quand ce module est
    /// payant, que l'entitlement Pro est toujours valide. On filtre **à la lecture**
    /// sans jamais toucher à la préférence stockée : désactiver puis réactiver le
    /// module, ou renouveler l'abonnement, restitue ainsi la position et la taille
    /// choisies.
    ///
    /// ⚠️ Le flag module (`showBudget`/`showInvestments`, persisté en UserDefaults) et
    /// `PurchaseManager.accessLevel` (JAMAIS persisté, recalculé à chaque lancement
    /// depuis StoreKit — cf. PurchaseManager) peuvent diverger : un abonnement qui
    /// expire laisse le flag à `true`. Sans le check `purchaseManager.isUnlocked`, un
    /// utilisateur dont le Pro a expiré pouvait encore activer/désactiver — et voir
    /// le contenu de — la carte d'un module qu'il ne peut plus ouvrir depuis l'onglet.
    @MainActor
    func isDashboardCardAvailable(_ card: DashboardCardID, purchaseManager: PurchaseManager) -> Bool {
        guard let module = card.requiredModule else { return true }
        guard availableTabsResolved.contains(module) else { return false }
        guard let feature = module.paywallFeature else { return true }
        return purchaseManager.isUnlocked(feature)
    }

    /// Cartes réellement affichables, dans l'ordre choisi par l'utilisateur.
    @MainActor
    func visibleDashboardCards(purchaseManager: PurchaseManager) -> [DashboardCardPreference] {
        dashboardLayout.filter { $0.isVisible && isDashboardCardAvailable($0.card, purchaseManager: purchaseManager) }
    }

    /// Navigation cross-tab depuis n'importe où dans l'app (ex : bandeau
    /// Dashboard → onglet Patrimoine). Gère les 2 cas :
    ///   - Tab cible parmi les 4 premiers visibles → simple `selectedTab = …`
    ///   - Tab cible dans les onglets cachés → bascule sur `more` + set
    ///     `pendingMoreDestination` pour que MoreView push l'écran cible
    func navigateToTab(_ tab: MainTabItem) {
        if visibleTabsResolved.contains(tab) {
            selectedTab = tab.rawValue
            // S'il y avait une destination pending dans More, on la clear pour
            // ne pas la dérouler par erreur au prochain switch vers More.
            pendingMoreDestination = nil
        } else {
            selectedTab = "more"
            pendingMoreDestination = tab
        }
    }

    /// Onglet Console SQL en racine (opt-in Pro, désactivé par défaut).
    /// L'accès se fait uniquement via cet onglet — plus de raccourci dans Données.
    var showSQLConsole: Bool = UserDefaults.standard.bool(forKey: "featureSQLConsole") {
        didSet { UserDefaults.standard.set(showSQLConsole, forKey: "featureSQLConsole") }
    }

    /// Affichage de la trésorerie (cash) dans la valorisation totale des heros
    /// (compte + dashboard global). Quand OFF : hero affiche uniquement la valeur des
    /// positions, le cash est listé séparément. Quand ON : hero affiche positions + cash
    /// en grand. ⚠️ Le calcul de PnL/variation% n'utilise JAMAIS le cash, peu importe
    /// la valeur de ce flag (sinon la perf serait artificiellement gonflée).
    var investmentsIncludeCashInTotal: Bool = UserDefaults.standard.bool(forKey: "investmentsIncludeCashInTotal") {
        didSet { UserDefaults.standard.set(investmentsIncludeCashInTotal, forKey: "investmentsIncludeCashInTotal") }
    }

    /// Compte par défaut sélectionné au démarrage. 0 = aucune préférence (premier compte disponible).
    var defaultAccountId: Int = UserDefaults.standard.integer(forKey: "defaultAccountId") {
        didSet { UserDefaults.standard.set(defaultAccountId, forKey: "defaultAccountId") }
    }

    /// Langue de l'interface : "system" | "fr" | "en". Par défaut : système.
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

    private let tabOrderKey = "mainTabOrder"

    var mainTabOrder: [MainTabItem] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: tabOrderKey) ?? []
            return sanitizeTabOrder(raw.compactMap(MainTabItem.init(rawValue:)))
        }
        set {
            let sanitized = sanitizeTabOrder(newValue)
            UserDefaults.standard.set(sanitized.map(\.rawValue), forKey: tabOrderKey)
        }
    }

    init() {
        mainTabOrder = sanitizeTabOrder(mainTabOrder)
    }

    private func sanitizeTabOrder(_ input: [MainTabItem]) -> [MainTabItem] {
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
