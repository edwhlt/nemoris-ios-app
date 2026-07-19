import SwiftUI
import Charts
import TipKit

// MARK: - BudgetView (entry point)

struct BudgetView: View {
    @State private var vm = BudgetViewModel()
    @State private var calendarDays: [CalendarDay] = []
    @State private var selectedDay: CalendarDay?
    @State private var summary: MonthlyBudgetSummary?
    @State private var showEnvelopes = false
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
    private let weekdaySymbols = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        Group {
            if isEmbedded { navContent } else { NavigationStack { navContent } }
        }
        .onAppear {
            vm.onAppear()
            if allTiers.isEmpty { allTiers = referenceRepo.fetchTiers() }
            if allCategories.isEmpty { allCategories = referenceRepo.fetchCategories() }
        }
        .sheet(isPresented: $vm.showDetectionSheet) {
            DetectionResultsSheet(vm: vm)
        }
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
                                message: "Utilisez le menu ··· pour détecter vos dépenses récurrentes."
                            )
                            .padding(.horizontal, AppTheme.Spacing.md)
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.xxxl)
                }
            }
            .animation(AppTheme.Animations.springSnappy, value: selectedDay?.id)
            .task(id: vm.displayedMonth) { await loadData() }
            .onChange(of: vm.previsions) { _, _ in Task { summary = await vm.monthlySummary() } }
            .navigationDestination(isPresented: $showEnvelopes) {
                EnvelopeListView(vm: vm)
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

                            // Load new month data immediately from cache
                            if goingLeft { vm.nextMonth() } else { vm.previousMonth() }
                            calendarDays = txCache[targetKey].map { vm.calendarDays(transactions: $0) } ?? []
                            summary = nil
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
        .sheet(item: $apercuPresentation) { p in
            BudgetApercuSheet(summary: p.summary, days: p.days, month: p.month, categories: vm.categories, allTiers: allTiers, allCategories: allCategories)
        }
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

    // MARK: - Budget Overview Section

    @ViewBuilder private func budgetOverviewSection(_ s: MonthlyBudgetSummary) -> some View {
        AppCard {
            VStack(spacing: AppTheme.Spacing.sm) {
                SectionHeader(title: "Aperçu budgétaire")
                MonthOverviewCard(summary: s)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)

        if !s.envelopes.isEmpty {
            AppCard {
                VStack(spacing: AppTheme.Spacing.sm) {
                    SectionHeader(
                        title: "Enveloppes",
                        action: { showEnvelopes = true },
                        actionLabel: "Gérer"
                    )
                    ForEach(s.envelopes) { env in
                        EnvelopeProgressRow(progress: env)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
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
        let pending = vm.pendingPrevisions.filter { ep in
            !vm.upcomingPrevisions.contains { $0.id == ep.id }
        }
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
        async let txsFetch = Task.detached(priority: .userInitiated) {
            TransactionRepository().fetchAllAccountsTransactions(from: start, to: end)
        }.value
        async let summaryFetch = vm.monthlySummary()
        let (txs, sum) = await (txsFetch, summaryFetch)
        calendarDays = vm.calendarDays(transactions: txs)
        txCache[monthKey(month)] = txs
        summary = sum
        selectedDay = nil
        // Premier chargement terminé → on cache le skeleton.
        if isInitialLoading { isInitialLoading = false }

        // Pré-charger les mois adjacents en arrière-plan
        let cal = Calendar.current
        for delta in [-1, 1] {
            let adjMonth = cal.date(byAdding: .month, value: delta, to: month) ?? month
            let key = monthKey(adjMonth)
            guard txCache[key] == nil else { continue }
            let (s, e) = monthBounds(adjMonth)
            Task {
                let adjTxs = await Task.detached(priority: .background) {
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

// MARK: - Aperçu Presentation Model

private struct ApercuPresentation: Identifiable {
    let id = UUID()
    let summary: MonthlyBudgetSummary?
    let days: [CalendarDay]
    let month: Date
}

// MARK: - Budget Summary Bubble

private struct BudgetSummaryBubble: View {
    let summary: MonthlyBudgetSummary
    let month: Date
    let onTap: () -> Void

    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct: Double = 20

    private var fullRatio: Double {
        guard summary.forecastedExpenses > 0 else { return 0 }
        return summary.actualExpenses / summary.forecastedExpenses
    }

    private var ratio: Double { min(fullRatio, 1.0) }

    private var overColor: Color {
        guard summary.isOverBudget else { return AppTheme.Colors.accent }
        return fullRatio >= 1.0 + budgetRedOverPct / 100 ? AppTheme.Colors.danger : AppTheme.Colors.warning
    }

    private var overIcon: String {
        guard summary.isOverBudget else { return "chart.pie.fill" }
        return fullRatio >= 1.0 + budgetRedOverPct / 100 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: overIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(overColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(month, format: .dateTime.month(.wide).year())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                            Capsule()
                                .fill(overColor)
                                .frame(width: geo.size.width * ratio, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(width: 120)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.actualExpenses, format: .currency(code: "EUR").precision(.fractionLength(0)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(overColor)
                    Text("/ \(summary.forecastedExpenses.formatted(.currency(code: "EUR").precision(.fractionLength(0))))")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppTheme.Colors.accent.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Capsule())
            .modifier(GlassBubbleModifier())
        }
        .buttonStyle(BubblePressStyle())
    }
}

private struct BubblePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct GlassBubbleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
        }
    }
}

// MARK: - Budget Aperçu Sheet

private struct BudgetApercuSheet: View {
    let summary: MonthlyBudgetSummary?
    let days: [CalendarDay]
    let month: Date
    let categories: [Category]
    let allTiers: [Tiers]
    let allCategories: [Category]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategoryName: String? = nil
    @State private var showCategoryTxSheet: Bool = false
    private let envelopeTip = BudgetEnvelopeTip()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    if let s = summary {
                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Aperçu budgétaire")
                                apercuContent(s)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)

                        if !s.envelopes.isEmpty {
                            TipView(envelopeTip, arrowEdge: .none)
                                .padding(.horizontal, AppTheme.Spacing.md)
                            AppCard {
                                VStack(spacing: AppTheme.Spacing.sm) {
                                    SectionHeader(title: "Enveloppes")
                                    ForEach(s.envelopes) { env in
                                        Button {
                                            selectedCategoryName = env.categoryName
                                            showCategoryTxSheet = true
                                        } label: {
                                            HStack(spacing: AppTheme.Spacing.sm) {
                                                EnvelopeProgressRow(progress: env)
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                        }
                    }

                    if !days.isEmpty {
                        MonthProjectionCard(days: days)
                            .padding(.horizontal, AppTheme.Spacing.md)

                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Dépenses par catégorie")
                                CategoryExpensePieChart(days: days, selectedCategory: $selectedCategoryName)
                                if selectedCategoryName != nil {
                                    Button {
                                        showCategoryTxSheet = true
                                    } label: {
                                        Label("Voir les transactions", systemImage: "list.bullet")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)

                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Flux budgétaire")
                                Text("Revenus → Dépenses par catégorie")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                MoneyFlowSankeyView(days: days)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                    }

                    Spacer(minLength: AppTheme.Spacing.xl)
                }
                .padding(.top, AppTheme.Spacing.md)
            }
            .background(AppTheme.Colors.background)
            .navigationTitle(month.formatted(.dateTime.month(.wide).year()).capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showCategoryTxSheet) {
                NavigationStack {
                    List(filteredTransactionsForSelectedCategory()) { tx in
                        HStack(spacing: 10) {
                            MerchantLogo(transaction: tx, allTiers: allTiers, allCategories: allCategories, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                    .font(.subheadline)
                                if !tx.information.isEmpty && !tx.tiersName.isEmpty {
                                    Text(tx.information).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(tx.amount, format: .currency(code: "EUR"))
                                    .font(.subheadline).bold()
                                    .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                Text(tx.date, format: .dateTime.day().month(.abbreviated))
                                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                    .navigationTitle(selectedCategoryName ?? "Transactions")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { showCategoryTxSheet = false } } }
                }
            }
        }
    }

    @ViewBuilder
    private func apercuContent(_ s: MonthlyBudgetSummary) -> some View {
        HStack {
            statBox(title: "Prévu", value: s.forecastedExpenses, color: AppTheme.Colors.accent)
            Divider().frame(height: 40)
            statBox(title: "Réel", value: s.actualExpenses,
                    color: s.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.success)
            Divider().frame(height: 40)
            let v = s.variance
            statBox(title: v >= 0 ? "Écart" : "Économie", value: abs(v),
                    color: v > 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .frame(maxWidth: .infinity)

        let ratio = s.forecastedExpenses > 0
            ? min(s.actualExpenses / s.forecastedExpenses, 1.5) : 0
        BudgetRatioBar(ratio: ratio, forecastedExpenses: s.forecastedExpenses, actualExpenses: s.actualExpenses)

        HStack {
            Text("\(s.matchedCount) confirmés")
                .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text("\(s.pendingCount) en attente")
                .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
        }

        if s.fixedActual > 0 || s.totalIncome > 0 {
            Rectangle()
                .fill(AppTheme.Colors.surfaceSecondary)
                .frame(height: 1)
            SavingsBreakdownRow(summary: s)
        }
    }

    private func statBox(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall).foregroundStyle(color)
            Text(title)
                .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func filteredTransactionsForSelectedCategory() -> [FinanceTransaction] {
        guard let sel = selectedCategoryName else { return [] }
        let cal = Calendar.current
        let monthComponents = cal.dateComponents([.year, .month], from: month)

        // Build hierarchical set of category IDs (parent + children)
        let matchingIds: Set<Int>
        if let cat = categories.first(where: { $0.name == sel }) {
            let childIds = categories.filter { $0.parentId == cat.id }.map { $0.id }
            matchingIds = Set([cat.id] + childIds)
        } else {
            matchingIds = Set()
        }

        return days
            .flatMap { $0.transactions }
            .filter { tx in
                let comps = cal.dateComponents([.year, .month], from: tx.date)
                guard comps.year == monthComponents.year && comps.month == monthComponents.month else { return false }
                if !matchingIds.isEmpty, let catId = tx.categoryId {
                    return matchingIds.contains(catId)
                }
                // Fallback: name-based match (for "Autre" or unknown categories)
                let catName = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
                return catName == sel
            }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Recurring Management View

struct RecurringManagementView: View {
    @Bindable var vm: BudgetViewModel
    @State private var showAddSheet = false
    @State private var editingPattern: RecurringPattern?

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                let active   = vm.patterns.filter { $0.isActive }
                let inactive = vm.patterns.filter { !$0.isActive }

                if active.isEmpty && inactive.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "arrow.clockwise.circle",
                            title: "Aucun récurrent",
                            message: "Détectez vos dépenses récurrentes ou ajoutez-en manuellement."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    if !active.isEmpty {
                        Section("Actifs") {
                            ForEach(active) { p in
                                RecurringPatternRow(pattern: p, categories: vm.categories)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingPattern = p }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { vm.deletePattern(id: p.id) } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                        Button { vm.togglePattern(p) } label: {
                                            Label("Désactiver", systemImage: "pause.circle")
                                        }
                                        .tint(AppTheme.Colors.warning)
                                    }
                            }
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                    if !inactive.isEmpty {
                        Section("Inactifs") {
                            ForEach(inactive) { p in
                                RecurringPatternRow(pattern: p, categories: vm.categories)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingPattern = p }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { vm.deletePattern(id: p.id) } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                        Button { vm.togglePattern(p) } label: {
                                            Label("Réactiver", systemImage: "play.circle")
                                        }
                                        .tint(AppTheme.Colors.success)
                                    }
                            }
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Récurrents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .tint(AppTheme.Colors.accent)
            }
        }
        .sheet(isPresented: $showAddSheet) { PatternEditSheet(vm: vm, pattern: nil) }
        .sheet(item: $editingPattern) { p in PatternEditSheet(vm: vm, pattern: p) }
    }
}

// MARK: - Detection Results Sheet

private struct DetectionResultsSheet: View {
    @Bindable var vm: BudgetViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ces dépenses semblent récurrentes dans votre historique. Confirmez celles que vous souhaitez suivre.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)

                ForEach(vm.detectionResults, id: \.name) { candidate in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text(candidate.frequency.label)
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(abs(candidate.amountAvg), format: .currency(code: "EUR"))
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                Text("\(Int(candidate.confidence * 100))% confiance")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Text("\(candidate.occurrences.count) occurrences détectées")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            vm.acceptCandidate(candidate)
                            vm.detectionResults.removeAll { $0.name == candidate.name }
                            if vm.detectionResults.isEmpty { dismiss() }
                        } label: { Label("Confirmer", systemImage: "checkmark") }
                        .tint(AppTheme.Colors.success)
                    }
                    .listRowBackground(AppTheme.Colors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.background)
            .navigationTitle("Récurrents détectés")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Tout accepter") {
                        for c in vm.detectionResults { vm.acceptCandidate(c) }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct MonthNavigationView: View {
    @Bindable var vm: BudgetViewModel

    private var cal: Calendar { .current }
    private var prevMonth: Date { cal.date(byAdding: .month, value: -1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var nextMonth: Date { cal.date(byAdding: .month, value: 1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var isCurrentMonth: Bool { cal.isDate(vm.displayedMonth, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button { vm.previousMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.surface, in: Circle())
            }

            Button { vm.previousMonth() } label: {
                Text(prevMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Spacer()

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(vm.displayedMonth, format: .dateTime.month(.wide))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if !isCurrentMonth {
                        Image(systemName: "arrow.uturn.left.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.Colors.accent.opacity(0.75))
                    }
                }
                Text(vm.displayedMonth, format: .dateTime.year())
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isCurrentMonth { vm.goToCurrentMonth() } }

            Spacer()

            Button { vm.nextMonth() } label: {
                Text(nextMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Button { vm.nextMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.surface, in: Circle())
            }
        }
        .buttonStyle(.borderless)
        .animation(AppTheme.Animations.springSnappy, value: vm.displayedMonth)
    }
}

private struct MonthOverviewCard: View {
    let summary: MonthlyBudgetSummary

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                statBox(title: "Prévu",   value: summary.forecastedExpenses, color: AppTheme.Colors.accent)
                Divider().frame(height: 40)
                statBox(title: "Réel",    value: summary.actualExpenses,
                        color: summary.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Divider().frame(height: 40)
                let v = summary.variance
                statBox(title: v >= 0 ? "Écart" : "Économie",
                        value: abs(v),
                        color: v > 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
            }
            .frame(maxWidth: .infinity)

            let ratio = summary.forecastedExpenses > 0
                ? min(summary.actualExpenses / summary.forecastedExpenses, 1.5)
                : 0
            BudgetRatioBar(ratio: ratio, forecastedExpenses: summary.forecastedExpenses, actualExpenses: summary.actualExpenses)

            HStack {
                Text("\(summary.matchedCount) confirmés")
                    .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text("\(summary.pendingCount) en attente")
                    .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if summary.fixedActual > 0 || summary.totalIncome > 0 {
                Rectangle()
                    .fill(AppTheme.Colors.surfaceSecondary)
                    .frame(height: 1)
                SavingsBreakdownRow(summary: summary)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func statBox(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall).foregroundStyle(color)
            Text(title)
                .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Savings Breakdown Row

private struct SavingsBreakdownRow: View {
    let summary: MonthlyBudgetSummary

    var body: some View {
        HStack(spacing: 0) {
            miniStat(title: "Fixes",
                     value: summary.fixedActual,
                     color: AppTheme.Colors.textSecondary.opacity(0.7))
            miniStat(title: "Variables",
                     value: summary.variableActual,
                     color: AppTheme.Colors.warning)
            if summary.totalIncome > 0 {
                miniStat(title: "Revenus",
                         value: summary.totalIncome,
                         color: AppTheme.Colors.success)
                let net = summary.netSavings
                miniStat(title: net >= 0 ? "Économisé" : "Déficit",
                         value: abs(net),
                         color: net >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }
        }
    }

    private func miniStat(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value, format: .currency(code: "EUR").precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EnvelopeProgressRow: View {
    let progress: EnvelopeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill((progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: progress.categoryIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                }
                Text(progress.categoryName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                Text("\(progress.spent, format: .currency(code: "EUR")) / \(progress.allocated, format: .currency(code: "EUR"))")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
            }
            // Barre segmentée : gris = fixes confirmés, accent = variables, fantôme = prévu restant
            GeometryReader { geo in
                let totalW = geo.size.width
                let recurW = totalW * progress.recurringRatio
                let varW   = totalW * min(max(progress.ratio - progress.recurringRatio, 0),
                                          1.0 - progress.recurringRatio)
                let spentW = recurW + varW
                let forecastW = min(totalW * progress.forecastedRatio, totalW)
                let ghostW = max(forecastW - spentW, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.Colors.surfaceSecondary).frame(height: 8)
                    HStack(spacing: 0) {
                        if recurW > 0 {
                            Rectangle()
                                .fill(AppTheme.Colors.textSecondary.opacity(0.45))
                                .frame(width: recurW, height: 8)
                        }
                        if varW > 0 {
                            Rectangle()
                                .fill(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                                .frame(width: varW, height: 8)
                        }
                        if ghostW > 0 {
                            Rectangle()
                                .fill(AppTheme.Colors.accent.opacity(0.2))
                                .frame(width: ghostW, height: 8)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: totalW, height: 8)
                    .clipShape(Capsule())
                }
            }
            .frame(height: 8)
            HStack {
                if progress.isOverBudget {
                    Label("Dépassé de \(progress.spent - progress.allocated, format: .currency(code: "EUR"))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.danger)
                } else {
                    Text("Reste \(progress.remaining, format: .currency(code: "EUR"))")
                        .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                if progress.forecasted > 0 {
                    HStack(spacing: 3) {
                        if progress.forecastExceedsBudget {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.warning)
                        } else {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(AppTheme.Colors.accent.opacity(0.5))
                                .frame(width: 2, height: 9)
                        }
                        Text("\(progress.forecasted, format: .currency(code: "EUR").precision(.fractionLength(0))) prévus")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(progress.forecastExceedsBudget
                                ? AppTheme.Colors.warning
                                : AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                } else if progress.recurringSpent > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(AppTheme.Colors.textSecondary.opacity(0.45))
                            .frame(width: 5, height: 5)
                        Text("\(progress.recurringSpent, format: .currency(code: "EUR")) fixes")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                } else {
                    Text("\(Int((progress.ratio * 100).rounded())) %")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct PrevisionRow: View {
    let enriched: EnrichedPrevision
    /// Si fourni ET status == .pending, affiche un bouton inline "skip" trailing.
    /// (les rows sont dans VStack/AppCard, pas dans List → pas de .swipeActions natif)
    var onSkip: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(enriched.patternName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let cat = enriched.categoryName {
                    Text(cat)
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(enriched.displayAmount, format: .currency(code: "EUR"))
                    .font(AppTheme.Typography.moneySmall)
                    .foregroundStyle(enriched.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Text(enriched.expectedDate, format: .dateTime.day().month(.abbreviated))
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            // Bouton rapide skip : visible seulement sur les .pending
            if let onSkip, enriched.status == .pending {
                Button(action: onSkip) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ignorer cette échéance")
            }
        }
    }

    private var statusColor: Color {
        switch enriched.status {
        case .pending: return AppTheme.Colors.warning
        case .matched: return AppTheme.Colors.success
        case .skipped: return AppTheme.Colors.textSecondary
        }
    }
}

private struct RecurringPatternRow: View {
    let pattern: RecurringPattern
    let categories: [Category]

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: pattern.frequency.systemImage)
                .frame(width: 28)
                .foregroundStyle(pattern.isActive ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(pattern.isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                HStack(spacing: 4) {
                    Text(pattern.frequency.label)
                    if let catId = pattern.categoryId,
                       let cat = categories.first(where: { $0.id == catId }) {
                        Text("·")
                        Text(cat.name)
                    }
                }
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Text(pattern.displayAmount, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall)
                .foregroundStyle(pattern.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .opacity(pattern.isActive ? 1.0 : 0.5)
    }
}

// MARK: - Pattern Edit Sheet

private struct PatternEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let pattern: RecurringPattern?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amount = ""
    @State private var isExpense = true
    @State private var frequency = RecurrenceFrequency.monthly
    @State private var categoryId: Int? = nil
    @State private var payeeId: Int? = nil
    @State private var anchorDay: Int? = nil
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    // Tiers chargés à l'ouverture pour le picker (lecture seule, pas via VM)
    @State private var allTiers: [Tiers] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Informations") {
                    TextField("Nom (ex: Netflix, Loyer)", text: $name)
                    HStack {
                        TextField("Montant", text: $amount).keyboardType(.decimalPad)
                        Picker("", selection: $isExpense) {
                            Text("Dépense").tag(true)
                            Text("Revenu").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
                Section("Fréquence") {
                    Picker("Fréquence", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { f in Text(f.label).tag(f) }
                    }
                    if frequency == .monthly {
                        Stepper("Jour du mois : \(anchorDay ?? 1)",
                                value: Binding(get: { anchorDay ?? 1 }, set: { anchorDay = $0 }),
                                in: 1...31)
                    }
                }
                Section("Période") {
                    DatePicker("Début", selection: $startDate, displayedComponents: .date)
                    Toggle("Date de fin", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("Fin", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
                Section("Catégorie") {
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(nil as Int?)
                        ForEach(vm.categories.hierarchicallySorted, id: \.category.id) { entry in
                            Text(entry.indentedName).tag(entry.category.id as Int?)
                        }
                    }
                }
                // Le tier associé pré-remplit le picker quand la transaction matchée arrive,
                // et permet à l'auto-matching de cibler ce tier en priorité (TransactionMatcher).
                // Tri alpha + section "Aucun" pour éviter d'imposer un choix.
                Section {
                    Picker("Tier", selection: $payeeId) {
                        Text("Aucun").tag(nil as Int?)
                        ForEach(allTiers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { t in
                            Text(t.name).tag(t.id as Int?)
                        }
                    }
                } header: {
                    Text("Tier associé")
                } footer: {
                    Text("Optionnel — facilite l'auto-matching d'une transaction réelle à cette échéance et permet d'afficher le logo du marchand.")
                        .font(.caption)
                }
            }
            .navigationTitle(pattern == nil ? "Nouveau récurrent" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save(); dismiss() }
                        .disabled(name.isEmpty || amount.isEmpty)
                }
            }
        }
        .onAppear {
            populateFields()
            if allTiers.isEmpty {
                allTiers = TransactionRepository().fetchTiers()
            }
        }
    }

    private func populateFields() {
        guard let p = pattern else { return }
        name = p.name
        amount = String(format: "%.2f", p.displayAmount)
        isExpense = p.isExpense
        frequency = p.frequency
        categoryId = p.categoryId
        payeeId = p.payeeId
        anchorDay = p.anchorDay
        startDate = p.startDate
        hasEndDate = p.endDate != nil
        endDate = p.endDate ?? Date()
    }

    private func save() {
        let raw = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        let signed = isExpense ? -abs(raw) : abs(raw)
        let effectiveEndDate = hasEndDate ? endDate : nil
        if let existing = pattern {
            let updated = RecurringPattern(
                id: existing.id, name: name, amountAvg: signed, amountTolerance: existing.amountTolerance,
                categoryId: categoryId, payeeId: payeeId, frequency: frequency,
                anchorDay: anchorDay, isActive: existing.isActive, isManual: existing.isManual,
                createdAt: existing.createdAt, lastDetectedAt: existing.lastDetectedAt,
                startDate: startDate, endDate: effectiveEndDate
            )
            vm.updatePattern(updated)
        } else {
            let new = RecurringPattern(
                id: 0, name: name, amountAvg: signed, amountTolerance: 0.15,
                categoryId: categoryId, payeeId: payeeId, frequency: frequency,
                anchorDay: anchorDay, isActive: true, isManual: true,
                createdAt: Date(), lastDetectedAt: nil,
                startDate: startDate, endDate: effectiveEndDate
            )
            vm.addManualPattern(new)
        }
    }
}

// MARK: - Envelope List View

struct EnvelopeListView: View {
    @Bindable var vm: BudgetViewModel
    @State private var showAdd = false
    @State private var showSuggestions = false
    @State private var editingEnvelope: BudgetEnvelope?

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                let active = vm.envelopes.filter { $0.isActive }
                if active.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "envelope",
                            title: "Aucune enveloppe",
                            message: "Définissez un budget par catégorie."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(active) { env in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(env.name)
                                    .font(AppTheme.Typography.bodyMedium)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text(env.period.label)
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            Text(env.amount, format: .currency(code: "EUR"))
                                .font(AppTheme.Typography.moneySmall)
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingEnvelope = env }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { vm.deleteEnvelope(id: env.id) } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Enveloppes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Créer une enveloppe", systemImage: "plus")
                    }
                    Button {
                        showSuggestions = true
                    } label: {
                        Label("Suggérer (90 j)", systemImage: "wand.and.stars")
                    }
                } label: {
                    Image(systemName: "plus")
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        .sheet(isPresented: $showAdd) { EnvelopeEditSheet(vm: vm, envelope: nil) }
        .sheet(item: $editingEnvelope) { env in EnvelopeEditSheet(vm: vm, envelope: env) }
        .sheet(isPresented: $showSuggestions) {
            EnvelopeSuggestionSheet(
                viewModel: vm,
                existingEnvelopes: vm.envelopes,
                allCategories: vm.categories
            )
        }
    }
}

private struct EnvelopeEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let envelope: BudgetEnvelope?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amount = ""
    @State private var period = BudgetPeriod.monthly
    @State private var categoryId: Int? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom (ex: Alimentation)", text: $name)
                    HStack {
                        TextField("Montant", text: $amount).keyboardType(.decimalPad)
                        Picker("", selection: $period) {
                            ForEach(BudgetPeriod.allCases, id: \.self) { p in Text(p.label).tag(p) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Catégorie") {
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(nil as Int?)
                        ForEach(vm.categories.hierarchicallySorted, id: \.category.id) { entry in
                            Text(entry.indentedName).tag(entry.category.id as Int?)
                        }
                    }
                }
            }
            .navigationTitle(envelope == nil ? "Nouvelle enveloppe" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save(); dismiss() }
                        .disabled(name.isEmpty || amount.isEmpty)
                }
            }
        }
        .onAppear {
            if let e = envelope {
                name = e.name
                amount = String(format: "%.2f", e.amount)
                period = e.period
                categoryId = e.categoryId
            }
        }
    }

    private func save() {
        let raw = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        if let existing = envelope {
            let updated = BudgetEnvelope(id: existing.id, name: name, categoryId: categoryId,
                                         amount: raw, period: period,
                                         startDate: existing.startDate, isActive: existing.isActive)
            vm.updateEnvelope(updated)
        } else {
            let new = BudgetEnvelope(id: 0, name: name, categoryId: categoryId,
                                      amount: raw, period: period, startDate: Date(), isActive: true)
            vm.addEnvelope(new)
        }
    }
}

// MARK: - Category Expense Pie Chart

private struct CategoryExpensePieChart: View {
    let days: [CalendarDay]
    @Binding var selectedCategory: String?

    private struct Slice: Identifiable {
        let id: String
        let amount: Double
        var label: String { id }
    }

    private var slices: [Slice] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount < 0 {
            let cat = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
            dict[cat, default: 0] += abs(tx.amount)
        }
        let sorted = dict.map { Slice(id: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
        guard sorted.count > 6 else { return sorted }
        let other = sorted.dropFirst(5).reduce(0) { $0 + $1.amount }
        return Array(sorted.prefix(5)) + [Slice(id: "Autre", amount: other)]
    }

    var body: some View {
        if slices.isEmpty {
            Text("Aucune dépense ce mois")
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            VStack(spacing: 8) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Montant", slice.amount),
                        innerRadius: .ratio(0.52),
                        angularInset: 2.5
                    )
                    .cornerRadius(5)
                    .foregroundStyle(by: .value("Catégorie", slice.id))
                    .opacity(selectedCategory == nil || selectedCategory == slice.id ? 1.0 : 0.35)
                    .annotation(position: .overlay, alignment: .center) {
                        if selectedCategory == slice.id {
                            Text(slice.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .shadow(radius: 1)
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .center, spacing: 6)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame else { return }
                                let frame = geo[plot]
                                let center = CGPoint(x: frame.midX, y: frame.midY)
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let radius = sqrt(dx*dx + dy*dy)
                                let outerR = min(frame.width, frame.height) * 0.5
                                let innerR = outerR * 0.52
                                guard radius >= innerR * 0.85 && radius <= outerR * 1.05 else { return }
                                var angle = atan2(dx, -dy)
                                if angle < 0 { angle += 2 * .pi }
                                let total = slices.reduce(0) { $0 + $1.amount }
                                guard total > 0 else { return }
                                var start: Double = 0
                                var found: String? = nil
                                for s in slices {
                                    let frac = s.amount / total
                                    let end = start + frac * 2 * .pi
                                    if angle >= start && angle < end { found = s.id; break }
                                    start = end
                                }
                                if let cat = found {
                                    withAnimation(AppTheme.Animations.easeInOut) {
                                        selectedCategory = (selectedCategory == cat) ? nil : cat
                                    }
                                }
                            }
                    }
                }
                .frame(height: 220)

                if let sel = selectedCategory, let slice = slices.first(where: { $0.id == sel }) {
                    HStack(spacing: 6) {
                        Text(slice.label)
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("·").foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(slice.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                            .font(AppTheme.Typography.labelMedium)
                            .fontWeight(.semibold)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(AppTheme.Animations.easeInOut, value: selectedCategory)
                }
            }
        }
    }
}

// MARK: - Sankey Flow View (Income → Expenses)

private struct MoneyFlowSankeyView: View {
    let days: [CalendarDay]

    private struct SankeyNode: Identifiable {
        let id = UUID()
        let label: String
        let amount: Double
        let color: Color
    }

    private struct NodeLayout: Identifiable {
        let node: SankeyNode
        let y: CGFloat
        let height: CGFloat
        var id: UUID { node.id }
        var color: Color { node.color }
    }

    private static let incomeColors: [Color] = [
        Color(hex: "34D399"), Color(hex: "10B981"), Color(hex: "6EE7B7"),
        Color(hex: "059669"), Color(hex: "A7F3D0")
    ]
    private static let expenseColors: [Color] = [
        Color(hex: "5EA1FF"), Color(hex: "FBBF24"), Color(hex: "F87171"),
        Color(hex: "7B61FF"), Color(hex: "FB923C"), Color(hex: "E879F9")
    ]

    private var incomeNodes: [SankeyNode] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount > 0 {
            let cat = tx.categoryName.isEmpty ? "Revenu" : tx.categoryName
            dict[cat, default: 0] += tx.amount
        }
        return dict.sorted { $0.value > $1.value }.prefix(4).enumerated()
            .map { idx, pair in SankeyNode(label: pair.key, amount: pair.value, color: Self.incomeColors[idx]) }
    }

    private var expenseNodes: [SankeyNode] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount < 0 {
            let cat = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
            dict[cat, default: 0] += abs(tx.amount)
        }
        let sorted = dict.sorted { $0.value > $1.value }
        var nodes = sorted.prefix(4).enumerated()
            .map { idx, pair in SankeyNode(label: pair.key, amount: pair.value, color: Self.expenseColors[idx]) }
        if sorted.count > 4 {
            let other = sorted.dropFirst(4).reduce(0) { $0 + $1.value }
            nodes.append(SankeyNode(label: "Autre", amount: other, color: Color(.systemGray)))
        }
        return nodes
    }

    private var totalIncome: Double { incomeNodes.reduce(0) { $0 + $1.amount } }
    private var totalExpenses: Double { expenseNodes.reduce(0) { $0 + $1.amount } }

    private func makeLayout(nodes: [SankeyNode], scale: Double, height: CGFloat, gap: CGFloat) -> [NodeLayout] {
        guard scale > 0, !nodes.isEmpty else { return [] }
        let totalGap = gap * CGFloat(max(nodes.count - 1, 0))
        let usable = height - totalGap
        var y: CGFloat = 0
        return nodes.map { node in
            let h = max((node.amount / scale) * usable, 4)
            let ln = NodeLayout(node: node, y: y, height: h)
            y += h + gap
            return ln
        }
    }

    var body: some View {
        if incomeNodes.isEmpty && expenseNodes.isEmpty {
            Text("Aucune donnée ce mois")
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            let extraRow = totalIncome > totalExpenses ? 1 : 0
            let chartH = CGFloat(max(incomeNodes.count, expenseNodes.count + extraRow)) * 54 + 20
            GeometryReader { geo in
                let nodeW: CGFloat = 10
                let labelW: CGFloat = 90
                let gap: CGFloat = 5
                let leftX: CGFloat = labelW + 4
                let rightX: CGFloat = geo.size.width - labelW - 4
                let midX: CGFloat = (leftX + rightX) * 0.5
                let h = geo.size.height
                let maxT = max(totalIncome, totalExpenses, 1)
                let leftLayout  = makeLayout(nodes: incomeNodes,  scale: maxT, height: h, gap: gap)
                let rightLayout = makeLayout(nodes: expenseNodes, scale: maxT, height: h, gap: gap)
                let savingsAmount = totalIncome - totalExpenses
                let savingsH: CGFloat = savingsAmount > 0
                    ? max((savingsAmount / maxT) * h, 4) : 0
                let savingsY: CGFloat = rightLayout.last.map { $0.y + $0.height + gap } ?? 0

                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        // Flow ribbons from left income total → each right expense node
                        var srcY: CGFloat = 0
                        for rn in rightLayout {
                            var p = Path()
                            p.move(to:    CGPoint(x: leftX + nodeW, y: srcY))
                            p.addCurve(to: CGPoint(x: rightX - nodeW, y: rn.y),
                                       control1: CGPoint(x: midX, y: srcY),
                                       control2: CGPoint(x: midX, y: rn.y))
                            p.addLine(to:  CGPoint(x: rightX - nodeW, y: rn.y + rn.height))
                            p.addCurve(to: CGPoint(x: leftX + nodeW, y: srcY + rn.height),
                                       control1: CGPoint(x: midX, y: rn.y + rn.height),
                                       control2: CGPoint(x: midX, y: srcY + rn.height))
                            p.closeSubpath()
                            ctx.fill(p, with: .color(rn.color.opacity(0.15)))
                            srcY += rn.height + gap
                        }
                        // Savings flow ribbon
                        if savingsH > 0 {
                            var p = Path()
                            p.move(to:    CGPoint(x: leftX + nodeW, y: srcY))
                            p.addCurve(to: CGPoint(x: rightX - nodeW, y: savingsY),
                                       control1: CGPoint(x: midX, y: srcY),
                                       control2: CGPoint(x: midX, y: savingsY))
                            p.addLine(to:  CGPoint(x: rightX - nodeW, y: savingsY + savingsH))
                            p.addCurve(to: CGPoint(x: leftX + nodeW, y: srcY + savingsH),
                                       control1: CGPoint(x: midX, y: savingsY + savingsH),
                                       control2: CGPoint(x: midX, y: srcY + savingsH))
                            p.closeSubpath()
                            ctx.fill(p, with: .color(Color(hex: "34D399").opacity(0.12)))
                        }
                        // Left income bars
                        for ln in leftLayout {
                            ctx.fill(Path(CGRect(x: leftX, y: ln.y, width: nodeW, height: ln.height)),
                                     with: .color(ln.color))
                        }
                        // Right expense bars
                        for rn in rightLayout {
                            ctx.fill(Path(CGRect(x: rightX - nodeW, y: rn.y, width: nodeW, height: rn.height)),
                                     with: .color(rn.color))
                        }
                        // Savings bar
                        if savingsH > 0 {
                            ctx.fill(Path(CGRect(x: rightX - nodeW, y: savingsY, width: nodeW, height: savingsH)),
                                     with: .color(Color(hex: "34D399").opacity(0.55)))
                        }
                    }

                    // Left labels (income) — right-aligned before bar
                    ForEach(leftLayout) { ln in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ln.node.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(ln.color)
                                .lineLimit(1)
                            Text(ln.node.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .frame(width: labelW, height: max(ln.height, 22), alignment: .trailing)
                        .offset(x: 0, y: ln.y)
                    }

                    // Right labels (expenses) — left-aligned after bar
                    ForEach(rightLayout) { rn in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rn.node.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(rn.color)
                                .lineLimit(1)
                            Text(rn.node.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .frame(width: labelW, height: max(rn.height, 22), alignment: .leading)
                        .offset(x: rightX + 4, y: rn.y)
                    }

                    // Savings label
                    if savingsH > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Épargne")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(hex: "34D399"))
                                .lineLimit(1)
                            Text(savingsAmount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .frame(width: labelW, height: max(savingsH, 22), alignment: .leading)
                        .offset(x: rightX + 4, y: savingsY)
                    }
                }
            }
            .frame(height: chartH)
        }
    }
}

// MARK: - Budget Ratio Progress Bar

struct BudgetRatioBar: View {
    let ratio: Double
    let forecastedExpenses: Double
    let actualExpenses: Double

    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct: Double = 20

    private var pct: Int { Int((min(ratio, 1.5) * 100).rounded()) }
    private var isOver: Bool { ratio > 1 }

    private var barColor: LinearGradient {
        let redRatio = 1.0 + budgetRedOverPct / 100
        if ratio <= 1.0 {
            return LinearGradient(colors: [AppTheme.Colors.success, AppTheme.Colors.success.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
        } else if ratio < redRatio {
            return LinearGradient(colors: [AppTheme.Colors.warning, AppTheme.Colors.warning.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [AppTheme.Colors.danger, AppTheme.Colors.danger], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(height: 10)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * min(ratio, 1.0), height: 10)
                }
            }
            .frame(height: 10)
            HStack {
                if isOver {
                    Label("Dépassement de \((actualExpenses - forecastedExpenses).formatted(.currency(code: "EUR").precision(.fractionLength(0))))", systemImage: ratio >= 1.0 + budgetRedOverPct / 100 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.danger)
                } else {
                    Text("Reste \((forecastedExpenses - actualExpenses).formatted(.currency(code: "EUR").precision(.fractionLength(0))))")
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                Text("\(pct) %")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOver ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
            }
        }
    }
}
