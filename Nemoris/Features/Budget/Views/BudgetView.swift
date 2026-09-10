import SwiftUI
import Charts
import TipKit

/// Hauteur réelle du panneau de détail du jour ouvert dans le calendrier
/// (`DayDetailPanel`) — remontée par mesure plutôt qu'estimée, son contenu
/// (0 à N prévisions + 0 à N transactions) n'a pas de taille fixe. Seul
/// consommateur : `BudgetView.calendarCarouselHeight`.
private struct DayDetailHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - BudgetView (entry point)
struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = BudgetViewModel()
    @State private var calendarDays: [CalendarDay] = []
    @State private var selectedDay: CalendarDay?
    @State private var summary: MonthlyBudgetSummary?
    @State private var apercuPresentation: ApercuPresentation? = nil
    @State private var txCache: [String: [FinanceTransaction]] = [:]
    @State private var allTiers: [Tiers] = []
    @State private var allCategories: [Category] = []
    private let referenceRepo = TransactionRepository()
    // Carrousel de mois — remplace l'ancien geste de swipe custom (snapshot
    // qui glissait, mois cible chargé APRÈS relâchement, d'où la sensation
    // de "ça recharge"). `pageMonths` est une fenêtre de 3 mois [M-1, M, M+1]
    // rendue par un `TabView(.page)` NATIF : le doigt suit du contenu RÉEL
    // déjà pré-rendu des deux côtés (même prefetch que l'ancien système,
    // cf. `loadData()`), sans geste maison à réinventer — cf. retour
    // d'usage "comme si on avait une scrollview horizontale qui figeait sur
    // la vue du mois". `pageIndex` ne bouge QUE par la pagination native
    // (swipe ou changement programmatique animé) ; dès qu'il s'éloigne de 1,
    // `.onChange` traduit ça en vrai changement de mois côté ViewModel, puis
    // `.onChange(of: vm.displayedMonth)` recentre la fenêtre SANS animation
    // (`Transaction.disablesAnimations`) pour que ce recentrage soit invisible.
    @State private var pageMonths: [Date] = []
    @State private var pageIndex: Int = 1
    @State private var previsionPendingChoice: BudgetPrevision?
    @State private var showMonthYearPicker = false
    /// Coach dépenses — déplacé depuis Transactions (2026-08-29), qui reste un
    /// pur explorateur de transactions. L'analyse budgétaire a sa place ici.
    @State private var showCoach = false
    // Groupes repliables de la carte "Récurrents" — état par groupe, pas un
    // seul bool : replier "7 prochains jours" ne doit pas affecter "Ce mois".
    // "Ce mois" replié par défaut (généralement la plus longue des deux
    // listes) ; "7 prochains jours" reste ouvert, c'est l'horizon le plus
    // actionnable (retour d'usage 2026-08-26).
    @State private var upcomingExpanded = true
    @State private var thisMonthExpanded = false

    /// Skeleton uniquement sur la 1ère ouverture (ou sur un changement de mois non-caché).
    /// Voir `loadData()` qui met à `true` quand le mois cible est absent du cache.
    @State private var isInitialLoading = true

    /// Hauteur RÉELLE de `DayDetailPanel` telle que remontée par
    /// `DayDetailHeightPreferenceKey` — jamais une constante, cf.
    /// `calendarCarouselHeight`.
    @State private var measuredDetailHeight: CGFloat = 0

    var isEmbedded: Bool = false

    #if os(macOS)
    /// Sous-écran du module ouvert en navigation PAR ÉTAT (jamais un push).
    enum BudgetSection: Identifiable {
        case envelopes, recurring
        var id: Self { self }
        var title: String {
            switch self {
            case .envelopes: return "Enveloppes"
            case .recurring: return "Récurrents"
            }
        }
    }
    @State private var pushedSection: BudgetSection?
    /// Pour fermer le panneau en revenant au calendrier.
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?

    /// Sous-écran en pleine page + retour vers le calendrier.
    @ViewBuilder
    private func budgetSectionPage(_ section: BudgetSection) -> some View {
        Group {
            switch section {
            case .envelopes: EnvelopeListView(vm: vm)
            case .recurring: RecurringManagementView(vm: vm)
            }
        }
        // ⚠️ Résolution explicite, jamais un littéral/`LocalizedStringKey` nu :
        // `.navigationTitle` ponte vers la chrome native (barre de titre macOS),
        // qui ne respecte pas fiablement `\.locale` forcé par l'app. Cf. CLAUDE.md §5.
        .localizedNavigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    paneCenter?.dismissCurrent()
                    pushedSection = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Budget")
                .localizedAccessibilityLabel("Budget")
            }
        }
    }
    #endif

    /// Symboles de jours pour l'en-tête de la grille calendrier — un seul
    /// caractère, semaine commençant le lundi (`leadingEmpty` fige cet ordre
    /// indépendamment de `Calendar.current.firstWeekday`). Dérivés de
    /// `appState.locale` (pas `Locale.current`) pour suivre le réglage de
    /// langue de l'app plutôt que celui, potentiellement différent, de l'appareil.
    private var weekdaySymbols: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = appState.locale
        let symbols = cal.veryShortWeekdaySymbols  // index 0 = dimanche
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[1...]) + [symbols[0]]  // lundi … dimanche
    }

    var body: some View {
        Group {
            #if os(macOS)
            // Sous-écran ouvert → il REMPLACE le contenu du module (navigation
            // par état, avec son propre retour). Cf. commentaire de la toolbar.
            if let section = pushedSection {
                budgetSectionPage(section)
            } else if isEmbedded {
                navContent
            } else {
                NavigationStack { navContent }
            }
            #else
            if isEmbedded { navContent } else { NavigationStack { navContent } }
            #endif
        }
        // `.task` et NON `.onAppear` : dans la colonne détail d'un
        // `NavigationSplitView` macOS, `.onAppear` n'est pas fiable — il ne se
        // déclenchait pas ici, et le module s'affichait donc vide (« Aucun
        // récurrent », budget à 0 €) alors que la base contenait les données.
        // Le calendrier, lui, se chargeait : il passe par un `.task(id:)`.
        .task {
            vm.onAppear()
            if allTiers.isEmpty { allTiers = referenceRepo.fetchTiers() }
            if allCategories.isEmpty { allCategories = referenceRepo.fetchCategories() }
        }
        .adaptivePane(isPresented: $vm.showDetectionSheet) {
            DetectionResultsSheet(vm: vm)
        }
        .paywallOverlay(for: .budget)
        .previsionDeletionConfirmation(target: $previsionPendingChoice, vm: vm)
    }

    // MARK: - Main Content

    @ViewBuilder private var navContent: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                // `.frame(maxWidth: .infinity)` explicite : un `ScrollView`
                // propose sa largeur dispo à son contenu, mais un `VStack`
                // dont aucun enfant direct ne force `.infinity` reste replié
                // sur sa largeur intrinsèque — sur macOS (colonne détail
                // large), ça se traduisait par un calendrier collé au coin
                // haut-gauche avec tout le reste de la fenêtre vide (retour
                // d'usage 2026-08-26, capture à l'appui).
                VStack(spacing: AppTheme.Spacing.md) {

                    // Month navigation — les flèches jouent la MÊME transition
                    // de page native que le swipe (`pageIndex` change,
                    // `.onChange` fait le reste) ; le libellé mois/année est
                    // maintenant un bouton qui ouvre le sélecteur rapide
                    // (retour d'usage : "faire de l'affichage du mois et de
                    // l'année ... des boutons pour sélectionner le mois et
                    // l'année").
                    MonthNavigationView(
                        vm: vm,
                        onPrevious: goToPreviousMonth,
                        onNext: goToNextMonth,
                        onToday: { vm.goToCurrentMonth() },
                        onSelectMonthYear: { showMonthYearPicker = true }
                    )
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.sm)

                    if isInitialLoading {
                        budgetSkeleton
                    } else {
                        calendarCarousel
                            .background(AppTheme.Colors.background)

                        // Récurrents à venir : 1 carte, 2 groupes repliables
                        // (au lieu de 2 cartes empilées) — déclutter la vue.
                        recurringPrevisionsCard

                        // Empty state when no patterns
                        if vm.patterns.isEmpty {
                            // macOS : le menu "⋯" a été aplati en boutons dans la
                            // barre d'outils — le message doit suivre, sinon il
                            // renvoie vers un menu qui n'existe plus.
                            #if os(macOS)
                            EmptyStateView(
                                icon: "arrow.clockwise.circle",
                                title: "Aucun récurrent",
                                message: "Utilisez la baguette magique dans la barre d'outils pour détecter vos dépenses récurrentes."
                            )
                            .padding(.horizontal, AppTheme.Spacing.md)
                            #else
                            EmptyStateView(
                                icon: "arrow.clockwise.circle",
                                title: "Aucun récurrent",
                                message: "Utilisez le menu ··· pour détecter vos dépenses récurrentes."
                            )
                            .padding(.horizontal, AppTheme.Spacing.md)
                            #endif
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.xxxl)
                }
                .frame(maxWidth: .infinity)
            }
            .animation(AppTheme.Animations.springSnappy, value: selectedDay?.id)
            .task(id: vm.displayedMonth) { await loadData() }
            .onAppear { syncPagerToDisplayedMonth(animated: false) }
            .onChange(of: pageIndex) { _, new in
                // Le carrousel a fini une transition (swipe utilisateur OU
                // flèche programmatique, cf. `MonthNavigationView`) — `1`
                // reste le centre, seul un écart en est le signe.
                guard new != 1 else { return }
                if new == 2 { vm.nextMonth() } else { vm.previousMonth() }
                selectedDay = nil
                HapticService.shared.selection()
            }
            .onChange(of: vm.displayedMonth) { _, _ in
                // `pageIndex == 1` ⇒ le changement ne vient PAS d'un
                // page-turn du carrousel (donc "aujourd'hui", le sélecteur
                // mois/année, ou le scrubber) → un fondu est approprié. Sinon
                // (0 ou 2) c'est un recentrage post-swipe : DOIT rester
                // invisible, sous peine de re-glisser par-dessus la
                // transition native qui vient de jouer.
                syncPagerToDisplayedMonth(animated: pageIndex == 1)
            }
            .onChange(of: vm.previsions) { _, _ in
                // Transactions du mois déjà en cache dans l'immense majorité des cas
                // (posées par `loadData()`) → recalcul synchrone, pas de aller-retour
                // SQL pour un simple skip/match/edit de récurrent.
                if let txs = txCache[monthKey(vm.displayedMonth)] {
                    summary = vm.monthlySummary(transactions: txs)
                } else {
                    Task { summary = await vm.monthlySummary() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Transparent spacer keeps scroll content from hiding behind bubble
                Color.clear.frame(height: summary != nil ? 76 : 0)
            }

            // Bubble is a ZStack overlay — completely outside the ScrollView gesture scope
            // so the DragGesture never interferes with button tap recognition.
            VStack(spacing: 0) {
                Spacer()
                if let s = summary {
                    HStack {
                        Spacer()
                        BudgetSummaryBubble(summary: s, month: vm.displayedMonth) {
                            apercuPresentation = ApercuPresentation(
                                summary: summary, days: calendarDays, month: vm.displayedMonth
                            )
                        }
                        Spacer()
                    }
                    .padding(.bottom, 12)
                    .sensoryFeedback(.impact, trigger: apercuPresentation?.id)
                }
            }
            .allowsHitTesting(summary != nil)
        }
        // Swipe à deux doigts sur trackpad = changement de mois (no-op sur
        // iOS, qui a déjà le swipe natif du `TabView(.page)`). Partage les
        // mêmes déclencheurs que les flèches de `MonthNavigationView`.
        .trackpadMonthSwipe(onPrevious: goToPreviousMonth, onNext: goToNextMonth)
        .adaptivePane(item: $apercuPresentation) { p in
            BudgetApercuSheet(summary: p.summary, days: p.days, month: p.month, categories: vm.categories, allTiers: allTiers, allCategories: allCategories)
        }
        .adaptivePane(isPresented: $showMonthYearPicker) {
            MonthYearPickerSheet(month: vm.displayedMonth) { picked in
                jumpToMonth(picked)
            }
        }
        .adaptivePane(isPresented: $showCoach) {
            CoachView(domain: .transactions)
        }
        .localizedNavigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(macOS)
            // macOS : actions en boutons icône (pas de menu "⋯"), et surtout
            // AUCUN `NavigationLink` — un push depuis un module désynchronise la
            // sidebar et, dans une toolbar, déclenchait un crash. Les deux
            // destinations passent par un état (cf. `pushedSection`), comme dans
            // Investissements, Tricount et Réglages.
            ToolbarItemGroup(placement: .primaryAction) {
                ToolbarPaywallGate(feature: .budget) {
                    Button { vm.runAutoDetection() } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .localizedHelp("Détecter les récurrents")
                    Button { showCoach = true } label: {
                        Image(systemName: "lightbulb")
                    }
                    .localizedHelp("Coach dépenses")
                    Button { pushedSection = .envelopes } label: {
                        Image(systemName: "envelope.fill")
                    }
                    .localizedHelp("Enveloppes")
                    Button { pushedSection = .recurring } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .localizedHelp("Gérer les récurrents")
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                ToolbarPaywallGate(feature: .budget) {
                    Menu {
                        Button { vm.runAutoDetection() } label: {
                            Label("Détecter les récurrents", systemImage: "wand.and.stars")
                        }
                        Button { showCoach = true } label: {
                            Label("Coach dépenses", systemImage: "lightbulb")
                        }
                        Divider()
                        NavigationLink {
                            EnvelopeListView(vm: vm)
                        } label: {
                            Label("Enveloppes budgétaires", systemImage: "envelope.fill")
                        }
                        Divider()
                        NavigationLink {
                            RecurringManagementView(vm: vm)
                        } label: {
                            Label("Gérer les récurrents", systemImage: "arrow.clockwise.circle.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(AppTheme.Colors.accent)
                }
            }
            #endif
        }
    }

    // MARK: - Calendar Carousel

    /// Fenêtre de 3 mois [M-1, M, M+1] centrée sur `month`.
    private func neighborWindow(around month: Date) -> [Date] {
        let cal = Calendar.current
        let prev = cal.date(byAdding: .month, value: -1, to: month) ?? month
        let next = cal.date(byAdding: .month, value: 1, to: month) ?? month
        return [prev, month, next]
    }

    /// Recentre `pageMonths`/`pageIndex` sur `vm.displayedMonth`. `animated:
    /// false` (recentrage post-swipe/bouton, DOIT être invisible — sinon on
    /// verrait un second glissé se superposer à la transition native qui
    /// vient de jouer) vs `true` (saut direct — "aujourd'hui", sélecteur
    /// mois/année, scrubber — un fondu léger est approprié).
    private func syncPagerToDisplayedMonth(animated: Bool) {
        let wanted = neighborWindow(around: vm.displayedMonth)
        guard pageMonths != wanted || pageIndex != 1 else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                pageMonths = wanted
                pageIndex = 1
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                pageMonths = wanted
                pageIndex = 1
            }
        }
    }

    /// Mois précédent/suivant, PARTAGÉ par les flèches de `MonthNavigationView`
    /// ET le swipe trackpad macOS (`.trackpadMonthSwipe`) — même mécanisme
    /// (`pageIndex` change, `.onChange` fait le reste) pour ne pas dupliquer
    /// la logique de transition entre les deux déclencheurs.
    private func goToPreviousMonth() {
        withAnimation(.easeInOut(duration: 0.3)) { pageIndex = 0 }
    }

    private func goToNextMonth() {
        withAnimation(.easeInOut(duration: 0.3)) { pageIndex = 2 }
    }

    /// Saut direct (scrubber, sélecteur mois/année) — pas de notion de
    /// "précédent/suivant" ici, donc jamais via `pageIndex`.
    private func jumpToMonth(_ month: Date) {
        let cal = Calendar.current
        guard !cal.isDate(month, equalTo: vm.displayedMonth, toGranularity: .month) else { return }
        vm.setDisplayedMonth(month)
        HapticService.shared.selection()
    }

    /// `TabView(.page)` NATIF : le doigt suit du contenu déjà rendu des deux
    /// côtés (fenêtre pré-chargée par `loadData()`), sans geste maison — Apple
    /// gère le suivi 1:1 et le rejet en dessous du seuil pour nous.
    ///
    /// ⚠️ macOS : `PageTabViewStyle` n'est PAS un style pris en charge sur
    /// macOS (uniquement iOS/iPadOS/tvOS/watchOS d'après Apple) — appliqué
    /// quand même, il compile (le type existe côté framework) mais son rendu
    /// est dégradé : la grille restait quasi vide (en-tête des jours affiché,
    /// aucun chiffre) et le `TabView` se repliait sur une largeur intrinsèque
    /// minuscule au lieu de suivre celle proposée par le parent — d'où le
    /// calendrier collé au coin de la fenêtre (retour d'usage 2026-08-26,
    /// capture à l'appui). Un geste de swipe n'a de toute façon aucun sens au
    /// clavier/souris : macOS affiche directement le mois RÉGLÉ, sans
    /// carrousel — la navigation reste les flèches + le sélecteur mois/année.
    @ViewBuilder private var calendarCarousel: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            weekdayHeaderRow

            #if os(macOS)
            // Pas de `.frame(height:)` ici : contrairement à iOS (TabView(.page),
            // qui a besoin d'UNE hauteur partagée par les 3 pages voisines),
            // macOS n'affiche que le mois réglé — le VStack englobant peut
            // simplement suivre la hauteur réelle du contenu, panneau de
            // détail compris, quelle que soit sa taille (cf. le commentaire
            // de `calendarCarouselHeight` sur le bug d'origine).
            monthPage(vm.displayedMonth)
                .frame(maxWidth: .infinity)
                .id(monthKey(vm.displayedMonth))
                .transition(.opacity)
                .animation(AppTheme.Animations.easeOut, value: vm.displayedMonth)
            #else
            TabView(selection: $pageIndex) {
                ForEach(Array(pageMonths.enumerated()), id: \.offset) { i, month in
                    monthPage(month).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Le fond système d'un `.page` TabView est opaque sur iOS —
            // sans ça, une bande blanche/grise apparaît derrière le point
            // d'indicateur masqué.
            .background(AppTheme.Colors.background)
            .frame(height: calendarCarouselHeight)
            .animation(AppTheme.Animations.springSnappy, value: calendarCarouselHeight)
            #endif

            legendRow
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(DayDetailHeightPreferenceKey.self) { measuredDetailHeight = $0 }
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 1) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
    }

    private var legendRow: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            legendDot(color: AppTheme.Colors.warning, label: "Prévu")
            legendDot(color: AppTheme.Colors.danger, label: "Dépense")
            legendDot(color: AppTheme.Colors.success, label: "Revenu")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    /// Une page du carrousel = un mois. Lit `txCache`/`vm.cachedPrevisions`
    /// directement (déjà pré-chargés en fenêtre ±1 par `loadData()`) plutôt
    /// que de dépendre de `calendarDays`/`vm.displayedMonth`, qui ne
    /// décrivent QUE le mois RÉGLÉ — sinon les pages voisines montreraient
    /// soit rien, soit le mauvais mois pendant le glissé.
    @ViewBuilder
    private func monthPage(_ month: Date) -> some View {
        let key = monthKey(month)
        let isSettled = Calendar.current.isDate(month, equalTo: vm.displayedMonth, toGranularity: .month)
        if let txs = txCache[key] {
            let enrichedPrevisions = vm.enrichPrevisions(vm.cachedPrevisions(for: month) ?? [])
            let days = vm.calendarDays(for: month, transactions: txs, previsions: enrichedPrevisions)
            dayGrid(days: days, showsSelection: isSettled)
        } else {
            SkeletonCalendarGrid(showsHeader: false)
        }
    }

    /// Grille de semaines + détail du jour sélectionné inséré INLINE, juste
    /// sous SA semaine (retour d'usage : "un espace qui s'ouvre dans le
    /// calendrier, entre la ligne de la semaine et celle du dessous").
    /// `showsSelection` : seule la page RÉGLÉE affiche `selectedDay` — une
    /// page voisine encore visible pendant le glissé n'a pas à montrer le
    /// panneau d'un jour d'un AUTRE mois.
    @ViewBuilder
    private func dayGrid(days: [CalendarDay], showsSelection: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(weekRows(days).enumerated()), id: \.offset) { _, week in
                HStack(spacing: 1) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            Button {
                                HapticService.shared.selection()
                                withAnimation(AppTheme.Animations.springSnappy) {
                                    selectedDay = (selectedDay?.id == day.id) ? nil : day
                                }
                            } label: {
                                DayCell(
                                    day: day,
                                    isToday: Calendar.current.isDateInToday(day.date),
                                    isSelected: showsSelection && selectedDay?.id == day.id
                                )
                            }
                            .buttonStyle(DayCellButtonStyle())
                        } else {
                            // `.frame(maxWidth: .infinity)` explicite : un
                            // `HStack` ne donne aux enfants sans contenu
                            // propre AUCUNE largeur par défaut — sans lui,
                            // les cases vides de bord de mois s'écrasaient à
                            // zéro et décalaient tout le reste de la ligne.
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                    }
                }

                if showsSelection, let selectedDay,
                   let column = week.firstIndex(where: { $0?.id == selectedDay.id }) {
                    dayDetailCaret(column: column)
                    DayDetailPanel(day: selectedDay, vm: vm, allTiers: allTiers, allCategories: allCategories)
                        // Mesure la hauteur RÉELLE du panneau (nombre variable
                        // de prévisions/transactions) au lieu de l'estimer —
                        // cf. `calendarCarouselHeight`, consommateur unique.
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: DayDetailHeightPreferenceKey.self, value: geo.size.height)
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
    }

    /// Hauteur du carrousel — dérivée UNIQUEMENT de la page RÉGLÉE (nombre de
    /// semaines du mois affiché + le panneau de détail s'il est ouvert).
    /// Une page voisine plus courte/longue pendant un glissé transitoire
    /// peut donc être clippée/laisser un espace résiduel — compromis assumé
    /// (redimensionner en direct pendant le drag n'est pas vérifiable sans
    /// appareil sous la main).
    ///
    /// ⚠️ Utilise `measuredDetailHeight` (mesuré via
    /// `DayDetailHeightPreferenceKey`), PAS une constante : le panneau
    /// contient 0 à N prévisions + 0 à N transactions, une hauteur fixe (300
    /// à l'origine) débordait dès qu'un jour avait beaucoup de mouvements —
    /// le reste du calendrier/les cartes suivantes se retrouvaient
    /// chevauchés/coupés (retour d'usage 2026-08-27, capture iOS + macOS à
    /// l'appui). +11 = hauteur du petit triangle `dayDetailCaret` (7pt) +
    /// son espacement dans le `VStack(spacing: 4)` de `dayGrid`.
    private var calendarCarouselHeight: CGFloat {
        let rowH: CGFloat = 54
        let rowSpacing: CGFloat = 4
        let weeks = max(weekRows(calendarDays).count, 4)
        let gridH = CGFloat(weeks) * rowH + CGFloat(max(weeks - 1, 0)) * rowSpacing
        let detailH: CGFloat = selectedDay != nil ? measuredDetailHeight + 11 : 0
        return gridH + detailH
    }

    /// Découpe `days` (+ cases vides de bord de mois) en lignes de 7 —
    /// même construction que `leadingEmpty`/`trailingEmpty`, mais sous forme
    /// de grille explicite : la page a besoin de savoir sous QUELLE semaine
    /// ouvrir le détail, ce qu'un `LazyVGrid` à plat ne permet pas d'exprimer.
    private func weekRows(_ days: [CalendarDay]) -> [[CalendarDay?]] {
        var cells: [CalendarDay?] = Array(repeating: nil, count: leadingEmpty(days))
        cells.append(contentsOf: days.map { $0 as CalendarDay? })
        cells.append(contentsOf: Array(repeating: nil, count: trailingEmpty(days)))
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    /// Petit triangle qui pointe vers la colonne (0...6) du jour sélectionné,
    /// pour rattacher visuellement `DayDetailPanel` à sa case du calendrier
    /// plutôt qu'un panneau qui semble flotter sans lien avec le jour tapé.
    @ViewBuilder private func dayDetailCaret(column: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<7, id: \.self) { i in
                Group {
                    if i == column {
                        CalendarDetailCaret()
                            .fill(AppTheme.Colors.surface)
                            .frame(width: 14, height: 7)
                    } else {
                        Color.clear.frame(height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder private func legendDot(color: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Prevision Sections

    /// Une seule carte pour les deux horizons ("7 prochains jours" / "Ce
    /// mois"), chacun repliable indépendamment — remplace les 2 cartes
    /// empilées d'avant, qui pouvaient occuper tout l'écran sur un mois
    /// chargé en récurrents.
    @ViewBuilder private var recurringPrevisionsCard: some View {
        // ⚠️ `upcomingPrevisions` est lu UNE fois et converti en `Set` d'ids.
        // La version d'origine le relisait DANS le filtre — donc une fois par
        // prévision testée — et chaque lecture reconstruisait toute la liste
        // enrichie : coût quadratique à chaque rendu de la vue.
        let upcoming = vm.upcomingPrevisions
        let upcomingIds = Set(upcoming.map(\.id))
        let thisMonth = vm.pendingPrevisions.filter { !upcomingIds.contains($0.id) }
        if !upcoming.isEmpty || !thisMonth.isEmpty {
            AppCard {
                VStack(spacing: AppTheme.Spacing.md) {
                    if !upcoming.isEmpty {
                        recurringGroup(title: "Dans les 7 prochains jours", previsions: upcoming, isExpanded: $upcomingExpanded)
                    }
                    if !upcoming.isEmpty && !thisMonth.isEmpty {
                        Divider()
                    }
                    if !thisMonth.isEmpty {
                        recurringGroup(title: "Ce mois", previsions: thisMonth, isExpanded: $thisMonthExpanded)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private func recurringGroup(title: LocalizedStringKey, previsions: [EnrichedPrevision], isExpanded: Binding<Bool>) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Button {
                withAnimation(AppTheme.Animations.springSnappy) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(AppTheme.Typography.titleMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("\(previsions.count)")
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.surfaceSecondary, in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                ForEach(previsions) { ep in
                    PrevisionRow(enriched: ep, onSkip: { previsionPendingChoice = ep.prevision })
                        .contextMenu {
                            Button(role: .destructive) {
                                previsionPendingChoice = ep.prevision
                            } label: {
                                Label("Ignorer", systemImage: "xmark")
                            }
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Skeleton

    @ViewBuilder private var budgetSkeleton: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            SkeletonCalendarGrid()
                .padding(.horizontal, AppTheme.Spacing.md)

            // Bubble overlay placeholder (visuel uniquement, dans le flux ici)
            SkeletonBudgetBubble()

            // Carte "Dans les 7 prochains jours" skeleton
            AppCard {
                VStack(spacing: AppTheme.Spacing.sm) {
                    SkeletonLine(width: 200, height: 15)
                    SkeletonPrevisionRow()
                    SkeletonPrevisionRow()
                    SkeletonPrevisionRow()
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    // MARK: - Calendar Helpers

    private func leadingEmpty(_ days: [CalendarDay]) -> Int {
        guard let first = days.first else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: first.date)
        return (weekday + 5) % 7  // Monday = 0
    }

    private func trailingEmpty(_ days: [CalendarDay]) -> Int {
        let total = leadingEmpty(days) + days.count
        let remainder = total % 7
        return remainder == 0 ? 0 : 7 - remainder
    }

    private func loadData() async {
        let month = vm.displayedMonth
        let (start, end) = monthBounds(month)
        let txs = await Task.detached(priority: .userInitiated) {
            TransactionRepository().fetchAllAccountsTransactions(from: start, to: end)
        }.value
        calendarDays = vm.calendarDays(transactions: txs)
        txCache[monthKey(month)] = txs
        // Calculé en mémoire à partir de `txs` — évite le 2e fetch SQLite quasi
        // identique que `vm.monthlySummary()` faisait en interne pour le même mois.
        summary = vm.monthlySummary(transactions: txs)
        selectedDay = nil
        // Premier chargement terminé → on cache le skeleton.
        if isInitialLoading { isInitialLoading = false }

        // Pré-charger les mois adjacents en arrière-plan. Priorité `.utility` (pas
        // `.background`) : un swipe peu après l'ouverture de l'écran doit trouver le
        // cache déjà rempli, sinon la grille apparaît vide le temps du fetch — c'est
        // précisément la sensation de "chargement" au changement de mois à corriger.
        let cal = Calendar.current
        for delta in [-1, 1] {
            let adjMonth = cal.date(byAdding: .month, value: delta, to: month) ?? month
            let key = monthKey(adjMonth)
            guard txCache[key] == nil else { continue }
            let (s, e) = monthBounds(adjMonth)
            Task {
                let adjTxs = await Task.detached(priority: .utility) {
                    TransactionRepository().fetchAllAccountsTransactions(from: s, to: e)
                }.value
                txCache[key] = adjTxs
            }
        }
    }

    private func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    private func monthBounds(_ date: Date) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? date
        return (start, end)
    }
}
