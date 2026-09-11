import SwiftUI
import Charts

// MARK: - Security level (position detail)
//
// Detail screen of an individual position, reached from AccountDetailView.
// Shows:
//   - Position hero card (current value + variation over the range)
//   - KPIs: Quantity · Average cost · Current value · P&L abs+%
//   - Evolution chart with the orders highlighted
//   - Time range chips
//
// Each order is marked on the chart at its date, with its execution price.

struct InvestmentPositionDetailView: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    let position: InvestmentPosition

    @State private var localTimeRange: InvestmentTimeRange = .all
    @State private var priceHistory: [InvestmentPricePoint] = []
    /// 30-min INTRADAY series (1D range only) — loaded on demand when the user
    /// selects 1D, cached with a freshness skip under 25 min.
    @State private var intradayHistory: [InvestmentPricePoint] = []
    /// Loading state of the intraday series (1D range). While the fetch runs it's
    /// announced, and if it fails the reason is shown, rather than silently
    /// falling back to the daily series.
    @State private var intradayState: IntradayState = .idle

    enum IntradayState: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }
    @State private var isSyncing = false
    @State private var statusMessage: LocalizedStringResource?
    @State private var showEditForm = false
    /// Detail of the last sync (opened by the "?" button under the chart).
    @State private var showSyncDetail = false

    // orders
    // 2 distinct sheets, so tapping to edit can never create a new order:
    //   - showOrderAddForm  : new entry (order = nil)
    //   - editingOrder (Identifiable) : editing an existing order
    // A single shared `sheet(isPresented:)` with an optional `@State` suffers a
    // closure-capture race — the sheet can present with `editingOrder = nil`
    // right after it was assigned.
    @State private var orders: [InvestmentOrder] = []
    @State private var showOrderAddForm = false
    @State private var editingOrder: InvestmentOrder?

    // Interactive scrub on the position chart. "Pins" the chart under the finger
    // (consumes horizontal gestures), while letting vertical scrolling work (the
    // gesture rejects vertical drags).
    @State private var chartSelectedDate: Date?

    // Suppression position
    @State private var showDeletePositionConfirm = false
    /// Skeleton until `.task` has finished loadCachedHistory + loadOrders.
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismissDetail
    /// macOS: the sheet lives in the side pane (AdaptivePane) — `\.dismiss` is a
    /// no-op there, closing goes through `\.paneDismiss` (a no-op everywhere
    /// else: both calls coexist without a platform guard).
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState

    private let repository = InvestmentRepository()

    // MARK: - Derived

    /// The position's value over time = qty_at_that_date × close.
    ///
    /// The HISTORICAL quantity at each point (computed from the orders: Σ BUY −
    /// Σ SELL before the date) is used instead of the current quantity.
    /// Otherwise a sold position would show a flat line at 0, even though it had
    /// a market value while it was held.
    private var positionValuePoints: [PortfolioEvolutionPoint] {
        let cutoff = localTimeRange.startDate
        return priceHistory
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let cutoff else { return true }
                return point.date >= cutoff
            }
            .map { point in
                PortfolioEvolutionPoint(
                    date: point.date,
                    value: point.close * quantityAt(date: point.date)
                )
            }
    }

    /// Quantity held at a given date, rebuilt from the orders.
    /// Σ BUY − Σ SELL on or before `date`. DIVs don't affect the quantity.
    /// Clamped to 0 if there are more SELLs than BUYs (corrupted data edge case).
    private func quantityAt(date: Date) -> Double {
        var qty: Double = 0
        for order in orders where order.executedAt <= date {
            switch order.orderType {
            case .buy:      qty += order.quantity
            case .sell:     qty -= order.quantity
            case .dividend: break
            }
        }
        return max(0, qty)
    }

    /// Weighted average cost at a given date, computed from the earlier BUYs.
    /// Σ(qty × price + fees) of the BUYs / Σ qty of the BUYs.
    /// Used for the "gain/loss zone" shading on the chart: the area between the
    /// price curve and the average cost line at that instant shows the unrealized
    /// gain/loss.
    private func pruAt(date: Date) -> Double {
        var totalQty: Double = 0
        var totalCost: Double = 0
        for order in orders.sorted(by: { $0.executedAt < $1.executedAt })
            where order.executedAt <= date && order.orderType == .buy {
            totalQty += order.quantity
            totalCost += order.quantity * order.unitPrice + order.fees
        }
        return totalQty > 0 ? totalCost / totalQty : 0
    }

    /// "Current" weighted average cost (all BUYs combined). Used for the
    /// horizontal RuleMark that marks the break-even threshold.
    private var currentWeightedPRU: Double {
        pruAt(date: Date())
    }

    /// Price points filtered to the time range. Feed the main chart (close × 1,
    /// not × qty — the security is shown, not the holding).
    private var positionPricePoints: [InvestmentPricePoint] {
        let cutoff = localTimeRange.startDate
        return priceHistory
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let cutoff else { return true }
                return point.date >= cutoff
            }
    }

    /// SANITIZED points for chart rendering: sorted by date, a single point per
    /// time step, finite and strictly positive `close`, AND outliers rejected
    /// (`rejectOutliers`).
    ///
    /// Granularity matched to the range: on 1D the 30-min INTRADAY series of the
    /// last rolling 24 h is drawn (the daily series has a single point over that
    /// window — nothing to draw); otherwise the daily series, deduplicated per
    /// calendar day ("barcode" prevention).
    private var chartPoints: [InvestmentPricePoint] {
        if localTimeRange == .oneDay {
            // NO fallback to the daily series on 1D.
            //
            // Without intraday quotes, filtering the DAILY series over 24 h leaves one or
            // two closing points — drawn as an ordinary curve. The user would see a
            // straight line between two points, believing it's the day, with nothing to
            // tell them the intraday series was missing. An explicit empty state (see
            // `intradayState`) beats a curve fabricated from another granularity.
            guard !intradayHistory.isEmpty else { return [] }
            // One point per TIMESTAMP (not per day!), window of the last 24 TRADED hours
            // — anchored on the last available point, not on `Date()`, otherwise the
            // view is empty outside trading hours (see `lastQuotedWindow`).
            var seen = Set<Date>()
            let deduped = intradayHistory
                .filter { $0.close.isFinite && $0.close > 0 }
                .lastQuotedWindow()
                .filter { seen.insert($0.date).inserted }
            return rejectOutliers(deduped)
        }

        var seenDays = Set<Date>()
        let cal = Calendar.current
        let deduped = positionPricePoints
            .filter { $0.close.isFinite && $0.close > 0 }
            .filter { seenDays.insert(cal.startOfDay(for: $0.date)).inserted }
        return rejectOutliers(deduped)
    }

    /// "Barcode" prevention (2nd line of defense): a price series can be
    /// CONTAMINATED by two incompatible price scales merged under the same
    /// identifier — e.g. a ticker resolving to the wrong Yahoo instrument. The
    /// chart would then alternate between €35 and €300 from one point to the next
    /// → a comb. Every point outside [median / 4, median × 4] is dropped: a single
    /// scale survives, and the rendering stays smooth.
    private func rejectOutliers(_ points: [InvestmentPricePoint]) -> [InvestmentPricePoint] {
        guard points.count >= 4 else { return points }
        let sortedCloses = points.map(\.close).sorted()
        let median = sortedCloses[sortedCloses.count / 2]
        guard median > 0 else { return points }
        let lower = median / 4, upper = median * 4
        let cleaned = points.filter { $0.close >= lower && $0.close <= upper }
        // If the filter drops everything (pathological median), fall back to the
        // deduplicated series rather than showing an empty chart.
        return cleaned.isEmpty ? points : cleaned
    }

    /// Secondary chart markers: average cost + the visible BUY/SELL prices.
    /// Dividends are EXCLUDED (a few cents per share: including them would
    /// squash the Y axis towards 0).
    ///
    /// These are markers, NOT the series: they have no right to set the scale. A
    /// security bought at €250 that trades at €40 would otherwise force a 0–270
    /// domain on every range, and the month's movement (39 → 41 €) would read as
    /// a straight line. `ChartYDomain` only keeps them when they fall within
    /// reach of the curve; out of view, the marker is hidden (see
    /// `chartYDomain.contains(...)` at render), the curve isn't squashed.
    private var chartYReferences: [Double] {
        var refs = visibleOrders
            .filter { $0.orderType != .dividend }
            .map(\.unitPrice)
        if currentWeightedPRU > 0 { refs.append(currentWeightedPRU) }
        return refs
    }

    /// Y domain computed on the DRAWN series (`chartPoints`, not
    /// `positionPricePoints`: on 1D the domain must follow the intraday series).
    private var chartYDomain: ClosedRange<Double> {
        ChartYDomain.compute(values: chartPoints.map(\.close),
                             references: chartYReferences,
                             padding: 0.08,
                             clampToZero: true)
    }

    /// Orders to show on the chart: those falling within the selected time range.
    /// For "Max" (cutoff == nil) every order is taken.
    private var visibleOrders: [InvestmentOrder] {
        guard let cutoff = localTimeRange.startDate else { return orders }
        return orders.filter { $0.executedAt >= cutoff }
    }

    /// Chart annotation color for each order type.
    private func annotationColor(_ type: InvestmentOrderType) -> Color {
        switch type {
        case .buy:      return AppTheme.Colors.success         // purchase = long-term entry = green
        case .sell:     return AppTheme.Colors.danger          // vente = sortie = rouge
        case .dividend: return AppTheme.Colors.accentSecondary // dividende = brun secondaire
        }
    }

    /// True if the market value is unknown (not synced yet) but at least a cost
    /// basis is known from the BUY orders. In that case the cost basis is shown
    /// instead and the P&L hidden (it would otherwise be -100%).
    private var valuationIsEstimated: Bool {
        position.currentValue <= 0 && position.investedAmount > 0
    }
    /// True if the position was opened (at least 1 BUY) then closed (current net
    /// qty = 0). The hero/KPIs then talk about "realized P&L" over the whole
    /// holding period rather than a "value".
    private var isClosedPosition: Bool {
        position.quantity <= 0 && orders.contains { $0.orderType == .buy }
    }
    /// Value shown in the hero: market value if synced, otherwise the cost basis,
    /// so as not to show €0 when money was invested.
    private var displayedValuation: Double {
        valuationIsEstimated ? position.investedAmount : position.currentValue
    }

    /// Hero title adapted to the position's life cycle.
    private var heroTitle: LocalizedStringResource {
        if isClosedPosition { return "P&L réalisé sur la position" }
        if valuationIsEstimated { return "Valeur estimée (PRU × qty)" }
        return "Valeur de la position"
    }

    /// Adapted hero value:
    /// - Closed position → total realized P&L (positive or negative)
    /// - Not synced → cost basis
    /// - Synced → market value
    private var heroValue: Double {
        if isClosedPosition { return realizedPnL }
        return displayedValuation
    }

    /// Realized P&L = gains on past sales + dividends received.
    /// Method: for each SELL, (sell_price − average cost at that moment) ×
    /// qty_sold − fees. For each DIV, qty × unit_price is added.
    /// The average cost evolves with the BUYs (chronologically).
    private var realizedPnL: Double {
        var pnl: Double = 0
        var cumulativeBuyQty: Double = 0
        var cumulativeBuyCost: Double = 0
        let sorted = orders.sorted { $0.executedAt < $1.executedAt }
        for order in sorted {
            switch order.orderType {
            case .buy:
                cumulativeBuyQty += order.quantity
                cumulativeBuyCost += order.quantity * order.unitPrice + order.fees
            case .sell:
                // Weighted average cost at that instant
                let avgPRU = cumulativeBuyQty > 0 ? cumulativeBuyCost / cumulativeBuyQty : 0
                let saleProceeds = order.quantity * order.unitPrice - order.fees
                let costBasis = order.quantity * avgPRU
                pnl += saleProceeds - costBasis
            case .dividend:
                pnl += order.quantity * order.unitPrice
            }
        }
        return pnl
    }

    /// Unrealized P&L = current_value − qty × average cost. It's what disappears
    /// at the next full sale.
    private var unrealizedPnL: Double {
        position.currentValue - position.investedAmount
    }

    /// Total P&L = unrealized + realized. The figure shown first.
    private var totalPnL: Double { unrealizedPnL + realizedPnL }

    /// Total cumulative capital invested (Σ BUY costs, without deducting SELLs).
    /// The denominator of the variation % — more stable than `investedAmount`
    /// (which drops to 0 when the position is closed and would skew the variation %).
    private var totalInvestedEver: Double {
        var cost: Double = 0
        for order in orders where order.orderType == .buy {
            cost += order.quantity * order.unitPrice + order.fees
        }
        return cost
    }

    private var totalPnLPct: Double {
        totalInvestedEver > 0 ? (totalPnL / totalInvestedEver) * 100 : 0
    }
    private var pnl: Double { totalPnL }
    private var pnlPct: Double { totalPnLPct }
    private var pnlColor: Color {
        pnl >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    if !hasLoaded {
                        positionDetailSkeleton
                    } else {
                        heroAndChartCard
                        kpisCard
                        ordersCard       // — BUY/SELL/DIV order history
                        detailsCard
                        if let statusMessage {
                            AppCard {
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
            }
            .refreshable {
                await syncHistory()
            }
        }
        // Sync is triggered by pull-to-refresh on the ScrollView — no dedicated button.
        // macOS: hosted in the PANE (from the account sheet) → chrome declared via
        // paneChrome (Close / Delete / Edit in the system bar, a single pill).
        // iOS: pushed → NavigationStack + toolbar.
        #if os(macOS)
        .paneChrome(position.assetName.isEmpty ? position.ticker : position.assetName,
                    cancelLabel: "Fermer", onCancel: { paneDismiss() },
                    destructiveLabel: "Supprimer la position",
                    onDestructive: { showDeletePositionConfirm = true },
                    confirmLabel: "Modifier la position", confirmIcon: "pencil",
                    onConfirm: { showEditForm = true })
        #else
        .navigationTitle(position.assetName.isEmpty ? position.ticker : position.assetName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditForm = true
                    } label: {
                        Label("Modifier la position", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeletePositionConfirm = true
                    } label: {
                        Label("Supprimer la position", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        #endif
        .adaptivePane(isPresented: $showEditForm) {
            InvestmentPositionFormView(accountId: account.id, position: position) { p, isNew in
                viewModel.savePosition(p, isNew: isNew)
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(isPresented: $showOrderAddForm) {
            InvestmentOrderFormView(
                positionId: position.id,
                currency: account.currency,
                order: nil
            ) { savedOrder, _ in
                repository.addOrder(savedOrder)
                repository.recomputePositionFromOrders(positionId: position.id)
                loadOrders()
                viewModel.load()
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(item: $editingOrder) { orderToEdit in
            InvestmentOrderFormView(
                positionId: position.id,
                currency: account.currency,
                order: orderToEdit
            ) { savedOrder, _ in
                repository.updateOrder(savedOrder)
                repository.recomputePositionFromOrders(positionId: position.id)
                loadOrders()
                viewModel.load()
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(isPresented: $showSyncDetail) {
            InvestmentSyncDetailSheet(content: .single(syncTrace))
        }
        .confirmationDialog(
            "Supprimer cette position ?",
            isPresented: $showDeletePositionConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                viewModel.deletePosition(id: position.id)
                appState.dataRefreshToken = UUID()
                dismissDetail()   // iOS push: pop the stack
                paneDismiss()     // panneau macOS : fermeture (no-op ailleurs)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Tous les ordres rattachés (\(orders.count) au total) seront supprimés en cascade. Cette action est irréversible.")
        }
        .task {
            await Task.yield()
            loadCachedHistory()
            loadOrders()
            hasLoaded = true
            // If the view already opens on 1D (restored state), load the intraday series.
            if localTimeRange == .oneDay {
                await loadIntradayHistory()
            }
        }
        .onChange(of: localTimeRange) { _, newRange in
            // 1D range → on-demand fetch of the 30-min intraday series (skipped if fresh
            // < 25 min on the service side). The other ranges don't need it.
            if newRange == .oneDay {
                Task { await loadIntradayHistory() }
            }
        }
    }

    /// Loads the intraday series: network sync (with a freshness skip), then a
    /// cache read under the candidate identifiers (ISIN then ticker — the service
    /// stores under `bestSyncIdentifier`).
    ///
    /// The sync result is kept: any 1D failure — price rate-limited by the
    /// provider, symbol not found, network down — is surfaced instead of the
    /// screen silently showing a two-point line as if it were the day's curve.
    private func loadIntradayHistory() async {
        let identifier = position.bestSyncIdentifier
        guard !identifier.isEmpty else {
            intradayState = .unavailable("Aucun ticker ni ISIN sur cette position.")
            return
        }
        intradayState = .loading
        let outcome = await InvestmentAutoSyncService.shared.syncIntradayHistory(identifier: identifier)

        let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
        for candidate in candidates {
            let points = PriceHistoryCache.shared.fetch(identifier: candidate, resolution: .intraday30m)
            if !points.isEmpty {
                intradayHistory = points
                intradayState = .ready
                return
            }
        }
        intradayHistory = []
        intradayState = .unavailable(Self.intradayFailureMessage(outcome))
    }

    /// Text of the intraday sync result.
    private static func intradayFailureMessage(_ outcome: PositionSyncOutcome) -> String {
        switch outcome {
        case .success, .upToDate:
            // Sync reported OK but nothing cached: the instrument has no continuous
            // quotes (fund with a daily NAV, market closed for longer than the retention).
            return "Ce titre n'a pas de cotation en continu disponible — seul un cours de clôture quotidien existe."
        case .rateLimited(let provider, let retryAfter):
            return "\(provider.displayName) limite les requêtes — nouvelle tentative possible dans \(Int(retryAfter)) s."
        case .noData:
            return "Le fournisseur de cours n'a pas de données intrajournalières pour ce titre."
        case .invalidIdentifier:
            return "Identifiant de cotation invalide."
        case .networkError(let message):
            return "Cours intrajournaliers indisponibles : \(message)"
        }
    }

    // MARK: - Skeleton

    @ViewBuilder private var positionDetailSkeleton: some View {
        // Hero + chart
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SkeletonHero()
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonBlock(width: 38, height: 26, cornerRadius: 13)
                }
                Spacer()
            }
            SkeletonChart(height: 200)
        }
        // KPIs
        AppCard {
            HStack(spacing: AppTheme.Spacing.sm) {
                SkeletonStatBadge()
                SkeletonStatBadge()
                SkeletonStatBadge()
                SkeletonStatBadge()
            }
        }
        // Orders
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    SkeletonLine(width: 110, height: 15)
                    Spacer()
                    SkeletonCircle(size: 22)
                }
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        SkeletonCircle(size: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            SkeletonLine(width: 110, height: 13)
                            SkeletonLine(width: 70, height: 11)
                        }
                        Spacer()
                        SkeletonLine(width: 60, height: 13)
                    }
                }
            }
        }
        // Details
        AppCard {
            SkeletonFormSection(rows: 4)
        }
    }

    // MARK: - Cards

    /// Hero + chart, flat (no card), chips BELOW the chart.
    private var heroAndChartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            InvestmentHeroCard(
                title: heroTitle,
                currentValue: heroValue,
                // No visible variation on the estimate or on a closed position — it would
                // be misleading.
                previousValue: (valuationIsEstimated || isClosedPosition)
                    ? heroValue
                    : positionValuePoints.first?.value,
                currency: account.currency,
                rangeLabel: variationRangeLabel(localTimeRange)
            )

            if isClosedPosition {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                    Text("Position clôturée — \(realizedPnL >= 0 ? "plus-value" : "moins-value") réalisée \(realizedPnL, format: .currency(code: account.currency))")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if valuationIsEstimated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("Cours non synchronisé — la valeur affichée correspond au coût d'acquisition. Synchronise pour voir le P&L réel.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Reading band: entry price (open) → exit price (close) OF THE POINTED
            // CANDLE, with the difference in value and %. Both prices come from the
            // source (Yahoo/Stooq OHLC) and so change with each point scrubbed. Always
            // visible as soon as there is a curve: an annotation stuck to the point
            // would be truncated near the chart's edges.
            if !chartPoints.isEmpty {
                ChartScrubReadout(
                    reference: chartReadoutReference,
                    current: chartReadoutCurrent,
                    currency: account.currency,
                    referenceLabel: (readoutOpen?.isRealOpen ?? true) ? "Ouverture" : "Point précédent",
                    currentLabel: chartSelectedDate != nil ? "Cours pointé" : "Dernier cours",
                    deltaCaption: "sur ce point",
                    isScrubbing: chartSelectedDate != nil,
                    showsTime: localTimeRange == .oneDay
                )
                .padding(.top, AppTheme.Spacing.xs)
            }

            positionChart
                .padding(.top, AppTheme.Spacing.xs)

            TimeRangeChips(selection: $localTimeRange)

            // Info on the depth of available data. Lets the user understand that a
            // truncated 10Y chart isn't a bug: the ETF/stock is simply recent (Yahoo
            // only supplies history since the security's inception).
            if let earliest = priceHistoryEarliestDate {
                Text("Données disponibles depuis \(earliest, format: .dateTime.day().month(.abbreviated).year())")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if let trace = syncTrace {
                HStack(spacing: 6) {
                    Image(systemName: trace.status.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(syncTraceColor(trace.status))
                    (Text(LocalizedStringKey(trace.status.label)) + Text(" — \(trace.humanizedAttemptedAt)"))
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    SyncInfoButton(isPresented: $showSyncDetail)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    /// Identifiers used to find the sync trace (ISIN first, same logic as
    /// `bestSyncIdentifier`).
    private var syncTraceIdentifiers: [String] {
        [position.isin, position.ticker].filter { !$0.isEmpty }
    }

    private var syncTrace: InvestmentSyncTraceStore.Entry? {
        InvestmentSyncTraceStore.fetchBest(identifiers: syncTraceIdentifiers)
    }

    /// Candle read by the band: the one under the finger while scrubbing, the
    /// range's last one at rest.
    private var readoutCandle: InvestmentPricePoint? {
        if let selected = chartSelectedDate, let snapped = closestPoint(to: selected) {
            return snapped
        }
        return chartPoints.last
    }

    /// ENTRY price of the pointed point = the candle's open, as the source
    /// supplies it (`open` from Yahoo / Stooq). It's data SPECIFIC TO EACH
    /// POINT: it changes while scrubbing the curve, unlike the average cost,
    /// which is a constant of the position.
    ///
    /// Fallback when the source has no OHLC (CoinGecko, or a series cached
    /// without the `open` field): the previous point's close, which is the price
    /// at which the time step started. Same semantics, different name — hence
    /// the distinct UI label, so it doesn't pass for a real session open.
    private var readoutOpen: (value: Double, isRealOpen: Bool)? {
        guard let candle = readoutCandle else { return nil }
        if let open = candle.open, open > 0 { return (open, true) }
        guard let idx = chartPoints.firstIndex(where: { $0.id == candle.id }), idx > 0 else { return nil }
        return (chartPoints[idx - 1].close, false)
    }

    private var chartReadoutReference: ChartReadoutPoint? {
        readoutOpen.map { ChartReadoutPoint(value: $0.value) }
    }

    private var chartReadoutCurrent: ChartReadoutPoint? {
        readoutCandle.map { ChartReadoutPoint(date: $0.date, value: $0.close) }
    }

    /// Date of the oldest stored price point for this position. Used to show
    /// "Data available since ..." and explain why a 10Y chart can be truncated
    /// (Yahoo only returns data since inception).
    private var priceHistoryEarliestDate: Date? {
        priceHistory.map(\.date).min()
    }

    /// PRICE chart of the security (close × 1, not multiplied by qty).
    /// Also shows:
    ///   - Horizontal average cost (RuleMark) = break-even threshold for all BUYs
    ///   - Gain/loss zone (AreaMark) between the average cost and the curve while
    ///     the position is held: green if price > average cost, red otherwise
    ///   - BUY/SELL/DIV markers at (executedAt, unitPrice) of the circle
    @ViewBuilder
    private var positionChart: some View {
        if chartPoints.isEmpty {
            VStack(spacing: 8) {
                if localTimeRange == .oneDay, intradayState == .loading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Récupération des cours de la journée…")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                    // On 1D, the missing curve has a SPECIFIC cause (no continuous quote,
                    // provider limited…): state it, rather than the generic "no history"
                    // message, which would suggest a global sync failure.
                    if localTimeRange == .oneDay, case .unavailable(let reason) = intradayState {
                        Text("Pas de cours intrajournalier")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, AppTheme.Spacing.md)
                        Button("Réessayer") {
                            Task { await loadIntradayHistory() }
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.Colors.accent)
                    } else {
                        Text("Aucun historique synchronisé")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Button("Synchroniser maintenant") {
                            Task { await syncHistory() }
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.Colors.accent)
                        .disabled(position.bestSyncIdentifier.isEmpty || isSyncing)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            let pru = currentWeightedPRU
            let firstPrice = chartPoints.first?.close ?? 0
            let lastPrice = chartPoints.last?.close ?? 0
            let trendColor: Color = lastPrice >= firstPrice
                ? AppTheme.Colors.success
                : AppTheme.Colors.danger
            let baseline = chartYDomain.lowerBound

            Chart {
                // Area + line in A SINGLE ForEach (same pattern as EvolutionChart). Two
                // separate ForEach, or an `if` inside, break the series' continuity and
                // render each point as an isolated vertical bar ("barcode"). The held
                // position (gain/loss vs average cost) reads through the curve being above /
                // below the average cost RuleMark.
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", baseline),
                        yEnd: .value("Cours", point.close)
                    )
                    .foregroundStyle(trendColor.opacity(0.14))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Cours", point.close)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                }

                // Horizontal line at the average cost = visual break-even threshold.
                // Above = profit zone, below = loss zone.
                // Hidden when it leaves the domain: the average cost is a marker, it doesn't
                // justify flattening the curve to stay visible. It stays readable in the
                // KPIs and the Details card.
                if pru > 0, chartYDomain.contains(pru) {
                    RuleMark(y: .value("PRU", pru))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("PRU \(pru, format: .currency(code: account.currency))")
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppTheme.Colors.surface.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                }

                // BUY/SELL markers at the order's unit price.
                // DIVs are placed on the PRICE line at their date — a dividend's amount
                // (€1.70) has nothing to do with the price (€60), so plotting them at €1.70
                // would squash the Y axis towards 0 and hide the price's real range. The
                // temporal position (vertical date) is kept: that's the useful info for a DIV.
                ForEach(visibleOrders) { order in
                    let markerY: Double = {
                        switch order.orderType {
                        case .dividend:
                            // Positioned on the price at the dividend's date.
                            // Falls back to the average cost if there's no price at that date.
                            let closeAtDate = priceHistory
                                .filter { $0.date <= order.executedAt }
                                .max(by: { $0.date < $1.date })?
                                .close
                            return closeAtDate ?? pru
                        case .buy, .sell:
                            return order.unitPrice
                        }
                    }()
                    RuleMark(x: .value("Ordre", order.executedAt))
                        .foregroundStyle(annotationColor(order.orderType).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))

                    // The dot is placed only if its price fits within the domain; otherwise the
                    // vertical rule alone carries the useful info (the order's DATE) rather than
                    // forcing the scale open up to a price that is now far away.
                    if chartYDomain.contains(markerY) {
                        PointMark(
                            x: .value("Ordre", order.executedAt),
                            y: .value("Cours", markerY)
                        )
                        .foregroundStyle(annotationColor(order.orderType))
                        .symbol {
                            ZStack {
                                Circle()
                                    .fill(AppTheme.Colors.surface)
                                    .frame(width: 10, height: 10)
                                Circle()
                                    .strokeBorder(annotationColor(order.orderType), lineWidth: 2)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .symbolSize(70)
                    }
                }

                // Visual indicator while the user scrubs the chart (vertical line + dot on
                // the curve). Only appears when chartSelectedDate is set.
                if let selected = chartSelectedDate,
                   let snapped = closestPoint(to: selected) {
                    RuleMark(x: .value("Scrub", snapped.date))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Scrub", snapped.date),
                              y: .value("Cours", snapped.close))
                        .foregroundStyle(trendColor)
                        .symbolSize(120)
                }
            }
            .chartYScale(domain: chartYDomain)
            .chartXAxis {
                // Ticks adapted to the time range (5Y/10Y/Max → yearly ticks formatted
                // yyyy, 1D → hours, etc.).
                let span: TimeInterval = {
                    guard let first = positionPricePoints.first?.date,
                          let last = positionPricePoints.last?.date else { return 0 }
                    return max(0, last.timeIntervalSince(first))
                }()
                let config = InvestmentChartXAxisConfig.config(for: localTimeRange, span: span)
                // `.stride(by:count:)` can produce DOZENS of ticks on long ranges (5Y/Max):
                // labels overlap AND inflate the chart's intrinsic width, making the whole
                // view horizontally scrollable. Capped at ~5 ticks.
                AxisMarks(position: .bottom, values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: config.labelFormat)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                }
            }
            .chartYAxis {
                // Bounded desiredCount (like EvolutionChart): an unbounded Y axis could
                // generate too many ticks/gridlines and weigh down the layout.
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                    AxisGridLine()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.08))
                }
            }
            // Interactive scrub (consumes horizontal drags so the chart feels "pinned"
            // under the finger, lets vertical drags through to the parent ScrollView for
            // page scrolling).
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    let dx = abs(value.translation.width)
                                    let dy = abs(value.translation.height)
                                    guard dx > dy else {
                                        if chartSelectedDate != nil { chartSelectedDate = nil }
                                        return
                                    }
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let locationX = value.location.x - origin.x
                                    if let date: Date = proxy.value(atX: locationX) {
                                        let previous = chartSelectedDate.flatMap { closestPoint(to: $0)?.date }
                                        chartSelectedDate = date
                                        // Discreet tick on each point change (not on every pixel traveled).
                                        if closestPoint(to: date)?.date != previous {
                                            HapticService.shared.selection()
                                        }
                                    }
                                }
                                .onEnded { _ in chartSelectedDate = nil }
                        )
                }
            }
            // NO `.frame(maxWidth: .infinity)` here. Combined with the
            // `.chartOverlay { GeometryReader }` above, it creates an AutoLayout layout
            // LOOP on macOS (recursive NSISEngine / _updateConstraintsForSubtree) →
            // beachball, then an NSException crash when opening a position.
            // EvolutionChart only has a `.frame(height:)`. The X axis density is already
            // bounded (desiredCount: 5), so maxWidth isn't needed to avoid horizontal
            // scrolling.
            .frame(height: 220)
        }
    }

    /// Finds the history point closest in time to `date`.
    /// Used to snap the scrub to a real data point (not an interpolation).
    private func closestPoint(to date: Date) -> InvestmentPricePoint? {
        chartPoints.min(by: { a, b in
            abs(a.date.timeIntervalSince(date)) < abs(b.date.timeIntervalSince(date))
        })
    }

    /// Total dividends received over the position's lifetime. Used for the
    /// breakdown in the Performance card.
    private var totalDividends: Double {
        orders.filter { $0.orderType == .dividend }
              .reduce(0) { $0 + $1.quantity * $1.unitPrice }
    }

    /// Realized P&L on sales only (without dividends), used for the breakdown
    /// shown for a closed position.
    private var realizedSellsPnL: Double {
        realizedPnL - totalDividends
    }

    private var kpisCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SectionHeader(title: "Performance")
                if valuationIsEstimated {
                    // No synced price → a -100% P&L would be wrong and alarming.
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("P&L disponible après synchronisation du cours")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                } else if isClosedPosition {
                    // Closed position: the realized part is detailed, so as not to show a
                    // misleading P&L of 0.
                    HStack(spacing: AppTheme.Spacing.sm) {
                        StatBadge(
                            label: "P&L total",
                            value: realizedPnL.formatted(.currency(code: account.currency).locale(appState.locale)),
                            valueColor: realizedPnL >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                        )
                        StatBadge(
                            label: "Variation",
                            value: String(format: "%@%.2f %%",
                                          realizedPnL >= 0 ? "+" : "",
                                          totalInvestedEver > 0 ? (realizedPnL / totalInvestedEver) * 100 : 0),
                            valueColor: realizedPnL >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                        )
                    }
                    // Breakdown: capital gain on sales + dividends
                    VStack(alignment: .leading, spacing: 4) {
                        breakdownRow(
                            label: "Plus-value sur ventes",
                            value: realizedSellsPnL,
                            currency: account.currency
                        )
                        if totalDividends > 0 {
                            breakdownRow(
                                label: "Dividendes reçus",
                                value: totalDividends,
                                currency: account.currency
                            )
                        }
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        StatBadge(
                            label: "P&L total",
                            value: totalPnL.formatted(.currency(code: account.currency).locale(appState.locale)),
                            valueColor: pnlColor
                        )
                        StatBadge(
                            label: "Variation",
                            value: String(format: "%@%.2f %%", totalPnL >= 0 ? "+" : "", totalPnLPct),
                            valueColor: pnlColor
                        )
                    }
                    // Breakdown if realized > 0 (dividends or partial sales)
                    if realizedPnL != 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            breakdownRow(
                                label: "dont latent (sur titres détenus)",
                                value: unrealizedPnL,
                                currency: account.currency
                            )
                            breakdownRow(
                                label: "dont réalisé (ventes + dividendes)",
                                value: realizedPnL,
                                currency: account.currency
                            )
                        }
                        .padding(.top, AppTheme.Spacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownRow(label: LocalizedStringKey, value: Double, currency: String) -> some View {
        HStack {
            Text(label)
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value, format: .currency(code: currency))
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(value >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
        }
    }

    private var detailsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Détails")
                detailRow("Ticker", value: position.ticker.isEmpty ? "—" : position.ticker)
                detailRow("ISIN", value: position.isin.isEmpty ? "— (à renseigner pour sync fiable)" : position.isin)
                detailRow("Type", value: InvestmentAssetType(looselyMatching: position.assetType)?.label ?? position.assetType)
                detailRow("Quantité", value: String(format: "%.6f", position.quantity).trimmedZeros)
                detailRow("PRU", value: position.averageBuyPrice.formatted(.currency(code: account.currency).locale(appState.locale)))
                detailRow("Investi", value: position.investedAmount.formatted(.currency(code: account.currency).locale(appState.locale)))
                detailRow("Date d'achat", value: position.purchaseDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appState.locale)))
                detailRow("Compte", value: "\(account.name) · \(account.accountType)", isLast: true)
            }
        }
    }

    private func syncTraceColor(_ status: InvestmentSyncTraceStore.Status) -> Color {
        switch status {
        case .success:                      return AppTheme.Colors.success
        case .noData, .invalidId:           return AppTheme.Colors.warning
        case .rateLimited:                  return AppTheme.Colors.warning
        case .error:                        return AppTheme.Colors.danger
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            .padding(.vertical, 8)
            if !isLast {
                Divider().background(AppTheme.Colors.textSecondary.opacity(0.1))
            }
        }
    }

    // MARK: - Helpers

    /// Loads the price history by trying several identifiers:
    /// ISIN > ticker > symbol(s) resolved by the last sync trace.
    ///
    /// "Sync all prices" uses `bestSyncIdentifier` (the ISIN when available).
    /// OpenFIGI resolves the ISIN (e.g. FR0011871110 → PUST.PA), and the points
    /// are stored under that key — looking up by `position.ticker` (AMUN.PEA)
    /// alone would leave the chart empty even with hundreds of stored points.
    private func loadCachedHistory() {
        // 1. Try the ISIN first (highest priority, canonical identifier)
        // 2. Then the ticker
        let candidates = [position.isin, position.ticker]
            .filter { !$0.isEmpty }

        for candidate in candidates {
            let history = repository.fetchPriceHistory(identifier: candidate)
            if !history.isEmpty {
                priceHistory = history
                return
            }
        }

        // 3. Fallback: if the last sync succeeded via a resolved symbol (e.g. ISIN →
        //    PUST.PA via OpenFIGI), try to find the points stored under that symbol.
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
           trace.status == .success {
            for symbol in trace.symbolsTried {
                let history = repository.fetchPriceHistory(identifier: symbol)
                if !history.isEmpty {
                    priceHistory = history
                    return
                }
            }
        }

        priceHistory = []
    }

    /// Reloads this position's orders (chronological, ASC).
    private func loadOrders() {
        orders = repository.fetchOrders(positionId: position.id)
    }

    /// "Orders" card — operation history + a + button to add one.
    /// Lists BUY/SELL/DIV in reverse chronological order (most recent first).
    /// Tap disabled (prevents accidental edits). Leading swipe = Edit, trailing
    /// swipe = Delete (with automatic qty/average cost recompute).
    private var ordersCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    SectionHeader(title: "Ordres (\(orders.count))")
                    Spacer()
                    Button {
                        showOrderAddForm = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }

                if orders.isEmpty {
                    Text("Aucun ordre enregistré. Tape + pour ajouter un achat, une vente ou un dividende.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    // Edit/delete via iOS swipe AND macOS right-click (RowActions). No tap on
                    // purpose: an order affects the P&L, so accidental tap edits are avoided.
                    let reversed = orders.reversed().map { $0 }
                    // NO `List` on EITHER platform — same trap as `positionsCard`
                    // (InvestmentAccountDetailView): on macOS a nested List hits an AutoLayout
                    // constraint loop (NSException _postWindowNeedsUpdateConstraints); on iOS a
                    // `.scrollDisabled(true)` `List` nested in a `ScrollView` VIRTUALIZES its
                    // rows, so any height guessed OR measured from its own content is
                    // structurally fragile (measuring even enters a feedback loop: shrinking the
                    // List renders fewer rows, hence measures less, hence shrinks further). A
                    // `VStack` needs no guessed height — sound on both platforms, with no `#if`
                    // branch needed here (no tap on the row, only RowActions swipe/right-click,
                    // already cross-platform).
                    VStack(spacing: 0) {
                        ForEach(reversed) { order in
                            orderRowContent(order)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .rowActions(
                                    leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingOrder = order }],
                                    trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { deleteOrder(order) }]
                                )
                            if order.id != reversed.last?.id {
                                Divider()
                                    .overlay(AppTheme.Colors.textSecondary.opacity(0.1))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Visual content of an order — extracted to be placed in a row (actions via
    /// RowActions: iOS swipe / macOS right-click).
    @ViewBuilder
    private func orderRowContent(_ order: InvestmentOrder) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: order.orderType.systemIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(orderColor(order.orderType))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(order.orderType.label))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                HStack(spacing: 4) {
                    Text("\(order.quantity, specifier: "%.4f") @ \(order.unitPrice, format: .currency(code: account.currency))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if order.fees > 0 {
                        Text("· frais \(order.fees, format: .currency(code: account.currency))")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(order.totalCost, format: .currency(code: account.currency))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(orderColor(order.orderType))
                Text(order.executedAt, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func orderColor(_ type: InvestmentOrderType) -> Color {
        switch type {
        case .buy:      return AppTheme.Colors.danger    // sortie cash = rouge
        case .sell:     return AppTheme.Colors.success   // cash inflow = green
        case .dividend: return AppTheme.Colors.accentSecondary
        }
    }

    private func deleteOrder(_ order: InvestmentOrder) {
        _ = repository.deleteOrder(id: order.id)
        repository.recomputePositionFromOrders(positionId: position.id)
        loadOrders()
        viewModel.load()
        appState.dataRefreshToken = UUID()
    }

    private func syncHistory() async {
        isSyncing = true
        defer { isSyncing = false }

        // Preferred identifier: the ISIN when present (traditional securities),
        // OTHERWISE the ticker (cryptos have no ISIN; "BTC", "ETH" etc).
        // syncMarketHistory routes automatically to CoinGecko or Yahoo depending on
        // whether the identifier is recognized as a crypto.
        let identifier = position.bestSyncIdentifier
        guard !identifier.isEmpty else {
            statusMessage = LocalizedStringResource("Aucun ISIN ni ticker — impossible de synchroniser.")
            return
        }
        await viewModel.syncMarketHistory(for: identifier)
        statusMessage = viewModel.marketStatusMessage
        loadCachedHistory()
    }

    private func variationRangeLabel(_ range: InvestmentTimeRange) -> LocalizedStringResource {
        switch range {
        case .oneDay:     return "sur 1 jour"
        case .oneWeek:    return "sur 1 semaine"
        case .oneMonth:   return "sur 1 mois"
        case .threeMonth: return "sur 3 mois"
        case .sixMonth:   return "sur 6 mois"
        case .oneYear:    return "sur 1 an"
        case .fiveYear:   return "sur 5 ans"
        case .tenYear:    return "sur 10 ans"
        case .all:        return "depuis l'origine"
        }
    }
}

// MARK: - String trimming helper

private extension String {
    /// Strips useless trailing decimal zeros ("12.5000" → "12.5", "10.000000" → "10")
    var trimmedZeros: String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
