import SwiftUI
import Charts
import TipKit

// MARK: - DashboardView (Annual)

/// Dashboard en **page éditoriale** (refonte 2026-06-01, restructuré 2026-07-29).
///
/// Avant 2026-06 : pile de cards uniformes qui hiérarchisait tout au même niveau
/// visuel → effet "tableau de bord d'admin". Les composants `AppChartCard` et
/// `PremiumDashboardSummaryCard` ne sont donc plus utilisés ici — l'impact vient de
/// la typo, du dégradé et de l'espacement, pas du fond blanc/encadré.
///
/// Restructuration 2026-07 :
///   • les données viennent de `DashboardSnapshotStore` (calcul hors main thread,
///     cache par agrégat) — cette vue ne fait plus aucune requête ;
///   • le hero est à **deux niveaux** : mois dominant + cumul annuel discret ;
///   • les trois bandeaux Investissements / Patrimoine / Budget, qui étaient trois
///     copies quasi identiques empilées sur ~3 écrans de scroll, ont fusionné dans
///     `DashboardOverviewBanner`.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    /// Injecté une seule fois dans `NemorisApp` — cette vue est instanciée deux fois
    /// (TabView iOS + volet détail de la sidebar macOS) et deux `@State` voudraient
    /// dire deux caches, donc tout calculé deux fois.
    @Environment(DashboardSnapshotStore.self) private var store
    /// Entitlement Pro — pour que la disponibilité des cartes (bandeau + grille +
    /// écran de personnalisation) reflète l'abonnement réel, pas seulement le flag
    /// module persisté (cf. `AppState.isDashboardCardAvailable`).
    @Environment(PurchaseManager.self) private var purchaseManager
    /// Sélection de l'utilisateur (exercice + filtre mois). Seul état local restant :
    /// les données, elles, vivent dans le store.
    @State private var period = DashboardPeriod(
        year: Calendar.current.component(.year, from: Date()),
        month: nil
    )
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showCustomize = false
    @State private var showApplePayPending = false
    #if os(macOS)
    /// macOS : pour fermer le panneau au moment où « Personnaliser » remplace
    /// le dashboard (cf. `body`) — sinon un panneau Import/Recherche déjà
    /// ouvert resterait affiché, orphelin, par-dessus l'écran de personnalisation.
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif

    private let availableYears: [Int] = {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current).reversed()
    }()

    var isEmbedded: Bool = false

    // MARK: - Accès aux données du snapshot
    //
    // `nil` dans le snapshot = pas encore calculé. On retombe sur la valeur vide, ce
    // qui reproduit exactement le rendu précédent (les sections se masquent seules
    // quand leur collection est vide).

    private var monthlyData: [MonthlyTotals]      { store.snapshot.monthlySeries ?? [] }
    private var stats: DashboardStats             { store.snapshot.stats ?? .empty }
    private var previousYearStats: DashboardStats { store.snapshot.previousYearStats ?? .empty }
    private var alerts: [Alert]                   { store.snapshot.alerts ?? [] }
    private var investmentsRecap: InvestmentsRecap    { store.snapshot.investments ?? .empty }
    private var patrimoineSnapshot: PatrimoineSnapshot { store.snapshot.patrimoine ?? .empty }
    private var budgetRecap: BudgetRecap          { store.snapshot.budget ?? .empty }

    // MARK: - Colonnes du bandeau « Vue d'ensemble »
    //
    // Une colonne n'apparaît que si le module est activé ET qu'il y a une donnée à
    // montrer. Gater sur l'activation est nouveau : avant, un bandeau pouvait mener
    // vers un onglet que l'utilisateur avait désactivé dans les Réglages.

    private func isModuleAvailable(_ tab: MainTabItem) -> Bool {
        guard appState.availableTabsResolved.contains(tab) else { return false }
        guard let feature = tab.paywallFeature else { return true }
        return purchaseManager.isUnlocked(feature)
    }

    private var overviewInvestments: InvestmentsRecap? {
        guard isModuleAvailable(.investments), investmentsRecap.hasData else { return nil }
        return investmentsRecap
    }

    private var overviewPatrimoine: PatrimoineSnapshot? {
        guard isModuleAvailable(.patrimoine), patrimoineSnapshot.hasData else { return nil }
        return patrimoineSnapshot
    }

    private var overviewBudget: BudgetRecap? {
        guard isModuleAvailable(.budget), budgetRecap.hasData else { return nil }
        return budgetRecap
    }

    /// Agrégats à calculer : ceux des éléments fixes + ceux des cartes réellement
    /// affichées. **Une carte masquée ne coûte donc aucune requête** — c'est tout
    /// l'intérêt d'avoir déclaré les dépendances dans le registre.
    private var requiredUnits: Set<DashboardAggregate> {
        var units = DashboardAggregate.fixedElements
        for preference in appState.visibleDashboardCards(purchaseManager: purchaseManager) {
            units.formUnion(preference.card.dependencies)
        }
        return units
    }

    private var cacheKey: DashboardCacheKey {
        DashboardCacheKey(refreshToken: appState.dataRefreshToken, period: period)
    }

    /// Identité de la `.task` : la clé de cache **et** les agrégats demandés. Sans les
    /// unités, réafficher une carte masquée ne relancerait aucun calcul et la carte
    /// resterait sur son squelette.
    private struct LoadIdentity: Hashable {
        let key: DashboardCacheKey
        let units: Set<DashboardAggregate>
    }

    private var loadIdentity: LoadIdentity {
        LoadIdentity(key: cacheKey, units: requiredUnits)
    }

    /// La carte d'accueil « importez un CSV » ne concerne qu'un utilisateur sans
    /// données. On la restreint à l'exercice courant : sur un exercice passé et vide,
    /// c'est un résultat normal, pas un état d'onboarding.
    private var showsOnboardingCard: Bool {
        // `nil` = pas encore calculé : sans cette garde, l'écran d'accueil
        // clignoterait pendant la première passe.
        guard let series = store.snapshot.monthlySeries else { return false }
        return series.isEmpty && period.year == Calendar.current.component(.year, from: Date())
    }

    private func selectYear(_ year: Int) {
        period = DashboardPeriod(year: year, month: nil)
    }

    var body: some View {
        #if os(macOS)
        // macOS : personnalisation en navigation PAR ÉTAT, pas un push. Le
        // dashboard reste accessible (toolbar propre) pendant qu'un panneau
        // Import/Recherche est ouvert (volet non modal) — un push ici masquait
        // ce panneau derrière l'écran de personnalisation jusqu'au retour à la
        // racine (AppKit/NavigationStack « Panneau
        // macOS masqué par du contenu poussé »). Même remède que Réglages/
        // Investissements/Tricount.
        if showCustomize {
            DashboardCustomizeView(onBack: {
                paneCenter?.dismissCurrent()
                showCustomize = false
            })
            .environment(appState)
            .environment(purchaseManager)
        } else if isEmbedded {
            navBody
        } else {
            NavigationStack { navBody }
        }
        #else
        if isEmbedded { navBody } else { NavigationStack { navBody } }
        #endif
    }

    @ViewBuilder private var navBody: some View {
        // GeometryReader **à la racine, hors du ScrollView** : c'est lui qui donne le
        // nombre de colonnes de la grille. À l'intérieur du ScrollView il recevrait
        // une hauteur proposée dégénérée. `onGeometryChange` serait plus élégant mais
        // demande macOS 15+, or la cible du projet est macOS 14.
        GeometryReader { geometry in
            scrollBody(availableWidth: geometry.size.width)
        }
    }

    @ViewBuilder private func scrollBody(availableWidth: CGFloat) -> some View {
        ZStack(alignment: .top) {
            AppTheme.Colors.background.ignoresSafeArea()
            // Dégradé éditorial du top : accent → background. Sur 360pt seulement
            // pour ne pas baigner toute la scroll view dans la teinte verte.
            heroBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    yearPicker
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)

                    // Chargement PROGRESSIF : chaque bloc décide lui-même s'il a de
                    // quoi s'afficher. Plus de squelette global qui masquerait tout
                    // l'écran en attendant l'agrégat le plus lent.

                    // Alertes — visibles seulement si l'engine a remonté quelque chose
                    // d'actionnable. En tête pour maximiser la visibilité.
                    if !alerts.isEmpty {
                        AlertsBanner(alerts: alerts)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.md)
                    }

                    // Affiché à part des totaux — jamais dans le hero/les
                    // enveloppes tant que ces dépenses n'ont pas été résolues.
                    if let count = store.snapshot.pendingApplePayCount, count > 0 {
                        ApplePayPendingBanner(
                            count: count,
                            total: store.snapshot.pendingApplePayTotal ?? 0,
                            onTap: { showApplePayPending = true }
                        )
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.md)
                    }

                    Group {
                        if store.snapshot.stats == nil {
                            heroSkeleton
                        } else {
                            editorialHero
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.xl)

                    if showsOnboardingCard {
                        // Comme Investissements : c'est la navigation RACINE qui
                        // décide où afficher l'outil d'import (destination à
                        // part entière sur desktop, pane sur iPhone) — pas un
                        // panneau collé au Dashboard (retour d'usage).
                        OnboardingImportCard { appState.openImportTool(destination: .transactions) }
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.xxxl)
                    } else {
                        // Vue d'ensemble : une seule bande pour les 3 modules, au
                        // lieu de 3 bandeaux pleine largeur empilés. Se masque seule
                        // tant qu'aucune colonne n'a de donnée.
                        DashboardOverviewBanner(
                            investments: overviewInvestments,
                            patrimoine: overviewPatrimoine,
                            budget: overviewBudget,
                            onSelect: { appState.navigateToTab($0) }
                        )
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.xxl)

                        cardGrid(width: availableWidth)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.xxl)
                    }
                }
                .padding(.bottom, AppTheme.Spacing.xxxl)
            }
        }
        .localizedNavigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Recherche globale cross-modules (cmd-K style).
                // ⚠️ iOS UNIQUEMENT : sur macOS, la loupe vit
                // maintenant à côté du toggle de sidebar (`MainTabView`,
                // toujours visible quel que soit le module affiché) — la
                // garder ICI AUSSI faisait apparaître DEUX loupes dans la
                // même fenêtre dès que Dashboard était le module courant.
                // Sur iOS, Dashboard reste le seul point d'entrée (pas de
                // sidebar), donc inchangé.
                #if !os(macOS)
                PaneToggleButton(label: "Rechercher", systemImage: "magnifyingglass", isOn: $showSearch)
                #endif
                // Toggle rapide de masquage — discret mais toujours accessible
                // depuis le hub principal de l'app. Animation snappy pour confirmer
                // visuellement que le toggle a bien été pris en compte.
                Button {
                    HapticService.shared.toggle()
                    withAnimation(AppTheme.Animations.springSnappy) {
                        appState.amountsHidden.toggle()
                    }
                } label: {
                    Image(systemName: appState.amountsHidden ? "eye.slash.fill" : "eye")
                        .foregroundStyle(appState.amountsHidden ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                }
                // Un Menu plutôt qu'un 4ᵉ bouton : trois icônes tiennent déjà tout
                // juste dans la barre sur iPhone.
                Menu {
                    Button {
                        showCustomize = true
                    } label: {
                        Label("Personnaliser le tableau de bord", systemImage: "square.grid.2x2")
                    }
                    Button {
                        #if os(macOS)
                        // macOS : les Réglages existent déjà comme destination de la
                        // sidebar. Les présenter en sheet les rendait non bornés (plus
                        // grands que la fenêtre) et infermables (pas de swipe-down). On
                        // route vers le volet détail à la place.
                        appState.selectedTab = AppState.sidebarSettingsTag
                        #else
                        showSettings = true
                        #endif
                    } label: {
                        Label("Réglages", systemImage: "gearshape.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            // Cf. CLAUDE.md §5 : ré-injection \.locale obligatoire pour toute
            // `.sheet()` niveau 2+ atteignable sur macOS.
            SettingsView().environment(appState)
                .environment(\.locale, AppLocalization.locale)
        }
        // macOS : géré par `body` (navigation par état — cf. commentaire dessus).
        // iOS : sheet classique, `DashboardCustomizeView` reste poussable/dismissable
        // nativement via son propre `dismiss()`.
        #if !os(macOS)
        .sheet(isPresented: $showCustomize) {
            NavigationStack {
                DashboardCustomizeView()
                    .environment(appState)
                    .environment(purchaseManager)
            }
        }
        #endif
        .adaptivePane(isPresented: $showSearch) {
            SearchView().environment(appState)
        }
        .adaptivePane(isPresented: $showApplePayPending) {
            PendingApplePayListView().environment(appState)
        }
        // Une seule clé pour les 3 dimensions (données mutées, exercice, filtre mois)
        // plutôt que trois `.task(id:)` empilés. Le store ne recalcule que les
        // agrégats dont la clé restreinte a réellement changé.
        //
        // ⚠️ Ce chargement ne doit JAMAIS bumper `appState.dataRefreshToken` : ce
        // serait une boucle infinie (précédent documenté dans `InvestmentsView`).
        .task(id: loadIdentity) {
            // 1-frame guard : laisse le skeleton se peindre au moins une fois avant
            // que le premier snapshot ne le remplace, sinon sur une base déjà chaude
            // on aurait un flash de la layout vide.
            await Task.yield()
            await store.load(units: requiredUnits, key: cacheKey)
        }
    }

    // MARK: - Grille de cartes

    /// Les cartes choisies par l'utilisateur, réparties en lignes par
    /// `DashboardGridPlanner` : une carte large occupe sa ligne, les compactes se
    /// groupent jusqu'au nombre de colonnes autorisé par la largeur.
    @ViewBuilder private func cardGrid(width: CGFloat) -> some View {
        let columns = DashboardLayoutMetrics.columnCount(for: width)
        let rows = DashboardGridPlanner.rows(appState.visibleDashboardCards(purchaseManager: purchaseManager), columns: columns)
        let context = DashboardCardContext(
            period: $period,
            onNavigate: { appState.navigateToTab($0) }
        )

        LazyVStack(spacing: AppTheme.Spacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    ForEach(row) { preference in
                        DashboardCardHost(
                            preference: preference,
                            snapshot: store.snapshot,
                            context: context
                        )
                    }
                }
            }
        }
    }

    // MARK: - Hero backdrop (gradient subtil sur le top)

    /// Dégradé accent → background sur 360pt en haut de l'écran. Donne l'impression
    /// que le hero "émerge" du chrome de l'app, sans introduire un bandeau coloré
    /// brutal. Opacité 0.18 en dark, 0.12 en light pour rester sobre.
    @ViewBuilder private var heroBackdrop: some View {
        LinearGradient(
            colors: [
                AppTheme.Colors.accent.opacity(0.18),
                AppTheme.Colors.background.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 360)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Skeleton

    /// Squelette du **hero seul**. Le reste de l'écran n'en a plus besoin : le bandeau
    /// « Vue d'ensemble » se masque tant qu'il n'a rien à montrer, et chaque tuile de
    /// la grille porte son propre squelette. C'est ce que permet le snapshot à champs
    /// optionnels — avant, un squelette unique masquait tout l'écran jusqu'à ce que
    /// le dernier agrégat (le coach, qui scanne 180 jours) soit arrivé.
    @ViewBuilder private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SkeletonLine(width: 120, height: 11)
            SkeletonLine(width: 260, height: 40)
            SkeletonLine(width: 180, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Year Picker

    private var yearPicker: some View {
        HStack {
            Text("Exercice")
                .font(AppTheme.Typography.labelLarge)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Picker("Année", selection: Binding(
                get: { period.year },
                set: { selectYear($0) }
            )) {
                ForEach(availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AppTheme.Colors.accent)
        }
    }

    // MARK: - Editorial Hero (double niveau)

    /// Le bloc dominant de l'écran, sur **deux niveaux de lecture** :
    ///   1. le gros chiffre = la période la plus fine sélectionnée — le mois en cours
    ///      par défaut, le mois filtré si l'utilisateur en a choisi un ;
    ///   2. une ligne secondaire discrète = le cumul de l'exercice + la variation N-1.
    ///
    /// Pourquoi : un bilan **annuel** en chiffre dominant ne dit pas quoi faire
    /// aujourd'hui. En juillet, « −5 144 € sur 2026 » est un constat ; « −412 € ce
    /// mois-ci » est actionnable. Le cumul annuel reste à un coup d'œil dessous.
    ///
    /// **Pas de card**, pas de fond — le dégradé du backdrop fait le travail.
    @ViewBuilder private var editorialHero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            heroEyebrow
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Big number — via MoneyText pour respecter le masquage global.
            MoneyText(
                amount: heroNet,
                font: .system(size: 44, weight: .bold, design: .default),
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            heroSecondaryLine

            // Pied : Recettes · Dépenses de la MÊME période que le big number, sinon
            // les trois chiffres du hero ne parleraient pas de la même chose.
            HStack(spacing: AppTheme.Spacing.lg) {
                heroStatPill(
                    icon: "arrow.down.right",
                    label: "Recettes",
                    value: heroIncome,
                    color: AppTheme.Colors.success
                )
                heroStatPill(
                    icon: "arrow.up.right",
                    label: "Dépenses",
                    value: heroExpense,
                    color: AppTheme.Colors.danger
                )
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Second niveau : cumul de l'exercice quand le gros chiffre est mensuel, puis la
    /// variation vs N-1 quand elle a du sens. Volontairement en 13pt : c'est un
    /// repère, pas une information concurrente du big number.
    @ViewBuilder private var heroSecondaryLine: some View {
        let prevNet = previousYearStats.netBalance
        let delta = stats.netBalance - prevNet
        let hasComparison = previousYearStats.totalIncome != 0 || previousYearStats.totalExpense != 0
        let deltaPercent: Double = {
            guard hasComparison, abs(prevNet) > 0.01 else { return 0 }
            return delta / abs(prevNet) * 100
        }()

        if isMonthDominant || hasComparison {
            HStack(spacing: AppTheme.Spacing.xs) {
                if isMonthDominant {
                    Text("Cumul \(period.year.yearLabel)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    MoneyText(
                        amount: stats.netBalance,
                        font: .system(size: 13, weight: .semibold),
                        color: AppTheme.Colors.textPrimary,
                        maskedPlaceholder: "••• €"
                    )
                    if hasComparison {
                        Text("·")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                }
                if hasComparison {
                    HStack(spacing: 3) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        if abs(deltaPercent) > 0.01 {
                            Text(String(format: "%@%.1f %%", delta >= 0 ? "+" : "", deltaPercent))
                                .font(.system(size: 13, weight: .semibold))
                        } else {
                            Text(delta, format: .currency(code: "EUR").presentation(.narrow))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text("vs \((period.year - 1).yearLabel)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .foregroundStyle(delta >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Période dominante du hero

    /// Mois mis en avant : celui filtré par l'utilisateur, sinon le mois en cours
    /// quand on regarde l'exercice courant. `nil` sur un exercice passé — « ce
    /// mois-ci » n'aurait alors aucun sens, on retombe sur le bilan annuel.
    private var heroMonthKey: String? {
        if let month = period.month { return month }
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.year, from: now) == period.year else { return nil }
        return String(format: "%04d-%02d", period.year, calendar.component(.month, from: now))
    }

    private var isMonthDominant: Bool { heroMonthKey != nil }

    /// Totaux du mois dominant. Un mois sans transaction n'est pas une absence de
    /// donnée : c'est un mois à 0 €, et l'afficher est plus juste que de retomber
    /// silencieusement sur l'année.
    private var heroMonthTotals: MonthlyTotals? {
        guard let key = heroMonthKey else { return nil }
        return monthlyData.first { $0.month == key }
            ?? MonthlyTotals(month: key, income: 0, expense: 0)
    }

    private var heroNet: Double {
        guard let totals = heroMonthTotals else { return stats.netBalance }
        return totals.income + totals.expense
    }

    private var heroIncome: Double { heroMonthTotals?.income ?? stats.totalIncome }
    private var heroExpense: Double { heroMonthTotals?.expense ?? stats.totalExpense }

    private var heroEyebrow: Text {
        if let label = period.monthLabel { return Text(label) }
        if isMonthDominant { return Text("Ce mois-ci") }
        return Text("Bilan annuel · \(period.year)")
    }

    /// Petite "pilule" stat utilisée dans le pied du hero. Reste alignée gauche,
    /// pas de fond pour ne pas concurrencer le big number. Juste icône colorée +
    /// montant en `moneySmall` + label en très petit.
    @ViewBuilder
    private func heroStatPill(icon: String, label: LocalizedStringKey, value: Double, color: Color) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                MoneyText(
                    amount: abs(value),
                    font: AppTheme.Typography.moneySmall,
                    color: AppTheme.Colors.textPrimary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }

}
