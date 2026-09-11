import SwiftUI
import Charts

// MARK: - Account level
//
// Detail screen of an investment account, reached from the dashboard's
// account list. Mirrors the global dashboard's structure, restricted to this
// account's positions:
//   - Hero card (account value + variation + invested + P/L)
//   - Account evolution chart (time chips)
//   - Internal allocation donut (by asset type)
//   - List of tappable positions (→ PositionDetailView)
//
// Toolbar: "+ position" button to add one manually.

struct InvestmentAccountDetailView: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    /// macOS: back to the global dashboard. The account is shown FULL PAGE in the
    /// module column (internal navigation by state — see
    /// `InvestmentsView.dashboardContent`), so it supplies its own back button.
    /// nil on iOS, where the view is pushed and the `NavigationStack` back is enough.
    var onBack: (() -> Void)? = nil

    @State private var localTimeRange: InvestmentTimeRange = .threeMonth
    @State private var evolution: [PortfolioEvolutionPoint] = []
    /// Explanation shown when the 1D range has no intraday price (curve left
    /// empty on purpose rather than fabricated from daily data).
    @State private var oneDayUnavailableNote: String?
    /// Positions without price history → the chart can't include their value.
    /// Shown as a diagnostic.
    @State private var positionsWithoutHistory: [InvestmentPosition] = []
    @State private var positions: [InvestmentPosition] = []
    // add (Bool) + edit (Identifiable item) kept separate, so a state race can
    // never make "edit" open the add form.
    @State private var showAddPositionForm = false
    @State private var editingPosition: InvestmentPosition?
    #if os(macOS)
    /// macOS: the position sheet opens in the global SIDE PANE (`.adaptivePane`).
    /// A clicked push from depth 1 to 2 triggers an AutoLayout
    /// `_postWindowNeedsUpdateConstraints` recursion on macOS, even when driven
    /// by state (navigationDestination). The pane stacks no view in the
    /// NavigationStack, so that machinery is never hit.
    @State private var panePosition: InvestmentPosition?
    #endif

    // Account edit / delete
    @State private var showAccountEditForm = false
    @State private var showDeleteAccountConfirm = false
    // Suppression position
    @State private var positionToDelete: InvestmentPosition?

    // Sync de masse
    @State private var isSyncingAll = false
    // `LocalizedStringResource`, not `String` — same reason as
    // `InvestmentAutoSyncService.lastSummary`: otherwise frozen in the language
    // active at sync time rather than resolved at display.
    @State private var syncAllStatus: LocalizedStringResource?
    /// "?" detail — the account's positions with their last sync status.
    @State private var showSyncDetail = false
    /// Skeleton until the 1st `refresh()` has finished.
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss
    // paneDismiss: closing from the macOS pane (drill-down from InvestmentsView,
    // not a push — see \.paneHostContext below). No effect on iOS, where this
    // view stays pushed (NavigationLink, automatic back).
    @Environment(\.paneDismiss) private var paneDismiss
    #if os(macOS)
    @Environment(\.paneHostContext) private var paneHostContext
    #endif
    @Environment(AppState.self) private var appState

    private var invested: Double {
        positions.reduce(0) { $0 + $1.investedAmount }
    }

    /// Total valuation = positions' value + available cash.
    /// Cash is NOT part of the performance computation — it's neutral (invested
    /// cash vs raw cash). Performance = positions only.
    private var totalAccountValue: Double {
        account.currentValue + account.cashBalance
    }

    private var performance: Double {
        account.currentValue - invested
    }

    private var performanceColor: Color {
        performance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    /// True if no position of the account is synced (`account.currentValue ≤ 0`)
    /// but something has been invested. Avoids a misleading "€0 / Performance
    /// -100%" until prices have been fetched.
    private var valuationIsEstimated: Bool {
        account.currentValue <= 0 && invested > 0
    }

    /// Hero shows market value if synced, else cost basis (= invested).
    /// Includes cash IF the user toggle allows it.
    private var displayedValuation: Double {
        let baseValuation = valuationIsEstimated ? invested : account.currentValue
        let cash = appState.investmentsIncludeCashInTotal ? account.cashBalance : 0
        return baseValuation + cash
    }

    private var allocation: [AllocationSlice] {
        viewModel.allocationByAssetType(accountId: account.id)
    }

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    if !hasLoaded {
                        accountDetailSkeleton
                    } else {
                        heroAndChartCard
                        if !positionsWithoutHistory.isEmpty {
                            missingHistoryDiagnosticCard
                        }
                        kpisCard
                        if !allocation.isEmpty {
                            allocationCard
                        }
                        if !positions.isEmpty {
                            positionsCard
                        } else {
                            emptyPositionsCard
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
            }
            .refreshable {
                await syncAllPositions()
            }
        }
        // Module content (full page) on BOTH platforms → native toolbar. On macOS it
        // also carries the back-to-dashboard button.
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .adaptivePane(isPresented: $showAddPositionForm) {
            InvestmentPositionFormView(accountId: account.id, position: nil) { position, isNew in
                viewModel.savePosition(position, isNew: isNew)
                refresh()
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(item: $editingPosition) { position in
            InvestmentPositionFormView(accountId: account.id, position: position) { updated, isNew in
                viewModel.savePosition(updated, isNew: isNew)
                refresh()
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(isPresented: $showAccountEditForm) {
            InvestmentAccountFormView(account: account) { updated, isNew in
                viewModel.saveAccount(updated, isNew: isNew)
                refresh()
                appState.dataRefreshToken = UUID()
            }
        }
        .adaptivePane(isPresented: $showSyncDetail) {
            InvestmentSyncDetailSheet(content: .list(summary: nil, positions: syncPositionStatuses))
        }
        // Confirmation suppression compte
        .confirmationDialog(
            "Supprimer ce compte ?",
            isPresented: $showDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer le compte", role: .destructive) {
                viewModel.deleteAccount(id: account.id)
                appState.dataRefreshToken = UUID()
                // Both: `dismiss` pops (iOS, push), `paneDismiss` closes the pane (macOS) —
                // each is a no-op outside its context.
                dismiss()
                paneDismiss()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Toutes les positions et ordres rattachés à ce compte seront aussi supprimés (cascade).")
        }
        // Position deletion confirmation (triggered by the row's contextMenu)
        .confirmationDialog(
            positionToDelete.map { "Supprimer \"\($0.assetName.isEmpty ? $0.ticker : $0.assetName)\" ?" } ?? "Supprimer cette position ?",
            isPresented: Binding(
                get: { positionToDelete != nil },
                set: { if !$0 { positionToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: positionToDelete
        ) { pos in
            Button("Supprimer", role: .destructive) {
                viewModel.deletePosition(id: pos.id)
                positionToDelete = nil
                refresh()
                appState.dataRefreshToken = UUID()
            }
            Button("Annuler", role: .cancel) { positionToDelete = nil }
        } message: { _ in
            Text("Tous les ordres rattachés seront aussi supprimés.")
        }
        .task {
            await Task.yield()
            refresh()
            hasLoaded = true
        }
        .onChange(of: localTimeRange) { _, newRange in
            recomputeEvolution()
            // 1D range → on-demand fetch of the account positions' 30-min intraday
            // series, then recompute once the points are in.
            if newRange == .oneDay {
                Task {
                    await InvestmentAutoSyncService.shared.syncIntradayIfNeeded(
                        identifiers: positions.map(\.bestSyncIdentifier)
                    )
                    recomputeEvolution()
                }
            }
        }
    }

    // MARK: - Toolbar (extracted into a ViewBuilder to help the type-checker)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Sync is triggered by pull-to-refresh on the ScrollView — no dedicated button.
        #if os(macOS)
        // Back to the global dashboard: the account occupies the module column (not
        // a push), so it supplies its own back button. `.navigation` is the system
        // back's placement, left of the title.
        if let onBack {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Tous les comptes")
                .localizedAccessibilityLabel("Tous les comptes")
            }
        }
        // "⋯" menu flattened into icon buttons + tooltips in ONE pill via
        // `ToolbarItemGroup` (native grouping — `ControlGroup` rendered isolated
        // buttons), consistent with the app's other macOS toolbars.
        ToolbarItemGroup(placement: .topBarTrailing) {
            PaneToggleButton(label: "Ajouter une position", systemImage: "plus", isOn: $showAddPositionForm)
            // Only shown if the account holds cryptos — repairs values corrupted by
            // Yahoo syncs on same-named tickers (FET → the FET stock trading at €53,
            // ETH → Ethernity, etc.)
            if positions.contains(where: { $0.isCryptoAsset }) {
                Button {
                    repairCryptoValues()
                } label: {
                    Image(systemName: "wrench.adjustable")
                }
                .localizedHelp("Réparer les valeurs crypto")
            }
            PaneToggleButton(label: "Modifier le compte", systemImage: "pencil", isOn: $showAccountEditForm)
            Button(role: .destructive) {
                showDeleteAccountConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .localizedHelp("Supprimer le compte")
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showAddPositionForm = true
                } label: {
                    Label("Ajouter une position", systemImage: "plus")
                }
                if positions.contains(where: { $0.isCryptoAsset }) {
                    Button {
                        repairCryptoValues()
                    } label: {
                        Label("Réparer les valeurs crypto", systemImage: "wrench.adjustable")
                    }
                }
                Divider()
                Button {
                    showAccountEditForm = true
                } label: {
                    Label("Modifier le compte", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteAccountConfirm = true
                } label: {
                    Label("Supprimer le compte", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .tint(AppTheme.Colors.accent)
            }
        }
        #endif
    }

    // MARK: - Cards

    /// Shown only when at least one position has no fetchable price history: the
    /// chart is then incomplete, since those positions contribute nothing (no
    /// price to multiply their quantity by), so the aggregated value is
    /// truncated. A discreet tappable line → targeted sync of the positions
    /// without history (and only those).
    private var missingHistoryDiagnosticCard: some View {
        Button {
            Task { await syncMissingHistoryPositions() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.warning)
                    .font(.system(size: 13))
                Text("\(positionsWithoutHistory.count) position(s) sans historique de cours")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSyncingAll {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Synchroniser")
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
        }
        .buttonStyle(.plain)
        .disabled(isSyncingAll)
    }

    /// Purges price history wrongly scraped from Yahoo for crypto tickers + resets
    /// the crypto positions' current_value to 0. The user then reruns the
    /// Binance/wallet LiveSync to get the real CoinGecko values.
    private func repairCryptoValues() {
        let result = InvestmentRepository().purgeCorruptedCryptoData()
        syncAllStatus = LocalizedStringResource("Crypto réparé : \(result.positionsReset) position(s) reset, \(result.historyRowsDeleted) cours Yahoo purgés. Relance ta sync Binance/wallet.")
        viewModel.load()
        refresh()
    }

    /// Variant of `syncAllPositions` that syncs ONLY the positions without
    /// history — used from the diagnostic line. Routes automatically to CoinGecko
    /// or Yahoo via InvestmentAutoSyncService (no load() per position — a single
    /// final refresh).
    private func syncMissingHistoryPositions() async {
        let toSync = positionsWithoutHistory
        guard !toSync.isEmpty, !isSyncingAll else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        for position in toSync {
            let identifier = position.bestSyncIdentifier
            guard !identifier.isEmpty else { continue }
            let outcome = await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier)
            InvestmentAutoSyncService.shared.recordOutcome(identifier: identifier, outcome: outcome)
        }
        refresh()
        NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
    }

    private var heroAndChartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            InvestmentHeroCard(
                title: valuationIsEstimated
                    ? "\(account.name) · valeur estimée"
                    : "\(account.name) · \(account.accountType)",
                currentValue: displayedValuation,
                // When falling back to the estimate, the variation is cancelled so as not to
                // show a misleading -100%.
                previousValue: valuationIsEstimated ? displayedValuation : evolution.first?.value,
                currency: account.currency,
                rangeLabel: variationRangeLabel(localTimeRange),
                // Variation basis = POSITIONS ONLY (no cash) AND restricted to those actually
                // valued in `evolution` (positionsWithoutHistory excluded) — otherwise the
                // perf % is artificially inflated, by cash added to currentValue but absent
                // from evolution.first?.value, and by any position without history over the
                // range (same rule as the global hero, see `portfolioVariationBasisValue`).
                variationBasisValue: valuationIsEstimated
                    ? displayedValuation
                    : account.currentValue - positionsWithoutHistory.reduce(0) { $0 + $1.currentValue }
            )

            if valuationIsEstimated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("Cours des positions non synchronisés — la valeur correspond au coût total investi. Synchronise chaque position pour voir le P&L réel.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Edge-to-edge chart, chips BELOW the chart (Apple Stocks pattern).
            // NO .clipped() — it would cut the X-axis labels (see EvolutionChart)
            EvolutionChart(points: evolution, height: 190, timeRange: localTimeRange,
                           currency: account.currency)
                .padding(.top, AppTheme.Spacing.xs)

            if let oneDayUnavailableNote {
                Text(oneDayUnavailableNote)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TimeRangeChips(
                selection: $localTimeRange,
                ranges: InvestmentTimeRange.availableRanges(since: account.openedAt)
            )

            if !positions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: syncProblemCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(syncProblemCount > 0 ? AppTheme.Colors.warning : AppTheme.Colors.success)
                    syncSummaryLabel
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

    /// Sync status of each position of the account — reads `outcomesByIdentifier`
    /// (filled by EVERY sync: global pass, this account's "Sync all", a position
    /// sheet's pull-to-refresh) rather than tracking specific to this screen.
    private var syncPositionStatuses: [SyncPositionStatus] {
        let outcomes = InvestmentAutoSyncService.shared.outcomesByIdentifier
        return positions.map { position in
            let key = position.bestSyncIdentifier.uppercased()
            return SyncPositionStatus(
                id: position.id,
                name: position.assetName.isEmpty ? position.ticker : position.assetName,
                outcome: outcomes[key]
            )
        }
    }

    private var syncProblemCount: Int {
        syncPositionStatuses.filter(\.isProblem).count
    }

    private var syncSummaryLabel: Text {
        syncProblemCount == 0
            ? Text("Cours à jour")
            : Text("\(syncProblemCount) position(s) non synchronisée(s)")
    }

    /// Inline KPIs (invested · performance) + cash if > 0. Clean, flat style.
    private var kpisCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if valuationIsEstimated {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Performance disponible après synchronisation des cours")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Investi")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(invested, format: .currency(code: account.currency))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("·")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Plus-value")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(performance, format: .currency(code: account.currency))
                        .foregroundStyle(performanceColor)
                }
                .font(AppTheme.Typography.bodySmall)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            // Cash: visible only if > 0, so accounts without cash stay uncluttered.
            if account.cashBalance > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "eurosign.circle.fill")
                        .foregroundStyle(AppTheme.Colors.accentSecondary)
                        .font(.system(size: 14))
                    Text("Trésorerie disponible")
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    Text(account.cashBalance, format: .currency(code: account.currency))
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SectionHeader(title: "Répartition interne")
            AllocationDonutChart(slices: allocation, currency: account.currency, size: 150)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SectionHeader(title: "Positions (\(positions.count))")
                .padding(.horizontal, AppTheme.Spacing.sm)
            // NO `List` here, on EITHER platform.
            //
            // macOS: neither a nested List, nor a clicked NavigationLink, nor a depth-2
            // PUSH is safe (see the `panePosition` doc).
            //
            // iOS: a `.scrollDisabled(true)` `List` nested in the account's `ScrollView`
            // needs an EXPLICIT height — and every attempt to derive it from the real
            // content fails for the same structural reason: `List` VIRTUALIZES its rows
            // (it only renders those near the viewport). A fixed per-row estimate
            // ("~66pt") breaks as soon as a row is taller than expected (a long name on
            // 2 lines). Measuring each row's REAL height and summing makes it worse:
            // shrinking the List's height shrinks its viewport, which shrinks the
            // number of rows RENDERED (hence measured), which shrinks the computed
            // height further — a feedback loop that converges on just a handful of rows.
            //
            // A plain `VStack` needs NO guessed height: SwiftUI sizes it to its real
            // content, with no virtualization, hence no such trap. The accepted cost:
            // the native swipe (`.swipeActions`, which only exists in a real `List`) is
            // gone on iOS — the same actions stay reachable by long press
            // (`.contextMenu`, wired by `.rowActions` on both platforms).
            VStack(spacing: 0) {
                ForEach(positions) { position in
                    #if os(macOS)
                    Button {
                        panePosition = position
                    } label: {
                        positionRow(position)
                            .padding(.vertical, 6)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowActions(
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingPosition = position }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { positionToDelete = position }]
                    )
                    #else
                    NavigationLink {
                        InvestmentPositionDetailView(
                            viewModel: viewModel,
                            account: account,
                            position: position
                        )
                    } label: {
                        positionRow(position)
                            .padding(.vertical, 6)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowActions(
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingPosition = position }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { positionToDelete = position }]
                    )
                    #endif
                    if position.id != positions.last?.id {
                        Divider()
                            .overlay(AppTheme.Colors.textSecondary.opacity(0.12))
                            .padding(.leading, AppTheme.Spacing.sm)
                    }
                }
            }
            // A single card, same visual language as .macGroupedRow elsewhere in the
            // app: one rounded background wrapping every row.
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            #if os(macOS)
            .adaptivePane(item: $panePosition) { pushed in
                PositionPane(viewModel: viewModel, account: account, position: pushed)
            }
            #endif
        }
    }

    private var emptyPositionsCard: some View {
        AppCard {
            EmptyStateView(
                icon: "tray",
                title: "Aucune position",
                message: "Ajoute une position via le bouton + en haut à droite."
            )
        }
    }

    // MARK: - Position row

    private func positionRow(_ position: InvestmentPosition) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Dot colored by asset type (consistent with the donut)
            Circle()
                .fill(assetTypeColor(position.assetType))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(position.assetName.isEmpty ? position.ticker : position.assetName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(position.ticker)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("·")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("\(position.quantity, specifier: "%.4f") @ \(position.averageBuyPrice, format: .currency(code: account.currency))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(position.currentValue, format: .currency(code: account.currency))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                pnlBadge(position)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func pnlBadge(_ position: InvestmentPosition) -> some View {
        let pct = position.investedAmount > 0
            ? (position.pnl / position.investedAmount) * 100
            : 0
        let isPositive = position.pnl >= 0
        let color = isPositive ? AppTheme.Colors.success : AppTheme.Colors.danger
        return HStack(spacing: 3) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%@%.2f %%", isPositive ? "+" : "", pct))
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Skeleton

    @ViewBuilder private var accountDetailSkeleton: some View {
        // Hero + chart + chips (flat, chips below the chart)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SkeletonHero()
            SkeletonLine(width: 200, height: 13)
            SkeletonChart(height: 190)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { _ in
                    SkeletonBlock(width: 40, height: 28, cornerRadius: 14)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        // Flat allocation
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SkeletonLine(width: 130, height: 15)
            SkeletonDonut(size: 150)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        // Flat positions
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SkeletonLine(width: 130, height: 15)
            ForEach(0..<4, id: \.self) { _ in
                SkeletonPositionRow()
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    // MARK: - Helpers

    private func refresh() {
        positions = viewModel.fetchPositions(accountId: account.id)
        recomputeEvolution()
    }

    /// Syncs every price of the account's positions in one pass.
    /// Two-step pipeline:
    ///   1. LiveSync (Binance/EVM/BTC/SOL) if links are attached — refreshes the
    ///      values and inserts crypto trades (via CoinGecko internally)
    ///   2. InvestmentAutoSyncService.syncHistory for each position → automatic
    ///      CoinGecko (cryptos) vs Yahoo (securities) routing, typed outcomes, NO
    ///      load() per position — a single final refresh.
    private func syncAllPositions() async {
        guard !isSyncingAll, !positions.isEmpty else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        // 1. LiveSync: refresh values + trades from external providers
        let linkedLinks = LiveSyncRepository.shared.fetchLinks()
            .filter { $0.accountId == account.id && $0.enabled }
        var liveSyncOK = 0
        var liveSyncErr = 0
        for link in linkedLinks {
            if await LiveSyncRegistry.shared.syncLink(link) == nil {
                liveSyncOK += 1
            } else {
                liveSyncErr += 1
            }
        }

        // 2. History sync for EACH position (automatic CoinGecko vs Yahoo routing)
        var success = 0
        var upToDate = 0
        var rateLimited = 0
        var failed = 0
        for position in positions {
            let identifier = position.bestSyncIdentifier
            guard !identifier.isEmpty else { failed += 1; continue }
            let outcome = await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier)
            InvestmentAutoSyncService.shared.recordOutcome(identifier: identifier, outcome: outcome)
            switch outcome {
            case .success:     success += 1
            case .upToDate:    upToDate += 1
            case .rateLimited: rateLimited += 1
            case .noData, .networkError, .invalidIdentifier: failed += 1
            }
        }

        var parts: [LocalizedStringResource] = []
        if success > 0      { parts.append(LocalizedStringResource("\(success) cours sync")) }
        if upToDate > 0     { parts.append(LocalizedStringResource("\(upToDate) à jour")) }
        if liveSyncOK > 0   { parts.append(LocalizedStringResource("\(liveSyncOK) LiveSync OK")) }
        if liveSyncErr > 0  { parts.append(LocalizedStringResource("\(liveSyncErr) LiveSync KO")) }
        if rateLimited > 0  { parts.append(LocalizedStringResource("\(rateLimited) limité\(rateLimited > 1 ? "s" : "") (réessaie plus tard)")) }
        if failed > 0       { parts.append(LocalizedStringResource("\(failed) sans cours")) }
        // `LocalizedStringResource` n'a pas de `.joined()` — repli manuel par
        // imbrication (cf. `AppLocalization`/CLAUDE.md §5).
        syncAllStatus = parts.isEmpty
            ? LocalizedStringResource("Rien à synchroniser")
            : parts.dropFirst().reduce(parts[0]) { acc, part in LocalizedStringResource("\(acc) · \(part)") }
        // Local refresh + global notification (→ bumps dataRefreshToken in
        // NemorisApp → dashboard reload).
        refresh()
        NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
    }

    private func recomputeEvolution() {
        let result = viewModel.computeAccountEvolutionWithDiagnostic(
            accountId: account.id, range: localTimeRange
        )
        evolution = result.points
        positionsWithoutHistory = result.positionsWithoutHistory
        oneDayUnavailableNote = result.oneDayUnavailableNote
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

    /// Stable color per asset type — aligned with the donut's palette.
    private func assetTypeColor(_ raw: String) -> Color {
        switch InvestmentAssetType(looselyMatching: raw) {
        case .stock:  return AppTheme.Colors.accent
        case .etf:    return AppTheme.Colors.accentSecondary
        case .bond:   return AppTheme.Colors.warning
        case .crypto: return AppTheme.Colors.success
        case .fund:   return Color(hex: "6B9D85")
        case .none:   return AppTheme.Colors.textSecondary
        }
    }
}

#if os(macOS)
/// Side-pane content for a position sheet (AdaptivePane contract: the
/// presented view keeps its NavigationStack + navigationTitle + toolbar).
/// The "Close" button goes through `\.paneDismiss`, injected by the wrapper.
/// `InvestmentPositionDetailView` declares its own pane chrome (`.paneChrome`:
/// Close / Delete / Edit) — this wrapper only forwards the parameters. A
/// `NavigationStack` + `.toolbar` here would lift a second set of buttons
/// into the module's bar.
private struct PositionPane: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    let position: InvestmentPosition

    var body: some View {
        InvestmentPositionDetailView(viewModel: viewModel, account: account, position: position)
    }
}
#endif
