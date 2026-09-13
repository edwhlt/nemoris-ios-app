import SwiftUI
import Charts
import TipKit

// MARK: - DashboardView (Annual)

/// Dashboard as an **editorial page**.
///
/// Before: a stack of uniform cards that ranked everything at the same
/// visual level → an "admin dashboard" look. The `AppChartCard` and
/// `PremiumDashboardSummaryCard` components are therefore no longer used here — the
/// impact comes from typography, the gradient and spacing, not a white/boxed background.
///
/// Restructuring:
///   • data comes from `DashboardSnapshotStore` (computed off the main thread,
///     cached per aggregate) — this view no longer runs any query at all;
///   • the hero has **two levels**: the dominant month + a discreet yearly total;
///   • the three Investments / Patrimoine / Budget banners, which were three
///     near-identical copies stacked over ~3 screens of scroll, merged into
///     `DashboardOverviewBanner`.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    /// Injected once in `NemorisApp` — this view is instantiated twice
    /// (the iOS TabView + the macOS sidebar's detail pane) and two `@State`s would
    /// mean two caches, so everything computed twice.
    @Environment(DashboardSnapshotStore.self) private var store
    /// The Pro entitlement — so the availability of cards (banner + grid +
    /// customization screen) reflects the actual subscription, not just the
    /// persisted module flag (see `AppState.isDashboardCardAvailable`).
    @Environment(PurchaseManager.self) private var purchaseManager
    /// The user's selection (fiscal year + month filter). The only remaining local
    /// state: the data itself lives in the store.
    @State private var period = DashboardPeriod(
        year: Calendar.current.component(.year, from: Date()),
        month: nil
    )
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showCustomize = false
    @State private var showApplePayPending = false
    #if os(macOS)
    /// macOS: to close the pane at the moment "Customize" replaces
    /// the dashboard (see `body`) — otherwise an already-open Import/Search pane
    /// would stay shown, orphaned, on top of the customization screen.
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif

    private let availableYears: [Int] = {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current).reversed()
    }()

    var isEmbedded: Bool = false

    // MARK: - Reading the snapshot's data
    //
    // `nil` in the snapshot = not computed yet. It falls back to the empty
    // value, which reproduces exactly the previous rendering (sections hide
    // themselves when their collection is empty).

    private var monthlyData: [MonthlyTotals]      { store.snapshot.monthlySeries ?? [] }
    private var stats: DashboardStats             { store.snapshot.stats ?? .empty }
    private var previousYearStats: DashboardStats { store.snapshot.previousYearStats ?? .empty }
    private var alerts: [Alert]                   { store.snapshot.alerts ?? [] }
    private var investmentsRecap: InvestmentsRecap    { store.snapshot.investments ?? .empty }
    private var patrimoineSnapshot: PatrimoineSnapshot { store.snapshot.patrimoine ?? .empty }
    private var budgetRecap: BudgetRecap          { store.snapshot.budget ?? .empty }

    // MARK: - "Overview" banner columns
    //
    // A column only appears if the module is enabled AND there's data to
    // show. Gating on the module being enabled is new: before, a banner could
    // lead to a tab the user had disabled in Settings.

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

    /// Aggregates to compute: those of the fixed elements + those of the cards
    /// actually shown. **A hidden card therefore costs no query at all** — that's
    /// the whole point of declaring dependencies in the registry.
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

    /// Identity of the `.task`: the cache key **and** the requested
    /// aggregates. Without the units, showing a hidden card again wouldn't trigger
    /// any computation and the card would stay on its skeleton.
    private struct LoadIdentity: Hashable {
        let key: DashboardCacheKey
        let units: Set<DashboardAggregate>
    }

    private var loadIdentity: LoadIdentity {
        LoadIdentity(key: cacheKey, units: requiredUnits)
    }

    /// The "import a CSV" welcome card only applies to a user with no
    /// data. It's restricted to the current fiscal year: on a past, empty
    /// fiscal year, that's a normal result, not an onboarding state.
    private var showsOnboardingCard: Bool {
        // `nil` = not computed yet: without this guard, the welcome
        // screen would flicker during the first pass.
        guard let series = store.snapshot.monthlySeries else { return false }
        return series.isEmpty && period.year == Calendar.current.component(.year, from: Date())
    }

    private func selectYear(_ year: Int) {
        period = DashboardPeriod(year: year, month: nil)
    }

    var body: some View {
        #if os(macOS)
        // macOS: customization via STATE-DRIVEN navigation, not a push. The
        // dashboard stays accessible (its own toolbar) while an
        // Import/Search pane is open (a non-modal side pane) — a push here used to
        // mask that pane behind the customization screen until returning to
        // the root (an AppKit/NavigationStack issue: "macOS
        // pane masked by pushed content"). The same fix as Settings/
        // Investments/Tricount.
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
        // A GeometryReader **at the root, outside the ScrollView**: it's what gives
        // the grid's column count. Inside the ScrollView it would receive
        // a degenerate proposed height. `onGeometryChange` would be cleaner but
        // needs macOS 15+, while the project targets macOS 14.
        GeometryReader { geometry in
            scrollBody(availableWidth: geometry.size.width)
        }
    }

    @ViewBuilder private func scrollBody(availableWidth: CGFloat) -> some View {
        ZStack(alignment: .top) {
            AppTheme.Colors.background.ignoresSafeArea()
            // The editorial gradient at the top: accent → background. Only 360pt
            // tall so as not to bathe the whole scroll view in the green tint.
            heroBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    yearPicker
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)

                    // PROGRESSIVE loading: each block decides for itself whether it has
                    // something to show. No more single global skeleton that would mask
                    // the whole screen while waiting for the slowest aggregate.

                    // Alerts — only visible if the engine surfaced something
                    // actionable. At the top to maximize visibility.
                    if !alerts.isEmpty {
                        AlertsBanner(alerts: alerts)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.md)
                    }

                    // Shown apart from the totals — never in the hero/the
                    // envelopes as long as these expenses haven't been resolved.
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
                        // Like Investments: it's the ROOT navigation that
                        // decides where to show the import tool (a full
                        // destination on desktop, a pane on iPhone) — not a
                        // pane stuck onto the Dashboard.
                        OnboardingImportCard { appState.openImportTool(destination: .transactions) }
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.xxxl)
                    } else {
                        // Overview: a single band for the 3 modules, instead
                        // of 3 stacked full-width banners. Hides itself
                        // as long as no column has data.
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
                // Global cross-module search (cmd-K style).
                // ⚠️ iOS ONLY: on macOS, the magnifying glass now
                // lives next to the sidebar toggle (`MainTabView`,
                // always visible whatever module is shown) — keeping
                // it HERE TOO made TWO magnifying glasses show up in
                // the same window as soon as Dashboard was the current module.
                // On iOS, Dashboard stays the only entry point (no
                // sidebar), so unchanged.
                #if !os(macOS)
                PaneToggleButton(label: "Rechercher", systemImage: "magnifyingglass", isOn: $showSearch)
                #endif
                // A quick masking toggle — discreet but always accessible
                // from the app's main hub. A snappy animation to visually confirm
                // the toggle was registered.
                Button {
                    HapticService.shared.toggle()
                    withAnimation(AppTheme.Animations.springSnappy) {
                        appState.amountsHidden.toggle()
                    }
                } label: {
                    Image(systemName: appState.amountsHidden ? "eye.slash.fill" : "eye")
                        .foregroundStyle(appState.amountsHidden ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                }
                // A Menu rather than a 4th button: three icons already barely
                // fit in the bar on iPhone.
                Menu {
                    Button {
                        showCustomize = true
                    } label: {
                        Label("Personnaliser le tableau de bord", systemImage: "square.grid.2x2")
                    }
                    Button {
                        #if os(macOS)
                        // macOS: Settings already exists as a sidebar destination.
                        // Presenting it as a sheet made it unbounded (bigger
                        // than the window) and unclosable (no swipe-down). It's
                        // routed to the detail pane instead.
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
            // See CLAUDE.md §5: re-injecting \.locale is required for any
            // level-2+ `.sheet()` reachable on macOS.
            SettingsView().environment(appState)
                .environment(\.locale, AppLocalization.locale)
        }
        // macOS: handled by `body` (state-driven navigation — see the comment above).
        // iOS: a classic sheet, `DashboardCustomizeView` stays natively
        // pushable/dismissable via its own `dismiss()`.
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
        // A single key for the 3 dimensions (mutated data, fiscal year, month filter)
        // rather than three stacked `.task(id:)`s. The store only recomputes
        // aggregates whose restricted key actually changed.
        //
        // ⚠️ This load must NEVER bump `appState.dataRefreshToken`: that
        // would be an infinite loop (a documented precedent in `InvestmentsView`).
        .task(id: loadIdentity) {
            // A 1-frame guard: lets the skeleton paint at least once before
            // the first snapshot replaces it, otherwise on an already-warm database
            // there'd be a flash of the empty layout.
            await Task.yield()
            await store.load(units: requiredUnits, key: cacheKey)
        }
    }

    // MARK: - Grille de cartes

    /// The cards the user chose, arranged into rows by
    /// `DashboardGridPlanner`: a wide card takes its own row, compact ones
    /// group together up to the number of columns the width allows.
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

    // MARK: - Hero backdrop (a subtle gradient at the top)

    /// An accent → background gradient over 360pt at the top of the screen. Gives
    /// the impression the hero "emerges" from the app's chrome, without introducing a
    /// harsh colored band. Opacity 0.18 in dark, 0.12 in light to stay understated.
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

    /// A skeleton for the **hero alone**. The rest of the screen no longer needs one: the
    /// "Overview" banner hides itself as long as it has nothing to show, and each grid
    /// tile carries its own skeleton. That's what an optionally-fielded snapshot
    /// enables — before, a single skeleton masked the whole screen until
    /// the last aggregate (the coach, which scans 180 days) arrived.
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

    /// The screen's dominant block, on **two reading levels**:
    ///   1. the big number = the finest selected period — the current month
    ///      by default, the filtered month if the user chose one;
    ///   2. a discreet secondary line = the fiscal year's total + the N-1 variation.
    ///
    /// Why: an **annual** total as the dominant figure doesn't say what to do
    /// today. In July, "−€5,144 for 2026" is an observation; "−€412 this
    /// month" is actionable. The annual total stays a glance below.
    ///
    /// **No card**, no background — the backdrop's gradient does the work.
    @ViewBuilder private var editorialHero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            heroEyebrow
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // The big number — via MoneyText to respect global masking.
            MoneyText(
                amount: heroNet,
                font: .system(size: 44, weight: .bold, design: .default),
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            heroSecondaryLine

            // Footer: Income · Expenses for the SAME period as the big number, otherwise
            // the hero's three figures wouldn't be talking about the same thing.
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

    /// The second level: the fiscal year's total when the big number is monthly, then the
    /// N-1 variation when it makes sense. Deliberately 13pt: it's a
    /// reference point, not information competing with the big number.
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

    // MARK: - The hero's dominant period

    /// The month highlighted: the one filtered by the user, otherwise the current
    /// month when looking at the current fiscal year. `nil` on a past
    /// fiscal year — "this month" would then make no sense, falling back to
    /// the annual total.
    private var heroMonthKey: String? {
        if let month = period.month { return month }
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.year, from: now) == period.year else { return nil }
        return String(format: "%04d-%02d", period.year, calendar.component(.month, from: now))
    }

    private var isMonthDominant: Bool { heroMonthKey != nil }

    /// Totals for the dominant month. A month with no transaction isn't a lack of
    /// data: it's a €0 month, and showing it is more accurate than silently
    /// falling back to the year.
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

    /// A small stat "pill" used in the hero's footer. Left-aligned,
    /// no background so as not to compete with the big number. Just a colored icon +
    /// an amount in `moneySmall` + a tiny label.
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
