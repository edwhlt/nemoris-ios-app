import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// wrapper Identifiable pour présenter l'import V3 pré-rempli via
/// `.sheet(item:)` (CSV déposé par un raccourci Siri ou la share extension).
/// Miroir de `PreloadedInvestmentImport` côté Investissements.
struct PreloadedTransactionImport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Ouverture de l'outil d'importation demandée par un module.
struct RequestedImport: Identifiable {
    let id = UUID()
    let destination: ImportDestination
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showCancelImportConfirm = false
    /// Analyse de document en arrière-plan : l'utilisateur garde la main
    /// pendant que ça travaille, le bandeau sert de point de retour.
    private var importCoordinator: DocumentImportCoordinator { .shared }
    @State private var showAnalysisReview = false
    @State private var showInvestmentReview = false
    @State private var showCancelAnalysisConfirm = false
    /// import V3 pré-rempli par un CSV partagé/raccourci.
    @State private var preloadedTransactionImport: PreloadedTransactionImport?
    /// iPhone : l'outil d'importation demandé par un module, présenté en feuille
    /// faute de sidebar où l'envoyer.
    @State private var requestedImport: RequestedImport?
    #if os(macOS)
    /// Slot unique de l'inspecteur global desktop : les `.adaptivePane` de
    /// niveau 1 routent leur contenu ici (cf. doc `AdaptivePane.swift`).
    @State private var paneCenter = InspectorPaneCenter()
    /// Recherche globale — bouton posé à côté du toggle de sidebar (cf.
    /// `sidebarList`). Sur iOS, l'équivalent vit dans le toolbar Dashboard ;
    /// macOS n'a pas de Dashboard "toujours visible" au même titre (l'utilisateur
    /// peut être sur n'importe quel module), donc l'entrée vit à la racine.
    @State private var showGlobalSearch = false
    #endif
    private let moreTag = "more"
    /// Entrées "Outils" propres à la sidebar (pas des MainTabItem).
    /// Source unique dans AppState (réutilisée par le gear Dashboard sur Mac).
    private let sidebarImportTag = AppState.sidebarImportTag
    private let sidebarSettingsTag = AppState.sidebarSettingsTag

    /// layout desktop : sidebar sur Mac et iPad en paysage, où une
    /// tab bar iPhone dépareille dans une grande fenêtre. iPhone (et iPad
    /// compact / Split View étroit) garde la TabView.
    private var useSidebar: Bool {
        #if os(macOS)
        return true   // Mac natif = toujours la sidebar
        #else
        return UIDevice.current.userInterfaceIdiom == .pad && hSizeClass == .regular
        #endif
    }

