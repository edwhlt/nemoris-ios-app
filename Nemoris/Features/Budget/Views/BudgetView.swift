import SwiftUI
import Charts
import TipKit

// MARK: - BudgetView (entry point)
struct BudgetView: View {
    @State private var vm = BudgetViewModel()
    @State private var calendarDays: [CalendarDay] = []
    @State private var selectedDay: CalendarDay?
    @State private var summary: MonthlyBudgetSummary?
    @State private var apercuPresentation: ApercuPresentation? = nil
    @State private var txCache: [String: [FinanceTransaction]] = [:]
    @State private var allTiers: [Tiers] = []
    @State private var allCategories: [Category] = []
    private let referenceRepo = TransactionRepository()
    @State private var dragOffset: CGFloat = 0
    @State private var exitingDays: [CalendarDay] = []
    @State private var showExiting = false
    @State private var exitingSlideOffset: CGFloat = 0

    /// Skeleton uniquement sur la 1ère ouverture (ou sur un changement de mois non-caché).
    /// Voir `loadData()` qui met à `true` quand le mois cible est absent du cache.
    @State private var isInitialLoading = true

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
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    paneCenter?.dismissCurrent()
                    pushedSection = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Budget")
                .accessibilityLabel("Budget")
            }
        }
    }
    #endif

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
    private let weekdaySymbols = ["L", "M", "M", "J", "V", "S", "D"]

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
    }

    // MARK: - Main Content

    @ViewBuilder private var navContent: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {

                    // Month navigation
                    MonthNavigationView(vm: vm)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)

                    if isInitialLoading {
                        budgetSkeleton
                    } else {
                        // Calendar grid (with slide transition ZStack)
                        calendarGridSection
                            .background(AppTheme.Colors.background)

                        // Day detail (inline, animated)
                        if let day = selectedDay {
                            DayDetailPanel(day: day, vm: vm, allTiers: allTiers, allCategories: allCategories)
                                .padding(.horizontal, AppTheme.Spacing.md)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Upcoming previsions (7 days)
                        upcomingSection

                        // This month previsions
                        thisMonthSection

                        // Empty state when no patterns
                        if vm.patterns.isEmpty {
                            EmptyStateView(
                                icon: "arrow.clockwise.circle",
                                title: "Aucun récurrent",
                                // macOS : le menu "⋯" a été aplati en boutons dans la
                                // barre d'outils — le message doit suivre, sinon il
                                // renvoie vers un menu qui n'existe plus.
                                message: {
                                    #if os(macOS)
                                    "Utilisez la baguette magique dans la barre d'outils pour détecter vos dépenses récurrentes."
                                    #else
                                    "Utilisez le menu ··· pour détecter vos dépenses récurrentes."
                                    #endif
                                }()
                            )
                            .padding(.horizontal, AppTheme.Spacing.md)
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.xxxl)
                }
            }
            .animation(AppTheme.Animations.springSnappy, value: selectedDay?.id)
            .task(id: vm.displayedMonth) { await loadData() }
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // N'activer le déplacement que si clairement horizontal
                        guard abs(dx) > abs(dy) * 1.8 else { return }
                        dragOffset = dx
                    }
                    .onEnded { val in
                        let dx = val.translation.width
                        let dy = val.translation.height
                        if abs(dx) > abs(dy) * 1.2 && abs(dx) > 60 {
                            #if os(macOS)
                            // Pas d'UIScreen sur Mac — largeur de fenêtre typique
                            // suffisante pour l'animation de sortie du swipe.
                            let screenWidth: CGFloat = 900
                            #else
                            let screenWidth = UIScreen.main.bounds.width
                            #endif
                            let goingLeft = dx < 0
                            let exitTarget: CGFloat = goingLeft ? -screenWidth : screenWidth
                            let targetMonth = Calendar.current.date(
                                byAdding: .month, value: goingLeft ? 1 : -1, to: vm.displayedMonth
                            ) ?? vm.displayedMonth
                            let targetKey = monthKey(targetMonth)

                            // Snapshot current calendar as the exiting layer
                            exitingDays = calendarDays
                            exitingSlideOffset = dragOffset
                            showExiting = true

                            // `vm.nextMonth()`/`previousMonth()` basculent `vm.previsions`
                            // de façon SYNCHRONE quand le mois cible est déjà en cache
                            // (cf. BudgetViewModel.applyCachedOrReloadPrevisions) — donc
                            // `vm.calendarDays`/`vm.monthlySummary` ci-dessous lisent déjà
                            // les prévisions du mois cible, jamais celles de l'ancien mois.
                            if goingLeft { vm.nextMonth() } else { vm.previousMonth() }
                            if let cachedTxs = txCache[targetKey] {
                                calendarDays = vm.calendarDays(transactions: cachedTxs)
                                summary = vm.monthlySummary(transactions: cachedTxs)
                            } else {
                                // Mois pas encore pré-chargé (ex: plusieurs swipes très
                                // rapprochés) — `.task(id:)` prend le relais sous peu.
                                calendarDays = []
                                summary = nil
                            }
                            selectedDay = nil

                            // Position entering content off the opposite edge (no animation)
                            dragOffset = -exitTarget

                            // Animate both layers simultaneously — no black gap
                            withAnimation(.easeInOut(duration: 0.28)) {
                                exitingSlideOffset = exitTarget
                                dragOffset = 0
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                showExiting = false
                                exitingDays = []
                            }
                        } else {
                            withAnimation(AppTheme.Animations.springSnappy) { dragOffset = 0 }
                        }
                    }
            )

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
        .adaptivePane(item: $apercuPresentation) { p in
            BudgetApercuSheet(summary: p.summary, days: p.days, month: p.month, categories: vm.categories, allTiers: allTiers, allCategories: allCategories)
        }
        .navigationTitle("Budget")
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
                    .help("Détecter les récurrents")
                    Button { pushedSection = .envelopes } label: {
                        Image(systemName: "envelope.fill")
                    }
                    .help("Enveloppes")
                    Button { pushedSection = .recurring } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .help("Gérer les récurrents")
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                ToolbarPaywallGate(feature: .budget) {
                    Menu {
                        Button { vm.runAutoDetection() } label: {
                            Label("Détecter les récurrents", systemImage: "wand.and.stars")
                        }
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

    // MARK: - Calendar Grid Section

    /// ZStack showing both exiting (snapshot) and entering calendar grids during month transitions.
    @ViewBuilder private var calendarGridSection: some View {
        ZStack(alignment: .top) {
            if showExiting {
                calendarGridContent(days: exitingDays)
                    .offset(x: exitingSlideOffset)
                    .allowsHitTesting(false)
            }
            calendarGridContent(days: calendarDays)
                .offset(x: dragOffset)
        }
        .clipped()
    }

    @ViewBuilder private func calendarGridContent(days: [CalendarDay]) -> some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 1) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<leadingEmpty(days), id: \.self) { _ in
                    Color.clear.frame(height: 54)
                }
                ForEach(days) { day in
                    DayCell(
                        day: day,
                        isToday: Calendar.current.isDateInToday(day.date),
                        isSelected: selectedDay?.id == day.id
                    )
                    .onTapGesture {
                        withAnimation(AppTheme.Animations.springSnappy) {
                            selectedDay = (selectedDay?.id == day.id) ? nil : day
                        }
                    }
                }
                ForEach(0..<trailingEmpty(days), id: \.self) { _ in
                    Color.clear.frame(height: 54)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)

            HStack(spacing: AppTheme.Spacing.lg) {
                legendDot(color: AppTheme.Colors.warning, label: "Prévu")
                legendDot(color: AppTheme.Colors.danger, label: "Dépense")
                legendDot(color: AppTheme.Colors.success, label: "Revenu")
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
        }
    }

    @ViewBuilder private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Prevision Sections

    @ViewBuilder private var upcomingSection: some View {
        if !vm.upcomingPrevisions.isEmpty {
            AppCard {
                VStack(spacing: AppTheme.Spacing.sm) {
                    SectionHeader(title: "Dans les 7 prochains jours")
                    ForEach(vm.upcomingPrevisions) { ep in
                        PrevisionRow(enriched: ep, onSkip: { vm.skipPrevision(ep.prevision) })
                            .contextMenu {
                                Button(role: .destructive) {
                                    vm.skipPrevision(ep.prevision)
                                } label: {
                                    Label("Ignorer", systemImage: "xmark")
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    @ViewBuilder private var thisMonthSection: some View {
        // ⚠️ `upcomingPrevisions` est lu UNE fois et converti en `Set` d'ids.
        // La version d'origine le relisait DANS le filtre — donc une fois par
        // prévision testée — et chaque lecture reconstruisait toute la liste
        // enrichie : coût quadratique à chaque rendu de la vue.
        let upcomingIds = Set(vm.upcomingPrevisions.map(\.id))
        let pending = vm.pendingPrevisions.filter { !upcomingIds.contains($0.id) }
        if !pending.isEmpty {
            AppCard {
                VStack(spacing: AppTheme.Spacing.sm) {
                    SectionHeader(title: "Ce mois")
                    ForEach(pending) { ep in
                        PrevisionRow(enriched: ep, onSkip: { vm.skipPrevision(ep.prevision) })
                            .contextMenu {
                                Button(role: .destructive) {
                                    vm.skipPrevision(ep.prevision)
                                } label: {
                                    Label("Ignorer", systemImage: "xmark")
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
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
