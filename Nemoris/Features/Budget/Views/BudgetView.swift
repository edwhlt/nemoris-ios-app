import SwiftUI
import Charts
import TipKit

/// Actual height of the day-detail pane opened in the calendar
/// (`DayDetailPanel`) — measured rather than estimated, since its content
/// (0 to N previsions + 0 to N transactions) has no fixed size. Sole
/// consumer: `BudgetView.calendarCarouselHeight`.
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
    // Month carousel — replaces the old custom swipe gesture (a sliding
    // snapshot, the target month loaded AFTER release, hence the feeling
    // of "it's reloading"). `pageMonths` is a 3-month window [M-1, M, M+1]
    // rendered by a NATIVE `TabView(.page)`: the finger follows REAL, already
    // pre-rendered content on both sides (the same prefetch as the old system,
    // see `loadData()`), with no custom gesture to reinvent. `pageIndex` only
    // moves via native pagination (a swipe or an animated programmatic change);
    // as soon as it drifts from 1, `.onChange` translates that into a real
    // month change on the ViewModel side, then
    // `.onChange(of: vm.displayedMonth)` recenters the window WITH NO animation
    // (`Transaction.disablesAnimations`) so that recentering stays invisible.
    @State private var pageMonths: [Date] = []
    @State private var pageIndex: Int = 1
    @State private var previsionPendingChoice: BudgetPrevision?
    @State private var showMonthYearPicker = false
    /// Spending coach — moved here from Transactions (2026-08-29), which stays
    /// a pure transaction explorer. Budget analysis belongs here.
    @State private var showCoach = false
    // Collapsible groups on the "Recurring" card — state per group, not a
    // single bool: collapsing "Next 7 days" must not affect "This month".
    // "This month" collapsed by default (usually the longer of the two
    // lists); "Next 7 days" stays open, it's the more actionable horizon.
    @State private var upcomingExpanded = true
    @State private var thisMonthExpanded = false

    /// Skeleton only on the 1st open (or on an uncached month change).
    /// See `loadData()`, which sets it to `true` when the target month is missing from the cache.
    @State private var isInitialLoading = true

    /// The ACTUAL height of `DayDetailPanel` as reported by
    /// `DayDetailHeightPreferenceKey` — never a constant, see
    /// `calendarCarouselHeight`.
    @State private var measuredDetailHeight: CGFloat = 0

    var isEmbedded: Bool = false

    #if os(macOS)
    /// The module's sub-screen, opened via STATE-DRIVEN navigation (never a push).
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
    /// To close the pane by returning to the calendar.
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?

    /// A full-page sub-screen + a way back to the calendar.
    @ViewBuilder
    private func budgetSectionPage(_ section: BudgetSection) -> some View {
        Group {
            switch section {
            case .envelopes: EnvelopeListView(vm: vm)
            case .recurring: RecurringManagementView(vm: vm)
            }
        }
        // ⚠️ Explicit resolution, never a bare literal/`LocalizedStringKey`:
        // `.navigationTitle` bridges to native chrome (the macOS title bar),
        // which doesn't reliably respect the app-forced `\.locale`. See CLAUDE.md §5.
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

    /// Day symbols for the calendar grid header — a single
    /// character, week starting on Monday (`leadingEmpty` fixes this order
    /// independently of `Calendar.current.firstWeekday`). Derived from
    /// `appState.locale` (not `Locale.current`) to follow the app's
    /// language setting rather than the device's, which may differ.
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
            // A sub-screen is open → it REPLACES the module's content (state-driven
            // navigation, with its own back button). See the toolbar comment.
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
        // `.task`, NOT `.onAppear`: in the detail column of a macOS
        // `NavigationSplitView`, `.onAppear` isn't reliable — it wasn't firing
        // here, so the module showed empty ("No recurring items", budget at €0)
        // even though the database held the data. The calendar, on the other
        // hand, loaded fine: it goes through a `.task(id:)`.
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
                // Explicit `.frame(maxWidth: .infinity)`: a `ScrollView`
                // offers its available width to its content, but a `VStack`
                // with no direct child forcing `.infinity` stays collapsed
                // to its intrinsic width — on macOS (a wide detail
                // column), that showed up as a calendar stuck in the
                // top-left corner with the rest of the window empty.
                VStack(spacing: AppTheme.Spacing.md) {

                    // Month navigation — the arrows play the SAME native page
                    // transition as the swipe (`pageIndex` changes,
                    // `.onChange` does the rest); the month/year label is
                    // now a button that opens the quick picker.
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

                        // Upcoming recurring items: 1 card, 2 collapsible groups
                        // (instead of 2 stacked cards) — decluttering the view.
                        recurringPrevisionsCard

                        // Empty state when no patterns
                        if vm.patterns.isEmpty {
                            // macOS: the "⋯" menu was flattened into toolbar
                            // buttons — the message must follow suit, otherwise it
                            // points to a menu that no longer exists.
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
                // The carousel finished a transition (a user swipe OR a
                // programmatic arrow, see `MonthNavigationView`) — `1`
                // stays the center, only a drift from it is the signal.
                guard new != 1 else { return }
                if new == 2 { vm.nextMonth() } else { vm.previousMonth() }
                selectedDay = nil
                HapticService.shared.selection()
            }
            .onChange(of: vm.displayedMonth) { _, _ in
                // `pageIndex == 1` ⇒ the change did NOT come from a
                // carousel page-turn (so "today", the month/year picker,
                // or the scrubber) → a fade is appropriate. Otherwise
                // (0 or 2) it's a post-swipe recentering: it MUST stay
                // invisible, or it would slide back over the
                // native transition that just played.
                syncPagerToDisplayedMonth(animated: pageIndex == 1)
            }
            .onChange(of: vm.previsions) { _, _ in
                // The month's transactions are already cached in the vast majority of
                // cases (set by `loadData()`) → a synchronous recompute, no SQL
                // round trip for a plain skip/match/edit of a recurring item.
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
        // A two-finger trackpad swipe = a month change (a no-op on
        // iOS, which already has `TabView(.page)`'s native swipe). Shares the
        // same triggers as `MonthNavigationView`'s arrows.
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
            // macOS: icon-button actions (no "⋯" menu), and above all
            // NO `NavigationLink` — a push from a module desynchronizes the
            // sidebar and, in a toolbar, used to trigger a crash. Both
            // destinations go through state (see `pushedSection`), as in
            // Investments, Tricount and Settings.
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

    /// A 3-month window [M-1, M, M+1] centered on `month`.
    private func neighborWindow(around month: Date) -> [Date] {
        let cal = Calendar.current
        let prev = cal.date(byAdding: .month, value: -1, to: month) ?? month
        let next = cal.date(byAdding: .month, value: 1, to: month) ?? month
        return [prev, month, next]
    }

    /// Recenters `pageMonths`/`pageIndex` on `vm.displayedMonth`. `animated:
    /// false` (a post-swipe/button recentering, MUST be invisible — otherwise
    /// a second slide would be seen layering over the native transition that
    /// just played) vs `true` (a direct jump — "today", the month/year
    /// picker, the scrubber — a light fade is appropriate).
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

    /// Previous/next month, SHARED by `MonthNavigationView`'s arrows
    /// AND the macOS trackpad swipe (`.trackpadMonthSwipe`) — the same
    /// mechanism (`pageIndex` changes, `.onChange` does the rest) so as not to
    /// duplicate the transition logic between the two triggers.
    private func goToPreviousMonth() {
        withAnimation(.easeInOut(duration: 0.3)) { pageIndex = 0 }
    }

    private func goToNextMonth() {
        withAnimation(.easeInOut(duration: 0.3)) { pageIndex = 2 }
    }

    /// A direct jump (the scrubber, the month/year picker) — there's no
    /// notion of "previous/next" here, so never via `pageIndex`.
    private func jumpToMonth(_ month: Date) {
        let cal = Calendar.current
        guard !cal.isDate(month, equalTo: vm.displayedMonth, toGranularity: .month) else { return }
        vm.setDisplayedMonth(month)
        HapticService.shared.selection()
    }

    /// NATIVE `TabView(.page)`: the finger follows content already rendered on
    /// both sides (a window preloaded by `loadData()`), with no custom gesture — Apple
    /// handles 1:1 tracking and the below-threshold rejection for us.
    ///
    /// ⚠️ macOS: `PageTabViewStyle` is NOT a supported style on
    /// macOS (only iOS/iPadOS/tvOS/watchOS per Apple) — applied
    /// anyway, it compiles (the type exists on the framework side) but its
    /// rendering is degraded: the grid stayed nearly empty (the day header
    /// shown, no numbers at all) and the `TabView` collapsed to a tiny
    /// intrinsic width instead of following the one offered by the parent —
    /// hence the calendar stuck in the corner of the window. A swipe gesture makes
    /// no sense with keyboard/mouse anyway: macOS shows the SET month
    /// directly, with no carousel — navigation stays the arrows + the
    /// month/year picker.
    @ViewBuilder private var calendarCarousel: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            weekdayHeaderRow

            #if os(macOS)
            // No `.frame(height:)` here: unlike iOS (TabView(.page),
            // which needs ONE height shared by the 3 neighboring pages),
            // macOS only shows the set month — the enclosing VStack can
            // simply follow the content's actual height, detail
            // pane included, whatever its size (see the comment
            // on `calendarCarouselHeight` about the original bug).
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
            // The system background of a `.page` TabView is opaque on iOS —
            // without it, a white/gray band shows up behind the hidden
            // page-indicator dots.
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

    /// One carousel page = one month. Reads `txCache`/`vm.cachedPrevisions`
    /// directly (already preloaded in a ±1 window by `loadData()`) rather
    /// than depending on `calendarDays`/`vm.displayedMonth`, which describe
    /// ONLY the SET month — otherwise the neighboring pages would show
    /// either nothing or the wrong month during the slide.
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

    /// A grid of weeks + the selected day's detail inserted INLINE, right
    /// under ITS week. `showsSelection`: only the SET page shows
    /// `selectedDay` — a neighboring page still visible during the slide
    /// shouldn't show the panel for a day in ANOTHER month.
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
                            // Explicit `.frame(maxWidth: .infinity)`: an
                            // `HStack` gives children with no content of their
                            // own NO default width — without it,
                            // the empty cells at the edges of the month collapsed to
                            // zero width and threw off the rest of the row.
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
                        // Measures the panel's ACTUAL height (a variable count
                        // of previsions/transactions) instead of estimating it —
                        // see `calendarCarouselHeight`, the sole consumer.
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

    /// Carousel height — derived ONLY from the SET page (the number of
    /// weeks in the displayed month + the detail pane if it's open).
    /// A shorter/longer neighboring page during a transient slide can
    /// therefore be clipped/leave a residual gap — an accepted tradeoff
    /// (resizing live during the drag isn't verifiable without a
    /// device on hand).
    ///
    /// ⚠️ Uses `measuredDetailHeight` (measured via
    /// `DayDetailHeightPreferenceKey`), NOT a constant: the panel
    /// holds 0 to N previsions + 0 to N transactions, a fixed height (300
    /// originally) overflowed as soon as a day had many movements —
    /// the rest of the calendar/the following cards ended up
    /// overlapped/clipped. +11 = the height of the small `dayDetailCaret`
    /// triangle (7pt) + its spacing in `dayGrid`'s `VStack(spacing: 4)`.
    private var calendarCarouselHeight: CGFloat {
        let rowH: CGFloat = 54
        let rowSpacing: CGFloat = 4
        let weeks = max(weekRows(calendarDays).count, 4)
        let gridH = CGFloat(weeks) * rowH + CGFloat(max(weeks - 1, 0)) * rowSpacing
        let detailH: CGFloat = selectedDay != nil ? measuredDetailHeight + 11 : 0
        return gridH + detailH
    }

    /// Splits `days` (+ the empty edge-of-month cells) into rows of 7 —
    /// the same construction as `leadingEmpty`/`trailingEmpty`, but as an
    /// explicit grid: the page needs to know UNDER WHICH week to
    /// open the detail, which a flat `LazyVGrid` can't express.
    private func weekRows(_ days: [CalendarDay]) -> [[CalendarDay?]] {
        var cells: [CalendarDay?] = Array(repeating: nil, count: leadingEmpty(days))
        cells.append(contentsOf: days.map { $0 as CalendarDay? })
        cells.append(contentsOf: Array(repeating: nil, count: trailingEmpty(days)))
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    /// A small triangle pointing to the selected day's column (0...6),
    /// to visually anchor `DayDetailPanel` to its calendar cell
    /// rather than a panel that seems to float with no link to the tapped day.
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

    /// A single card for both horizons ("Next 7 days" / "This
    /// month"), each independently collapsible — replaces the 2 stacked
    /// cards from before, which could take up the whole screen on a month
    /// loaded with recurring items.
    @ViewBuilder private var recurringPrevisionsCard: some View {
        // ⚠️ `upcomingPrevisions` is read ONCE and converted to a `Set` of ids.
        // The original version re-read it INSIDE the filter — so once per
        // prevision tested — and every read rebuilt the whole enriched
        // list: quadratic cost on every render of the view.
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

            // Bubble overlay placeholder (visual only, in the flow here)
            SkeletonBudgetBubble()

            // "Next 7 days" card skeleton
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
        // Computed in memory from `txs` — avoids the near-identical 2nd SQLite
        // fetch `vm.monthlySummary()` used to do internally for the same month.
        summary = vm.monthlySummary(transactions: txs)
        selectedDay = nil
        // The first load is done → hide the skeleton.
        if isInitialLoading { isInitialLoading = false }

        // Preload the adjacent months in the background. `.utility` priority (not
        // `.background`): a swipe soon after opening the screen must find the
        // cache already filled, otherwise the grid appears empty while fetching —
        // that's precisely the "loading" feeling this is meant to fix on a month change.
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