    var body: some View {
        @Bindable var state = appState
        // Position du bandeau : EN HAUT sur iOS (style "appel en cours", sous
        // l'encoche et loin de la tab bar), EN BAS sur macOS — une barre d'état
        // persistante y est une convention desktop (barre de statut de fenêtre),
        // alors qu'en haut elle entre en concurrence avec la barre de titre et
        // la toolbar du module.
        return VStack(spacing: 0) {
            #if !os(macOS)
            importBanner(edge: .top)
            #endif

            if useSidebar {
                sidebarLayout
            } else {
                tabLayout
            }

            #if os(macOS)
            importBanner(edge: .bottom)
            #endif
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState.activeImportSession?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: importCoordinator.phase)
        .appToast($state.currentToast)
        .adaptivePane(isPresented: $state.showImportSessionSheet) {
            if let summary = appState.activeImportSession {
                // ⚠️ La revue dépend de la DESTINATION : une session de
                // transactions ouvre la résolution ligne à ligne (tiers,
                // catégories), une session d'investissements ouvre le
                // rattachement d'ordres à un compte-titres. Les deux répondent
                // à des questions différentes et restent distinctes.
                switch summary.destination {
                case .transactions:
                    NavigationStack {
                        ImportSessionView(sessionId: summary.id)
                    }
                case .investments:
                    InvestmentPDFImportView(
                        preparsedBatch: importCoordinator.batch,
                        accountId: summary.accountId ?? importCoordinator.accountId,
                        onFinished: {
                            state.showImportSessionSheet = false
                            appState.activeImportSession = nil
                            importCoordinator.clear()
                        }
                    )
                    // Le rechargement depuis la base, quand l'app a redémarré,
                    // est fait par `AppState.reloadActiveImportSession` — donc
                    // AVANT cette construction, sans quoi le `@State` de la
                    // revue serait déjà figé sur un résultat vide.
                    .id(summary.id)
                }
            }
        }
        // CSV déposé par le raccourci "Importer des transactions (CSV)"
        // ou la share extension Transactions : import V3 pré-rempli. Si une
        // session est déjà active, ImportEntryView affiche l'alerte de reprise.
        .adaptivePane(item: $preloadedTransactionImport) { item in
            ImportEntryView(preloadedFileURLs: item.urls)
        }
        // Relecture du résultat d'une analyse en arrière-plan.
        .adaptivePane(isPresented: $showAnalysisReview) {
            TransactionDocumentReviewView(
                coordinator: importCoordinator,
                onConfirm: { summary in
                    importCoordinator.clear()
                    appState.activeImportSession = summary
                    // Passage à la revue complète sans clignotement
                    // (cf. `ImportEntryView.handOver`).
                    ImportEntryView.handOver(to: appState,
                                               dismissSelf: { showAnalysisReview = false })
                },
                onCancel: {
                    showAnalysisReview = false
                    importCoordinator.clear()
                }
            )
        }
        .adaptivePane(isPresented: $showInvestmentReview) {
            InvestmentPDFImportView(
                preparsedBatch: importCoordinator.batch,
                accountId: importCoordinator.accountId,
                onFinished: {
                    showInvestmentReview = false
                    importCoordinator.clear()
                }
            )
        }
        .onChange(of: appState.pendingTransactionImportURLs) { _, urls in
            consumePendingTransactionImport(urls)
        }
        // Un module a demandé l'outil d'importation : c'est la navigation
        // RACINE qui décide où l'afficher, pas le module.
        .onChange(of: appState.importToolRequest) { _, request in
            guard request != nil else { return }
            if useSidebar {
                // Desktop : une destination à part entière, pas le volet
                // latéral collé au module qu'on vient de quitter.
                state.selectedTab = sidebarImportTag
            } else {
                requestedImport = RequestedImport(destination: request ?? .transactions)
            }
            // La demande est consommée : elle a servi à choisir la destination,
            // la laisser rouvrirait l'import au prochain changement d'onglet.
            appState.importToolRequest = nil
        }
        .adaptivePane(item: $requestedImport) { item in
            ImportEntryView(initialDestination: item.destination)
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
                    // ⚠️ Fermer AUSSI le panneau : sans ça l'inspecteur macOS
                    // restait ouvert sur une session supprimée — l'utilisateur
                    // voyait un import « toujours en cours » qui n'existait plus.
                    appState.showImportSessionSheet = false
                }
            }
            Button("Continuer l'import", role: .cancel) {}
        } message: {
            Text("Les lignes non encore importées seront perdues.")
        }
        .confirmationDialog(
            importCoordinator.isReady ? "Abandonner ce résultat d'analyse ?"
                                      : "Interrompre l'analyse en cours ?",
            isPresented: $showCancelAnalysisConfirm,
            titleVisibility: .visible
        ) {
            Button(importCoordinator.isReady ? "Abandonner le résultat" : "Interrompre l'analyse",
                   role: .destructive) {
                importCoordinator.cancel()
                // ⚠️ Refermer AUSSI la relecture éventuellement ouverte : sinon
                // l'inspecteur macOS restait affiché sur un résultat qui
                // n'existe plus (même classe de bug que la session annulée).
                showAnalysisReview = false
                showInvestmentReview = false
            }
            Button("Poursuivre", role: .cancel) {}
        } message: {
            // ⚠️ Le message affirmait « le document analysé n'est pas
            // conservé : il faudra le re-sélectionner » — devenu FAUX pour les
            // investissements depuis que l'analyse est persistée en session
            // (migration v45). Il reste vrai pendant l'analyse, où rien n'est
            // encore écrit en base.
            Text(importCoordinator.isReady
                 ? "Les opérations reconnues seront perdues : il faudra relancer l'analyse du document."
                 : "Le document en cours d'analyse ne sera pas conservé : il faudra le re-sélectionner.")
        }
        .onAppear {
            ensureValidSelection()
            appState.reloadActiveImportSession()
            consumePendingTransactionImport(appState.pendingTransactionImportURLs)
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
            #if os(macOS)
            // L'inspecteur est contextuel au module affiché → changement de
            // module = fermeture (reset du binding du call site inclus).
            paneCenter.dismissCurrent()
            #endif
        }
        #if os(macOS)
        .environment(paneCenter)
        .adaptivePane(isPresented: $showGlobalSearch) {
            SearchView()
        }
        #endif
    }

    /// Bandeau « import en cours », glissant depuis le bord où il est ancré.
    ///
    /// Deux états possibles, jamais les deux à la fois : une analyse de document
    /// en cours (ou prête à être relue), sinon une session d'import ouverte.
    @ViewBuilder
    private func importBanner(edge: Edge) -> some View {
        if importCoordinator.isActive {
            ImportAnalysisBanner(
                coordinator: importCoordinator,
                onOpen: { openAnalysisReview() },
                // Confirmation comme pour une session d'import : le résultat
                // d'analyse n'est PAS persisté, l'abandonner le perd pour de bon.
                onCancel: { showCancelAnalysisConfirm = true }
            )
            .transition(.move(edge: edge).combined(with: .opacity))
        } else if let summary = appState.activeImportSession {
            ImportSessionBanner(
                summary: summary,
                onTap: { appState.showImportSessionSheet = true },
                onCancel: { showCancelImportConfirm = true }
            )
            .transition(.move(edge: edge).combined(with: .opacity))
        }
    }

    /// Ouvre la relecture du résultat d'analyse, selon la destination choisie.
    private func openAnalysisReview() {
        switch importCoordinator.destination {
        case .transactions:
            showAnalysisReview = true
        case .investments:
            showInvestmentReview = true
        }
    }

    /// présente l'import V3 pré-rempli et libère les URL en attente
    /// (one-shot). No-op si vide ou si une sheet préchargée est déjà en cours.
    /// Miroir de `consumePendingInvestmentImport` dans InvestmentsView.
    private func consumePendingTransactionImport(_ urls: [URL]) {
        guard !urls.isEmpty, preloadedTransactionImport == nil else { return }
        preloadedTransactionImport = PreloadedTransactionImport(urls: urls)
        appState.pendingTransactionImportURLs = []
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

    /// Layout desktop : sidebar avec TOUS les modules (pas de limite
    /// à 4, pas d'onglet Plus) + section Outils. Chaque module garde sa propre
    /// NavigationStack dans sa colonne.
    ///
    /// ⚠️ Le split view doit rester la vue RACINE. Une V1 le wrappait dans un
    /// HStack (`HStack { NavigationSplitView; panneau }`) → le split view, qui
    /// veut être racine, négociait sa largeur en BOUCLE avec le HStack → la barre
    /// de fenêtre (et le bouton retour des vues poussées, ex. Tricount) vibrait
    /// en permanence. Le panneau est donc une COLONNE du split view, jamais un
    /// voisin posé à côté.
    private var sidebarLayout: some View {
        sidebarSplitView
    }

    /// ⚠️ `.id(selection)` sur la colonne du module est OBLIGATOIRE : sans elle,
    /// `NavigationSplitView` sur macOS ne détruit PAS l'état de navigation
    /// interne (push) de l'ancien module quand la sélection change — le contenu
    /// poussé (détail Tricount, détail compte/position Investissements…) reste
    /// affiché à l'écran, et seul un pop (bouton retour) force enfin le re-rendu
    /// vers le nouveau module. `.id()` force une identité de vue liée à l'onglet :
    /// au changement, SwiftUI démonte tout l'ancien sous-arbre (donc son
    /// `NavigationStack`/push interne) au lieu de tenter de le réutiliser.
    #if os(macOS)
    /// macOS — **trois colonnes** : sidebar · module · panneau.
    ///
    /// Le panneau est une VRAIE colonne de `NavigationSplitView`, et pas un
    /// `.inspector` ni un `HStack` custom, parce que c'est la seule construction
    /// qui reproduit le comportement des apps système (Mail, Notes) :
    ///
    /// 1. **Séparateur déplaçable** — l'utilisateur choisit la largeur du
    ///    panneau, AppKit la mémorise. L'ancien `HStack` la figeait à 440 pt.
    /// 2. **Barre d'outils scindée** — chaque colonne déclare sa propre
    ///    `.toolbar`, et macOS insère entre elles un séparateur de suivi
    ///    (`NSTrackingSeparatorToolbarItem`) aligné sur le séparateur de
    ///    colonnes. Les actions du module s'arrêtent donc au séparateur, celles
    ///    du panneau commencent après : l'appartenance de chaque groupe se lit
    ///    sans étiquette.
    ///
    /// > Mesuré : ni le `HStack` custom ni `.inspector` n'obtiennent le point 2.
    /// > Avec eux, tous les boutons s'entassent au bord droit de la fenêtre,
    /// > donc au-dessus du panneau — y compris ceux du module. Un
    /// > `ToolbarSpacer(.flexible)` n'y change rien (testé aux deux placements) :
    /// > le séparateur vient de la STRUCTURE en colonnes, pas de la barre.
    ///
    /// ⚠️ Répartition de la largeur — l'`ideal` du module est un COMPROMIS, pas
    /// une préférence esthétique. Dans un split view à 3 colonnes, c'est la
    /// colonne `detail` qui absorbe l'espace libre, et on redimensionne le
    /// panneau en tirant le bord de la colonne du MODULE. Les deux extrêmes sont
    /// donc mauvais, et ont été mesurés :
    ///
    /// - `ideal` du module très large (essai à 1 200) : le module veut toute la
    ///   place, le séparateur module|panneau devient **impossible à tirer** (le
    ///   séparateur sidebar|module, lui, répond toujours — c'est ce qui a permis
    ///   d'isoler la cause) et le panneau reste collé à son `min`.
    /// - Aucune contrainte sur le module : le panneau part à son `max` et
    ///   s'élargit avec la fenêtre, alors que c'est la liste du module qui a
    ///   besoin de la place.
    ///
    /// Valeurs retenues : le module a un `ideal` modéré (assez pour rester
    /// dominant, assez souple pour que le séparateur bouge) et le panneau un
    /// `max` qui l'empêche de manger la fenêtre.
    private var sidebarSplitView: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            sidebarList
                .navigationTitle("Nemoris")
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } content: {
            detailView(for: state.selectedTab)
                .id(state.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760, max: 1_400)
        } detail: {
            inspectorColumn
        }
        .tint(AppTheme.Colors.accent)
    }

    /// Colonne du panneau. Sans pane ouvert elle se REPLIE à zéro (vérifié : la
    /// colonne du module récupère alors toute la largeur) — un module comme le
    /// Dashboard n'a donc aucune place perdue, contrairement au troisième volet
    /// permanent d'un client mail.
    ///
    /// ⚠️ Seule la BRANCHE de cette colonne change quand un pane s'ouvre ; la
    /// colonne du module, elle, garde la même identité de vue. C'est ce qui
    /// préserve son `@State` (une version antérieure basculait entre
    /// `detailView` seul et `HStack { detailView; panneau }` : SwiftUI y voyait
    /// deux structures différentes, DÉTRUISAIT la vue du module à l'ouverture du
    /// panneau et la recréait — l'onglet courant de « Données » retombait sur
    /// Comptes, les filtres se vidaient…).
    ///
    /// Le panneau ne reçoit AUCUN chrome d'ici : son contenu déclare lui-même sa
    /// `.toolbar` (cf. `publishesInspectorChrome`), donc les actions sont toujours
    /// celles du rendu courant — jamais des closures périmées.
    @ViewBuilder
    private var inspectorColumn: some View {
        if let pane = paneCenter.pane {
            // `.id(pane.id)` : un pane re-présenté repart avec un @State frais
            // → cliquer une autre donnée change le détail sans passer par
            // « Fermer ».
            pane.content
                .id(pane.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Colors.background)
                .navigationSplitViewColumnWidth(
                    min: InspectorPaneMetrics.minWidth,
                    ideal: InspectorPaneMetrics.idealWidth,
                    max: InspectorPaneMetrics.maxWidth
                )
        } else {
            Color.clear
                .frame(width: 0)
                .navigationSplitViewColumnWidth(0)
        }
    }
    #else
    /// iOS / iPadOS — deux colonnes, comportement historique : les panes y sont
    /// des `.sheet` (cf. `adaptivePane`), il n'y a donc pas de troisième colonne
    /// à prévoir.
    private var sidebarSplitView: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            sidebarList
                .navigationTitle("Nemoris")
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailView(for: state.selectedTab)
                .id(state.selectedTab)
        }
        .tint(AppTheme.Colors.accent)
    }
    #endif

    @ViewBuilder
    private var sidebarList: some View {
        @Bindable var state = appState
        #if os(macOS)
        // Sélection pilotée MANUELLEMENT : la List `.sidebar` macOS dessine son
        // highlight de sélection avec la couleur d'accentuation SYSTÈME (bleu),
        // non recolorable via `.tint` (même limitation que les icônes). On retire
        // donc le binding `selection:` et on peint notre propre pastille ADN via
        // `.listRowBackground` (cf. sidebarRow). Contrepartie assumée : plus de
        // navigation clavier ↑/↓ entre modules (sidebar = clic).
        List {
            Section("Modules") {
                ForEach(availableTabs) { tab in
                    sidebarRow(title: tab.title, systemImage: tab.systemImage, tag: tab.rawValue)
                }
            }
            // ⚠️ Réglages n'est PAS un outil : c'est la configuration de l'app,
            // pas une action qu'on mène sur ses données. Le ranger avec
            // l'importation mettait sur le même plan « je traite un relevé » et
            // « je change mes préférences ».
            Section("Outils") {
                sidebarRow(title: "Importation", systemImage: "square.and.arrow.down", tag: sidebarImportTag)
            }
            Section {
                sidebarRow(title: "Réglages", systemImage: "gearshape", tag: sidebarSettingsTag)
            }
        }
        .listStyle(.sidebar)
        // Placement `.navigation` = segment de toolbar où macOS peint déjà le
        // bouton de bascule sidebar (auto-généré par `NavigationSplitView`) —
        // c'est ce qui met la loupe juste à côté de lui plutôt que noyée dans
        // la toolbar du module affiché.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PaneToggleButton(label: "Rechercher", systemImage: "magnifyingglass", isOn: $showGlobalSearch)
            }
        }
        #else
        // iOS / iPad : sélection native (le highlight suit le `.tint` ici).
        List(selection: Binding<String?>(
            get: { state.selectedTab },
            set: { if let value = $0 { state.selectedTab = value } }
        )) {
            Section("Modules") {
                ForEach(availableTabs) { tab in
                    sidebarLabel(tab.title, systemImage: tab.systemImage)
                        .tag(tab.rawValue)
                }
            }
            Section("Outils") {
                sidebarLabel("Importation", systemImage: "square.and.arrow.down")
                    .tag(sidebarImportTag)
            }
            // Section propre : cf. commentaire de la branche macOS.
            Section {
                sidebarLabel("Réglages", systemImage: "gearshape")
                    .tag(sidebarSettingsTag)
            }
        }
        .listStyle(.sidebar)
        #endif
    }

    #if os(macOS)
    /// Row de sidebar macOS à sélection custom. On reproduit le highlight NEUTRE
    /// de macOS (façon Mail : gris translucide) plutôt que le highlight bleu
    /// système accent — non recolorable via `.tint`. L'icône reste verte (ADN),
    /// le libellé passe en semibold quand sélectionné (emphase à la Mail).
    ///
    /// Sélection sur un `Button` (pas `onTapGesture`) : hit-testing immédiat et
    /// feedback au clic — l'`onTapGesture` sur une row de List donnait un ressenti
    /// "mou". Reste custom (pas de nav clavier ↑/↓, prix de la couleur non-bleue).
    @ViewBuilder
    private func sidebarRow(title: String, systemImage: String, tag: String) -> some View {
        let isSelected = appState.selectedTab == tag
        Button {
            appState.selectedTab = tag
        } label: {
            Label {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
        )
    }
    #endif

    /// Sur macOS, une `Label` dans une `List` `.listStyle(.sidebar)` teinte son
    /// icône avec `controlAccentColor` (réglage système "Couleur d'accentuation"),
    /// pas avec l'environnement `.tint()`/`accentColor` de SwiftUI — d'où les icônes
    /// bleues malgré le `.tint(AppTheme.Colors.accent)` posé plus haut. Seul un
    /// `.foregroundStyle` explicite sur l'icône (natif, pas de hack AppKit) permet
    /// de forcer la couleur ADN ici.
    private func sidebarLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.Colors.accent)
        }
    }

    @ViewBuilder
    private func detailView(for selection: String) -> some View {
        if selection == sidebarSettingsTag {
            NavigationStack { SettingsView(isEmbedded: true) }
        } else if selection == sidebarImportTag {
            NavigationStack {
                ImportEntryView(initialDestination: appState.importToolRequest ?? .transactions,
                                  isEmbedded: true)
            }
        } else if let tab = MainTabItem(rawValue: selection) {
            tabView(for: tab)
        } else {
            // Sélection transitoire invalide ("more" pendant la bascule) —
            // ensureValidSelection corrige juste après.
            tabView(for: .dashboard)
        }
    }

    // ⚠️ Délègue à `AppState.availableTabsResolved` — ne PAS dupliquer le
    // switch ici. Une copie locale existait avant et n'avait jamais été mise
    // à jour quand `.transactions`/`.referenceData` ont rejoint le filtre
    // (elle retombait sur `return true`, donc le toggle Transactions des
    // Réglages n'avait strictement aucun effet). Un seul filtre, une seule
    // fois — même doctrine que les calculs d'enveloppes budgétaires.
    private var availableTabs: [MainTabItem] { appState.availableTabsResolved }

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
    /// Path de navigation contrôlé. Sert à push programmatiquement quand l'utilisateur
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
                // destination était déjà ouverte (l'utilisateur fait 2 fois la navigation).
                navPath = [tab]
                // Consommé → clear pour ne pas re-push à chaque rebuild.
                appState.pendingMoreDestination = nil
            }
            .onAppear {
                // Cas où l'utilisateur atteint MoreView avec une destination déjà pending
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
                label: "Importation",
                icon: "square.and.arrow.down",
                color: AppTheme.Colors.success,
                destination: { AnyView(ImportEntryView(isEmbedded: true)) }
            ),
            MoreItem(
                label: "Paramètres",
                icon: "gearshape",
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
    //
    // Catalogue partagé avec `SearchView` — cf. `FeatureCatalog.swift`.

    private func filteredFeatures() -> [FeatureEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return FeatureCatalog.entries(for: appState) }
        return FeatureCatalog.matching(q, in: appState)
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
            NavigationLink(destination: ImportEntryView(isEmbedded: true)) {
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

// `FeatureTarget` / `FeatureEntry` : cf. `Features/Search/Service/FeatureCatalog.swift`
// (partagés avec `SearchView`).
