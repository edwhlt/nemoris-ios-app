import Foundation
import Observation

@Observable
@MainActor
final class BudgetViewModel {

    // MARK: - State

    // `didSet`: all three sources of `enrichedPrevisions` rebuild it
    // whenever they change — so the cache can never go stale, whatever
    // mutation path is taken (loading, refresh, skip, match…).
    var patterns: [RecurringPattern] = [] { didSet { rebuildEnrichedPrevisions() } }
    var envelopes: [BudgetEnvelope] = []
    var previsions: [BudgetPrevision] = [] { didSet { rebuildEnrichedPrevisions() } }
    var categories: [Category] = [] { didSet { rebuildEnrichedPrevisions() } }
    var isLoading = false
    var detectionResults: [DetectionCandidate] = []
    var showDetectionSheet = false

    /// Month shown in the calendar and the comparison (e.g. "2025-01")
    var displayedMonth: Date = {
        let cal = Calendar.current
        let now = Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
    }()

    // MARK: - Private

    private let repo: BudgetRepository
    private let txRepo: TransactionRepository

    /// The default value targets the app's database: no call site
    /// needs to change. Tests inject a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        repo = BudgetRepository(store: store)
        txRepo = TransactionRepository(store: store)
    }

    /// Cache of previsions per month (key "yyyy-MM"). Lets `navigateMonth(by:)`
    /// switch `previsions` SYNCHRONOUSLY when the target month is already
    /// preloaded — a mirror of the `txCache` `BudgetView` keeps for transactions.
    /// Without this cache, every swipe waited on an SQL round trip before the
    /// calendar's "Planned" dots and the summary bubble showed the right values.
    private var previsionsCache: [String: [BudgetPrevision]] = [:]

    // MARK: - Lifecycle

    func onAppear() {
        Task { await loadAll() }
    }

    func refresh() {
        Task { await loadAll() }
    }

    // MARK: - Loading

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        let patternsResult = await Task.detached(priority: .userInitiated) {
            self.repo.fetchPatterns()
        }.value
        let envelopesResult = await Task.detached(priority: .userInitiated) {
            self.repo.fetchEnvelopes()
        }.value
        let (start, end) = monthRange(displayedMonth)
        let prevResult = await Task.detached(priority: .userInitiated) {
            self.repo.fetchPrevisions(from: start, to: end)
        }.value
        let catResult = await Task.detached(priority: .userInitiated) {
            self.txRepo.fetchCategories()
        }.value

        self.patterns = patternsResult
        self.envelopes = envelopesResult
        self.previsions = prevResult
        self.categories = catResult
        previsionsCache[monthKey(displayedMonth)] = prevResult

        await prefetchAdjacentPrevisions()
    }

    // MARK: - Month Navigation

    func previousMonth() {
        navigateMonth(by: -1)
    }

    func nextMonth() {
        navigateMonth(by: 1)
    }

    func goToCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        applyCachedOrReloadPrevisions()
    }

    /// A direct jump to an arbitrary month (not necessarily ±1) — the
    /// month/year picker, the scrubber. `month` can be any day OF the
    /// target month, normalized to the 1st.
    func setDisplayedMonth(_ month: Date) {
        let cal = Calendar.current
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        applyCachedOrReloadPrevisions()
    }

    /// Changes the displayed month by `delta` months. If the target month's previsions
    /// are already cached (preloaded while looking at the previous month),
    /// `previsions` is reassigned SYNCHRONOUSLY — no SQL round trip between
    /// the swipe and the "Planned" dots/summary bubble showing up.
    private func navigateMonth(by delta: Int) {
        displayedMonth = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
        applyCachedOrReloadPrevisions()
    }

    private func applyCachedOrReloadPrevisions() {
        let key = monthKey(displayedMonth)
        if let cached = previsionsCache[key] {
            previsions = cached
        } else {
            // A month never visited or preloaded (e.g. fast consecutive swipes) —
            // falls back to the old behavior (an async fetch).
            Task { await reloadPrevisions() }
        }
        Task { await prefetchAdjacentPrevisions() }
    }

    private func reloadPrevisions() async {
        let (start, end) = monthRange(displayedMonth)
        let result = await Task.detached(priority: .userInitiated) {
            self.repo.fetchPrevisions(from: start, to: end)
        }.value
        previsionsCache[monthKey(displayedMonth)] = result
        self.previsions = result
    }

    /// Preloads M-1/M+1's previsions while the user is looking at the
    /// displayed month, so the NEXT swipe (either direction) already finds
    /// everything cached. `.utility` priority (not `.background`): a quick
    /// swipe must have good odds of finding the fetch already resolved.
    private func prefetchAdjacentPrevisions() async {
        let cal = Calendar.current
        for delta in [-1, 1] {
            let adjMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
            let key = monthKey(adjMonth)
            guard previsionsCache[key] == nil else { continue }
            let (s, e) = monthRange(adjMonth)
            let result = await Task.detached(priority: .utility) {
                self.repo.fetchPrevisions(from: s, to: e)
            }.value
            previsionsCache[key] = result
        }
    }

    // MARK: - Auto-Detection

    /// Analyzes the user's history and suggests recurring patterns to confirm.
    /// Analyzes ALL accounts so no subscription is missed.
    func runAutoDetection() {
        isLoading = true
        Task {
            defer { isLoading = false }
            // Load 24 months of transactions across all accounts
            let end = Date()
            let start = Calendar.current.date(byAdding: .month, value: -24, to: end) ?? end
            let txs = await Task.detached(priority: .userInitiated) {
                self.txRepo.fetchAllAccountsTransactions(from: start, to: end)
            }.value

            let candidates = RecurringDetector.detect(from: txs)
            // We keep EVERY candidate, including those that match an
            // already-existing pattern (active or not): excluding them
            // silently made them disappear with no explanation — a real-world
            // report read that as "detection doesn't work". The panel
            // shows them grayed out instead, with a link to the
            // existing pattern, rather than hiding them. Stable sort: new
            // ones first (in RecurringDetector's confidence order),
            // already-tracked ones after.
            self.detectionResults = candidates.sorted { a, b in
                let aKnown = a.existingMatch(in: patterns) != nil
                let bKnown = b.existingMatch(in: patterns) != nil
                return (aKnown ? 1 : 0) < (bKnown ? 1 : 0)
            }
            // Always open the panel, even with no result: otherwise clicking
            // "Detect recurring items" and finding nothing does NOTHING
            // visible, which reads as "the button is broken" rather
            // than "no recurring item meets the 4 criteria". The panel
            // then shows an explicit empty state (DetectionResultsSheet).
            self.showDetectionSheet = true
        }
    }

    /// Confirms and saves a detected candidate as a recurring pattern.
    func acceptCandidate(_ candidate: DetectionCandidate) {
        let firstOccurrence = candidate.occurrences.first ?? Date()
        let pattern = RecurringPattern(
            id: 0,
            name: candidate.name,
            amountAvg: candidate.amountAvg,
            amountTolerance: 0.15,
            categoryId: candidate.categoryId,
            payeeId: candidate.payeeId,
            frequency: candidate.frequency,
            anchorDay: candidate.anchorDay,
            isActive: true,
            isManual: false,
            createdAt: Date(),
            lastDetectedAt: candidate.occurrences.last,
            startDate: firstOccurrence,
            endDate: nil
        )
        if let newId = self.repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: true, isManual: false, createdAt: pattern.createdAt,
                lastDetectedAt: pattern.lastDetectedAt,
                startDate: pattern.startDate, endDate: nil
            )
            self.repo.regeneratePrevisions(for: withId)
        }
        refresh()
    }

    // MARK: - Pattern CRUD

    func addManualPattern(_ pattern: RecurringPattern) {
        if let newId = self.repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: pattern.isActive, isManual: true, createdAt: pattern.createdAt,
                lastDetectedAt: nil, startDate: pattern.startDate, endDate: pattern.endDate
            )
            self.repo.regeneratePrevisions(for: withId)
            scheduleNotificationsForPattern(withId)
        }
        refresh()
    }

    func updatePattern(_ pattern: RecurringPattern) {
        self.repo.updatePattern(pattern)
        self.repo.regeneratePrevisions(for: pattern)
        scheduleNotificationsForPattern(pattern)
        refresh()
    }

    func deletePattern(id: Int) {
        // Cancel the notifications before deleting (the previsions will cascade-delete)
        let toCancel = self.repo.fetchPrevisions(forPatternId: id)
        BudgetNotificationService.cancelAll(forPatternId: id, previsions: toCancel)
        self.repo.deletePattern(id: id)
        refresh()
    }

    func togglePattern(_ pattern: RecurringPattern) {
        let updated = RecurringPattern(
            id: pattern.id, name: pattern.name, amountAvg: pattern.amountAvg,
            amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
            payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
            isActive: !pattern.isActive, isManual: pattern.isManual,
            createdAt: pattern.createdAt, lastDetectedAt: pattern.lastDetectedAt,
            startDate: pattern.startDate, endDate: pattern.endDate
        )
        self.repo.updatePattern(updated)
        if updated.isActive {
            self.repo.regeneratePrevisions(for: updated)
            scheduleNotificationsForPattern(updated)
        } else {
            // Pattern disabled → cancel all its notifications
            let toCancel = self.repo.fetchPrevisions(forPatternId: updated.id)
            BudgetNotificationService.cancelAll(forPatternId: updated.id, previsions: toCancel)
        }
        refresh()
    }

    /// Helper: reschedules the j-3 notifications for every PENDING prevision of a pattern.
    /// Called after regeneratePrevisions to refresh the notifications without duplicating them.
    private func scheduleNotificationsForPattern(_ pattern: RecurringPattern) {
        guard pattern.isActive else { return }
        let previsions = self.repo.fetchPrevisions(forPatternId: pattern.id)
        Task {
            await BudgetNotificationService.rescheduleForPattern(
                patternId: pattern.id,
                patternName: pattern.name,
                previsions: previsions
            )
        }
    }

    // MARK: - Envelope CRUD

    func addEnvelope(_ envelope: BudgetEnvelope) {
        self.repo.insertEnvelope(envelope)
        refresh()
    }

    func updateEnvelope(_ envelope: BudgetEnvelope) {
        self.repo.updateEnvelope(envelope)
        refresh()
    }

    func deleteEnvelope(id: Int) {
        self.repo.deleteEnvelope(id: id)
        refresh()
    }

    // MARK: - Prevision Actions

    func skipPrevision(_ prevision: BudgetPrevision) {
        self.repo.updatePrevisionStatus(id: prevision.id, status: .skipped, transactionId: nil)
        // Skip → cancel the j-3 notification (otherwise it reminds about a due date the user already dismissed)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    /// Stops a recurring item from this due date onward: sets `endDate` to the
    /// day before the expected date, regenerates the previsions (this one and
    /// every one after it disappear, no new one will be generated) and
    /// reconciles the notifications. Unlike `skipPrevision` (ignores ONE
    /// occurrence, the recurring item continues), this is the equivalent of
    /// changing the pattern's end date.
    func stopPatternAfter(_ prevision: BudgetPrevision) {
        guard let patternId = prevision.recurringPatternId,
              let pattern = patterns.first(where: { $0.id == patternId }) else { return }
        let cal = Calendar.current
        let newEnd = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: prevision.expectedDate))
            ?? prevision.expectedDate
        let updated = RecurringPattern(
            id: pattern.id, name: pattern.name, amountAvg: pattern.amountAvg,
            amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
            payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
            isActive: pattern.isActive, isManual: pattern.isManual,
            createdAt: pattern.createdAt, lastDetectedAt: pattern.lastDetectedAt,
            startDate: pattern.startDate, endDate: newEnd
        )
        // updatePattern() persists, regenerates the previsions within the new
        // range (so nothing after newEnd) and reschedules the notifications.
        updatePattern(updated)
    }

    func matchPrevision(_ prevision: BudgetPrevision, to transactionId: Int) {
        self.repo.updatePrevisionStatus(id: prevision.id, status: .matched, transactionId: transactionId)
        // Matched → cancel the notification (the due date was honored, no reminder needed)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    // MARK: - Computed Views

    /// Enriched previsions for the displayed month.
    /// The enriched list is CACHED (not recomputed on every read).
    ///
    /// ⚠️ This used to be a computed property: every read rebuilt the
    /// ~1300 previsions then sorted them. Views read it several times per
    /// render — sometimes inside a loop — which made the module
    /// unusable. It's now recomputed ONLY when its sources
    /// change (see the `didSet`s on `previsions`/`patterns`/`categories`), and
    /// the prevision → recurring-item association goes through a dictionary
    /// instead of a linear search.
    private(set) var enrichedPrevisions: [EnrichedPrevision] = []

    private func rebuildEnrichedPrevisions() {
        let patternsById = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        enrichedPrevisions = previsions.compactMap { prev in
            let pattern = prev.recurringPatternId.flatMap { patternsById[$0] }
            let catName = pattern?.categoryId.flatMap { categoryNameById[$0] }
            return EnrichedPrevision(
                prevision: prev,
                patternName: pattern?.name ?? "Manuel",
                categoryName: catName,
                frequency: pattern?.frequency ?? .monthly
            )
        }
        .sorted { $0.expectedDate < $1.expectedDate }
    }

    var pendingPrevisions: [EnrichedPrevision] {
        enrichedPrevisions.filter { $0.status == .pending }
    }

    var upcomingPrevisions: [EnrichedPrevision] {
        let next7 = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return pendingPrevisions.filter { $0.expectedDate <= next7 && $0.expectedDate >= Date() }
    }

    /// Monthly summary (for the dashboard) — all accounts
    func monthlySummary() async -> MonthlyBudgetSummary {
        let (start, end) = monthRange(displayedMonth)
        let txs = await Task.detached(priority: .userInitiated) {
            self.txRepo.fetchAllAccountsTransactions(from: start, to: end)
        }.value
        return monthlySummary(transactions: txs)
    }

    /// Synchronous variant: computes the summary from transactions already in
    /// memory (a cache kept by `BudgetView`), with no SQLite round trip. Used on a
    /// month swipe for an instant display of the summary bubble — the network/DB
    /// fetch is the main factor of the delay being eliminated here.
    func monthlySummary(transactions txs: [FinanceTransaction]) -> MonthlyBudgetSummary {
        let monthPrevisions = previsions.filter { $0.status != .skipped }
        // FIXED share of the plan = sum of negative previsions (identified recurring items).
        let recurringForecast = monthPrevisions.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
        // VARIABLE share of the plan = sum of the month's active envelopes MINUS
        // whatever is already covered by the recurring items in the same category (to
        // avoid double counting: if "Rent & Utilities" has a recurring item of
        // €950 AND an envelope of €1100, only the €150 delta is added).
        // Each recurring item's category, indexed ONCE: the original version
        // re-ran a `patterns.first(where:)` for every prevision of every
        // envelope (≈2.4M comparisons on a real database) — one of the two
        // hot spots freezing the module.
        let patternCategoryById = Dictionary(
            patterns.compactMap { p in p.categoryId.map { (p.id, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let envelopeForecast = envelopes
            .filter { $0.isActive }
            .reduce(0.0) { acc, env in
                let allocated = env.period == .yearly ? env.amount / 12 : env.amount
                guard let cid = env.categoryId else { return acc + allocated }
                let allIds = allCategoryIds(for: cid)
                // Recurring items already budgeted in this category (or sub-category)
                let alreadyCovered = monthPrevisions
                    .filter { p in
                        guard p.amount < 0 else { return false }
                        guard let patternId = p.recurringPatternId,
                              let patternCat = patternCategoryById[patternId]
                        else { return false }
                        return allIds.contains(patternCat)
                    }
                    .reduce(0.0) { $0 + abs($1.amount) }
                // If the recurring items exceed the envelope, the envelope adds nothing more.
                return acc + max(0, allocated - alreadyCovered)
            }
        let forecasted = recurringForecast + envelopeForecast
        let actual = txs.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
        let totalIncome = txs.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let matched = previsions.filter { $0.status == .matched }.count
        let pending = previsions.filter { $0.status == .pending }.count

        // IDs of transactions linked to confirmed previsions (real recurring charges)
        let matchedTxIds = Set(previsions.filter { $0.status == .matched }.compactMap { $0.actualTransactionId })
        let fixedActual = txs
            .filter { matchedTxIds.contains($0.id) && $0.amount < 0 }
            .reduce(0) { $0 + abs($1.amount) }

        // Shared engine — the same computation as the Dashboard, alerts and widget.
        // See `EnvelopeSpendingCalculator` for the history of the 4 diverging versions.
        let envelopeProgress = EnvelopeSpendingCalculator.progresses(
            envelopes: envelopes.filter { $0.isActive },
            transactions: txs,
            categories: categories,
            previsions: previsions,
            patterns: patterns
        )

        let monthStr = monthKey(displayedMonth)
        return MonthlyBudgetSummary(
            month: monthStr,
            forecastedExpenses: forecasted,
            actualExpenses: actual,
            matchedCount: matched,
            pendingCount: pending,
            envelopes: envelopeProgress,
            totalIncome: totalIncome,
            fixedActual: fixedActual
        )
    }

    /// Days of the displayed month for the calendar — all accounts
    /// ⚠️ Three perf fixes compared to the original version, which
    /// froze the window for several seconds:
    /// 1. `enrichedPrevisions` is read ONCE (it used to be re-read for every day of
    ///    the month, i.e. ~31 full recomputes of the enriched list);
    /// 2. indexed by day via `Dictionary(grouping:)` — O(n) — instead of a
    ///    full `filter` per day, O(n × 31);
    /// 3. key = `startOfDay` (a `Date`) instead of a formatted string: every
    ///    call to `isoDate` built a brand-new `DateFormatter`, which is
    ///    expensive, and there were tens of thousands of them.
    func calendarDays(transactions: [FinanceTransaction]) -> [CalendarDay] {
        calendarDays(for: displayedMonth, transactions: transactions, previsions: enrichedPrevisions)
    }

    /// A pure variant targeting an EXPLICIT month — reads neither `displayedMonth`
    /// nor `previsions`/`enrichedPrevisions`, unlike the overload
    /// above. Needed for the calendar's page carousel
    /// (`BudgetView`): the neighboring pages (M-1/M+1) must be
    /// pre-renderable from the cache WITHOUT depending on the
    /// currently displayed month — otherwise they'd show either the
    /// wrong month's day range, or the displayed month's previsions applied
    /// to another month's transactions.
    func calendarDays(for month: Date, transactions: [FinanceTransaction], previsions: [EnrichedPrevision]) -> [CalendarDay] {
        let cal = Calendar.current
        guard let range = cal.dateInterval(of: .month, for: month) else { return [] }
        let totalDays = cal.dateComponents([.day], from: range.start, to: range.end).day ?? 30
        let prevByDay = Dictionary(grouping: previsions) { cal.startOfDay(for: $0.expectedDate) }
        let txByDay = Dictionary(grouping: transactions) { cal.startOfDay(for: $0.date) }

        return (0..<totalDays).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: range.start) else { return nil }
            let key = cal.startOfDay(for: day)
            return CalendarDay(date: day,
                               previsions: prevByDay[key] ?? [],
                               transactions: txByDay[key] ?? [])
        }
    }

    /// Enriches a list of RAW previsions (e.g. `previsionsCache[key]`)
    /// with the recurring item's/category's name — the same logic as
    /// `rebuildEnrichedPrevisions()`, but pure (doesn't mutate `self.enrichedPrevisions`,
    /// doesn't depend on `self.previsions`). Used to enrich the
    /// already-preloaded previsions of a neighboring month without attaching them
    /// to the displayed month's.
    func enrichPrevisions(_ raw: [BudgetPrevision]) -> [EnrichedPrevision] {
        let patternsById = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return raw.compactMap { prev in
            let pattern = prev.recurringPatternId.flatMap { patternsById[$0] }
            let catName = pattern?.categoryId.flatMap { categoryNameById[$0] }
            return EnrichedPrevision(
                prevision: prev,
                patternName: pattern?.name ?? "Manuel",
                categoryName: catName,
                frequency: pattern?.frequency ?? .monthly
            )
        }
        .sorted { $0.expectedDate < $1.expectedDate }
    }

    /// Raw previsions already cached for `month` (`previsionsCache`, filled
    /// by `prefetchAdjacentPrevisions`) — `nil` if not preloaded yet.
    func cachedPrevisions(for month: Date) -> [BudgetPrevision]? {
        previsionsCache[monthKey(month)]
    }

    // MARK: - Duplicate Matching

    /// Tries to automatically match new transactions to pending previsions.
    func autoMatchTransactions(_ transactions: [FinanceTransaction]) {
        let matches = TransactionMatcher.autoMatch(
            transactions: transactions,
            previsions: previsions.filter { $0.status == .pending },
            patterns: patterns
        )
        guard !matches.isEmpty else { return }
        for m in matches {
            self.repo.updatePrevisionStatus(id: m.previsionId, status: .matched, transactionId: m.transactionId)
            // Auto-match → cancel the j-3 notification (the due date was honored)
            BudgetNotificationService.cancel(forPrevisionId: m.previsionId)
        }
        refresh()
    }

    // MARK: - Helpers

    private func monthRange(_ date: Date) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? date
        return (start, end)
    }

    private func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    /// REUSED formatter: building a new one on every call is expensive, and this
    /// function is called in a loop. POSIX locale for a stable format.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func isoDate(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    /// Returns a category's id + all of its children (for hierarchical envelopes)
    private func allCategoryIds(for categoryId: Int?) -> [Int] {
        guard let id = categoryId else { return [] }
        let children = categories.filter { $0.parentId == id }.map { $0.id }
        return [id] + children
    }
}


