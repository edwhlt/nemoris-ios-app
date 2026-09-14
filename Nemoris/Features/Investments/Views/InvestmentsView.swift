import SwiftUI
import UniformTypeIdentifiers
import Charts
import TipKit

/// Identifiable wrapper to present the smart import pre-filled via
/// `.sheet(item:)` (a document dropped by a Siri shortcut).
struct PreloadedInvestmentImport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct InvestmentsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = InvestmentsViewModel()
    private let overviewTip = InvestmentsOverviewTip()

    // Separate add/edit sheets, so `editingAccount` and the add flag can never
    // race (which could make "edit" open the add form).
    // - `showAddAccountForm` (Bool): new entry
    // - `editingAccount` (optional Identifiable): editing via `.sheet(item:)`
    @State private var showAddAccountForm = false
    @State private var editingAccount: InvestmentAccount?
    @State private var accountToDelete: InvestmentAccount?

    #if os(macOS)
    /// macOS: the selected account replaces the dashboard in the module column
    /// (state-driven, see `dashboardContent`) — no push, which is unsafe on macOS
    /// (see `InvestmentAccountDetailView.positionsCard`).
    @State private var pushedAccount: InvestmentAccount?
    /// To close the pane when returning to the dashboard (see `onBack`).
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif

    @State private var showAddPositionForm = false
    @State private var editingPosition: InvestmentPosition?

    /// Entry point of the LiveSync catalog (Binance/EVM/BTC/SOL) — an option of
    /// the Investments module, not a global setting (see the header of
    /// `LiveSyncSettingsView.swift`). No account is supplied here
    /// (`accountId: nil`): `LiveSyncLinkFormView` creates a dedicated one on the
    /// fly. To link a source to an EXISTING account, see
    /// `InvestmentAccountFormView.linkedSourcesSection`.
    @State private var showLiveSyncCatalog = false
    /// Investment coach — presented as a pane, like the module's other tools.
    @State private var showCoach = false

    // Import is a dedicated sheet.
    @State private var showImportSheet = false
    @State private var showFilePicker = false
    @State private var showCSVAccountPicker = false

    /// Smart import pre-filled by a Siri shortcut.
    @State private var preloadedImport: PreloadedInvestmentImport?

    @State private var csvRawContent = ""
    @State private var csvMapping = InvestmentCSVMapping(
        isin: "", quantity: "", averageBuyPrice: "", purchaseDate: ""
    )
    @State private var csvProfile: InvestmentCSVSourceProfile = .generic
    @State private var datePolicy: Int = 1
    @State private var importResultMessage: String?

    /// Skeleton until the 1st `viewModel.load()` has finished.
    @State private var hasLoaded = false
    /// "?" detail of the sync status — lists ALL positions, across all accounts.
    @State private var showSyncDetail = false

    var isEmbedded: Bool = false

    var body: some View {
        Group {
            if isEmbedded { dashboardContent } else { NavigationStack { dashboardContent } }
        }
    }

    @ViewBuilder private var dashboardContent: some View {
        #if os(macOS)
        // macOS: an account's detail replaces the dashboard IN THE COLUMN (internal
        // module navigation, state-driven). Neither a push — which desynchronizes the
        // display when switching modules and triggers the AutoLayout recursion at
        // depth 2 — nor the pane: an account is charts, it needs the full width. The
        // inspector stays reserved for sheets (positions) and forms.
        if let account = pushedAccount {
            InvestmentAccountDetailView(
                viewModel: viewModel,
                account: account,
                // The pane is closed EXPLICITLY here (user action), not via an
                // `onDisappear` at the presentation site: mutating the pane's state while a
                // view is being torn down causes a SwiftUI render-engine reentrancy (crash).
                // Without this, returning to the dashboard would leave a position's sheet
                // open beside it — with a "Close" button that no longer responds, since the
                // binding it drives no longer exists.
                onBack: {
                    paneCenter?.dismissCurrent()
                    pushedAccount = nil
                }
            )
        } else {
            globalDashboard
        }
        #else
        globalDashboard
        #endif
    }

    @ViewBuilder private var globalDashboard: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            // A single home screen = the global dashboard.
            // Accounts/positions are reached by drill-down.
            // Import is reachable through the toolbar menu.
            dashboardTab
        }
        .localizedNavigationTitle("Investissements")
        .toolbar {
            #if os(macOS)
            // macOS: the 2 actions of the "⋯" menu become icon-only buttons + native
            // tooltips, grouped in ONE pill via `ToolbarItemGroup` (native grouping —
            // `ControlGroup` rendered isolated buttons).
            ToolbarItemGroup(placement: .topBarTrailing) {
                PaneToggleButton(label: "Coach investissement", systemImage: "lightbulb", isOn: $showCoach)
                PaneToggleButton(label: "Ajouter un compte", systemImage: "building.columns", isOn: $showAddAccountForm)
                // SINGLE import entry: the smart path already handles PDF / screenshot /
                // image / CSV (see the iOS branch).
                // It redirects to the import TOOL rather than opening it in the side pane:
                // import is a full journey (file choice, mapping, review), not a detail
                // sheet to show beside the module.
                Button {
                    appState.openImportTool(destination: .investments)
                } label: {
                    Label("Importer un relevé…", systemImage: "square.and.arrow.down")
                }
                .localizedHelp("Importer un relevé…")
                // An option of the module, not a global setting. `ToolbarPaywallGate`
                // applies the Pro lock.
                ToolbarPaywallGate(feature: .investmentsLiveSync) {
                    PaneToggleButton(label: "Lier un exchange / wallet", systemImage: "arrow.triangle.2.circlepath", isOn: $showLiveSyncCatalog)
                }
                .localizedHelp("Lier un exchange / wallet")
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCoach = true
                    } label: {
                        Label("Coach investissement", systemImage: "lightbulb")
                    }
                    Button {
                        showAddAccountForm = true
                    } label: {
                        Label("Ajouter un compte", systemImage: "building.columns")
                    }
                    // SINGLE import entry: the smart path already handles PDF / screenshot /
                    // image / CSV. If Apple Intelligence isn't available, it offers the fallback
                    // to the deterministic CSV import (column mapping) itself — offline-first
                    // stays guaranteed without AI.
                    Button {
                        appState.openImportTool(destination: .investments)
                    } label: {
                        Label("Importer un relevé…", systemImage: "square.and.arrow.down")
                    }
                    // The Pro lock applies to the presented CONTENT (`.paywallOverlay` on the
                    // pane below), not to this menu entry — same doctrine as the rest of this
                    // Menu, which is never gated itself.
                    Button {
                        showLiveSyncCatalog = true
                    } label: {
                        Label("Lier un exchange / wallet", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tint(AppTheme.Colors.accent)
                }
            }
            #endif
        }
        // Add: sheet triggered by a Bool, always passes nil → creation mode.
        .adaptivePane(isPresented: $showAddAccountForm) {
            InvestmentAccountFormView(account: nil) { account, isNew in
                viewModel.saveAccount(account, isNew: isNew)
            }
        }
        // Edit: item-driven sheet, a fresh View for each account → no stale state.
        .adaptivePane(item: $editingAccount) { account in
            InvestmentAccountFormView(account: account) { updated, isNew in
                viewModel.saveAccount(updated, isNew: isNew)
            }
        }
        // LiveSync catalog: accountId nil, a dedicated account is created by
        // `LiveSyncLinkFormView.save()`. `onDismiss` reloads the account list so the
        // new account (created even if the 1st sync fails) appears immediately.
        .adaptivePane(isPresented: $showCoach) {
            CoachView(domain: .investments)
        }
        .adaptivePane(isPresented: $showLiveSyncCatalog, onDismiss: { viewModel.load() }) {
            NavigationStack {
                LiveSyncProviderPickerView()
            }
            .paywallOverlay(for: .investmentsLiveSync)
        }
        .confirmationDialog(
            "Supprimer ce compte ?",
            isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountToDelete
        ) { account in
            Button("Supprimer \(account.name)", role: .destructive) {
                viewModel.deleteAccount(id: account.id)
                accountToDelete = nil
            }
            Button("Annuler", role: .cancel) { accountToDelete = nil }
        } message: { _ in
            Text("Toutes les positions et les ordres rattachés seront supprimés en cascade. Cette action est irréversible.")
        }
        .adaptivePane(isPresented: $showAddPositionForm) {
            if let accountId = viewModel.selectedAccountId {
                InvestmentPositionFormView(accountId: accountId, position: nil) { position, isNew in
                    viewModel.savePosition(position, isNew: isNew)
                }
            }
        }
        .adaptivePane(item: $editingPosition) { position in
            InvestmentPositionFormView(accountId: position.accountId, position: position) { updated, isNew in
                viewModel.savePosition(updated, isNew: isNew)
            }
        }
        .adaptivePane(isPresented: $showSyncDetail) {
            InvestmentSyncDetailSheet(content: .list(summary: nil, positions: allSyncPositionStatuses))
        }
        .adaptivePane(isPresented: $showImportSheet) {
            importTab
                .paneChrome("Importer un CSV", cancelLabel: "Fermer", onCancel: { showImportSheet = false })
        }
        // Smart import opened by a Siri shortcut (pre-filled document). Also
        // consumes the pending URL if the view was just mounted by
        // navigateToTab(.investments) before .onChange got attached.
        .adaptivePane(item: $preloadedImport) { item in
            InvestmentPDFImportView(preloadedFileURLs: item.urls,
                                    onFallbackToCSV: { showImportSheet = true })
        }
        .onChange(of: appState.pendingInvestmentImportURLs) { _, urls in
            consumePendingInvestmentImport(urls)
        }
        .onAppear {
            consumePendingInvestmentImport(appState.pendingInvestmentImportURLs)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importResultMessage = "Impossible de lire le fichier CSV"
                return
            }
            // SNIFF before decoding. A `utf8 ?? windowsCP1252 ?? isoLatin1` chain can't
            // fail: `isoLatin1` accepts any byte sequence, so a PDF or a capture dropped
            // here would become hundreds of thousands of binary characters presented as
            // a CSV — see `ImportFormatSniffer`.
            let kind = ImportFormatSniffer.detect(data: data, fileExtension: url.pathExtension)
            guard kind == .text, let rawContent = ImportFormatSniffer.decodeText(data) else {
                importResultMessage = kind == .unknown
                    ? "Format de fichier non reconnu — attendu : un CSV."
                    : "Ce fichier n'est pas un CSV. Utilise « Importer un relevé » pour un PDF ou une capture."
                return
            }
            csvRawContent = rawContent
            viewModel.loadCSV(content: rawContent)
            hydrateDefaultMappingIfNeeded()
        }
        // viewModel.load() is called in the dashboardTab's .task to drive the skeleton.
    }

    // MARK: - Sync status

    @MainActor
    private static let syncRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.locale
        formatter.unitsStyle = .short
        return formatter
    }()

    @ViewBuilder
    private var syncStatusLine: some View {
        let service = InvestmentAutoSyncService.shared
        HStack(spacing: AppTheme.Spacing.xs) {
            if service.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                if let progress = service.progress {
                    Text("Synchronisation… (\(progress.done)/\(progress.total))")
                } else {
                    Text("Synchronisation…")
                }
            } else if let last = service.lastSyncAt {
                Text("Actualisé \(Self.syncRelativeFormatter.localizedString(for: last, relativeTo: Date()))")
                // Possible errors of the last pass, on one discreet line.
                // `lastSyncHadIssues` (not a `.contains("erreur")` on the resolved text —
                // that breaks as soon as the app isn't in French).
                if let summary = service.lastSummary, service.lastSyncHadIssues {
                    (Text("· ") + Text(summary))
                        .lineLimit(1)
                }
            }
            if !viewModel.allPositions.isEmpty {
                Spacer(minLength: 4)
                SyncInfoButton(isPresented: $showSyncDetail)
            }
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.Colors.textSecondary)
    }

    /// Sync status of ALL positions, across all accounts — same source
    /// (`outcomesByIdentifier`) as the account/position levels, fed by any sync
    /// trigger (global pass, an account's "Sync all", a position's
    /// pull-to-refresh).
    private var allSyncPositionStatuses: [SyncPositionStatus] {
        let outcomes = InvestmentAutoSyncService.shared.outcomesByIdentifier
        return viewModel.allPositions.map { position in
            let key = position.bestSyncIdentifier.uppercased()
            return SyncPositionStatus(
                id: position.id,
                name: position.assetName.isEmpty ? position.ticker : position.assetName,
                outcome: outcomes[key]
            )
        }
    }

    /// Compact KPI line "Invested X · Gain Y".
    @ViewBuilder
    private func kpiInlineLine(invested: Double, performance: Double) -> some View {
        HStack(spacing: 6) {
            Text("Investi")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(invested, format: .currency(code: "EUR"))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("·")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text("Plus-value")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(performance, format: .currency(code: "EUR"))
                .foregroundStyle(performance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
        }
        .font(AppTheme.Typography.bodySmall)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: - Dashboard Tab ( — refonte style Finary, DA Nemoris)

    private var dashboardTab: some View {
        let stats = viewModel.dashboard
        return ScrollView {
            if !hasLoaded {
                investmentsSkeleton
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
            VStack(spacing: AppTheme.Spacing.md) {

                TipView(overviewTip, arrowEdge: .none)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.sm)

                // ── Hero + chart + chips (clean Apple Stocks style) ──────
                // Everything lives directly on the background: large figure, edge-to-edge
                // chart, chips BELOW the chart (Stocks pattern).
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    InvestmentHeroCard(
                        title: "Valorisation totale",
                        currentValue: viewModel.portfolioCurrentValue
                            + (appState.investmentsIncludeCashInTotal ? viewModel.portfolioTotalCash : 0),
                        previousValue: viewModel.portfolioStartValue,
                        currency: "EUR",
                        rangeLabel: variationRangeLabel(viewModel.selectedTimeRange),
                        // variation basis = PRICED positions only, the same subset as
                        // portfolioStartValue (see portfolioVariationBasisValue)
                        variationBasisValue: viewModel.portfolioVariationBasisValue
                    )

                    // Discreet inline KPI.
                    kpiInlineLine(invested: stats.totalInvested, performance: stats.performance)
                        .padding(.top, 2)

                    // Chart directly on the background. NO .clipped() here: it would cut the
                    // X-axis labels, which sit below the plot area.
                    EvolutionChart(
                        points: viewModel.portfolioEvolution,
                        height: 210,
                        timeRange: viewModel.selectedTimeRange
                    )
                    .padding(.top, AppTheme.Spacing.xs)

                    // 1D without any continuous quote: explain it, rather than let an empty
                    // chart look like a failure.
                    if let note = viewModel.oneDayUnavailableNote {
                        Text(note)
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, AppTheme.Spacing.xs)
                    }

                    TimeRangeChips(
                        selection: Binding(
                            get: { viewModel.selectedTimeRange },
                            set: { newValue in
                                viewModel.selectedTimeRange = newValue
                                viewModel.recomputePortfolioEvolution()
                                // 1D range → needs the INTRADAY series (30 min).
                                // On-demand fetch (skipped if fresher than 25 min), then recompute once
                                // the points have arrived.
                                if newValue == .oneDay {
                                    Task {
                                        await InvestmentAutoSyncService.shared.syncIntradayIfNeeded(
                                            identifiers: viewModel.allPositions.map(\.bestSyncIdentifier)
                                        )
                                        viewModel.recomputePortfolioEvolution()
                                    }
                                }
                            }
                        ),
                        // Oldest account as the reference: no point showing 10Y if the oldest
                        // account is 6 months old.
                        ranges: InvestmentTimeRange.availableRanges(
                            since: viewModel.accounts.map(\.openedAt).min() ?? Date()
                        )
                    )

                    // Auto-sync status (spinner + progress during, "Updated X ago" after).
                    syncStatusLine
                        .padding(.top, 2)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)

                // ── Allocation (flat donut, no card) ─────────────────────────
                allocationSection

                // ── Liste comptes (NavigationLink vers AccountDetailView) ─
                if !viewModel.accounts.isEmpty {
                    accountsListSection()
                } else {
                    emptyAccountsCard
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            }
        }
        .background(AppTheme.Colors.background)
        // `.task(id:)` re-fires whenever dataRefreshToken changes. Lets child views
        // (PositionDetail, AccountDetail) mark the global view dirty after saving /
        // deleting an order via `appState.dataRefreshToken = UUID()`.
        .task(id: appState.dataRefreshToken) {
            // 1-frame guard: lets the skeleton show before the SQLite query.
            await Task.yield()
            viewModel.load()
            // Recompute if there are accounts but no evolution loaded yet
            if viewModel.portfolioEvolution.isEmpty && !viewModel.accounts.isEmpty {
                viewModel.recomputePortfolioEvolution()
            }
            hasLoaded = true
        }
        // Auto-sync trigger on opening the module.
        // A task SEPARATE from the .task(id: dataRefreshToken) above: the end of the
        // pass bumps the token, which would cancel/restart that task and re-trigger
        // the sync in a loop.
        .task {
            await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .investmentsOpened)
        }
        .refreshable {
            // Pull-to-refresh: forces a full pass (bypasses the 4 h interval, not the
            // isSyncing lock). The main reload arrives via .nemorisInvestmentsDidSync →
            // token bump; reloadAll() as a safety net if the pass did nothing (toggle
            // off / sync already running).
            await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .pullToRefresh)
            reloadAll()
        }
    }

    /// Central helper: reloads positions + evolution. Used by pull-to-refresh.
    private func reloadAll() {
        viewModel.load()
        viewModel.recomputePortfolioEvolution()
    }

    /// Presents the pre-filled smart import and releases the pending URL
    /// (one-shot). No-op if nil or if a sheet is already up.
    private func consumePendingInvestmentImport(_ urls: [URL]) {
        guard !urls.isEmpty, preloadedImport == nil else { return }
        appState.pendingInvestmentImportURLs = []
        preloadedImport = PreloadedInvestmentImport(urls: urls)
    }

    // MARK: - Skeleton

    @ViewBuilder private var investmentsSkeleton: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            // Hero + KPI line + chart + chips (flat, Apple Stocks style)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonHero()
                SkeletonLine(width: 200, height: 13)
                SkeletonChart(height: 210)
                // TimeRange chips BELOW the chart, full width
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { _ in
                        SkeletonBlock(width: 40, height: 28, cornerRadius: 14)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)

            // Flat allocation donut
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    SkeletonLine(width: 110, height: 15)
                    Spacer()
                    SkeletonBlock(width: 150, height: 26, cornerRadius: 13)
                }
                SkeletonDonut(size: 150)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)

            // Flat account list
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonLine(width: 130, height: 15)
                SkeletonAccountRow()
                SkeletonAccountRow()
                SkeletonAccountRow()
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
        }
    }

    /// Flat allocation donut (no card) + "By type"/"By account" toggle.
    @ViewBuilder
    private var allocationSection: some View {
        let slices = viewModel.allocationGroupByAccount
            ? viewModel.allocationByAccount
            : viewModel.allocationByAssetType
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    SectionHeader(title: "Répartition")
                    Spacer()
                    // Toggle compact type ↔ compte
                    Picker("", selection: Binding(
                        get: { viewModel.allocationGroupByAccount },
                        set: { viewModel.allocationGroupByAccount = $0 }
                    )) {
                        Text("Type").tag(false)
                        Text("Compte").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                AllocationDonutChart(slices: slices, currency: "EUR", size: 150)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.top, AppTheme.Spacing.sm)
        }
    }

    /// Flat account section (no card), drilling down to AccountDetailView.
    /// Apple Stocks style — airy rows, 1M sparkline in the middle, value in
    /// right-aligned figures. Actions via RowActions (iOS swipe / macOS right-click).
    @ViewBuilder
    private func accountsListSection() -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SectionHeader(title: "Comptes (\(viewModel.accounts.count))")
                .padding(.horizontal, AppTheme.Spacing.sm)
            // NO `List` on EITHER platform — see the matching detailed comment in
            // `InvestmentAccountDetailView.positionsCard`: a `.scrollDisabled(true)`
            // `List` nested in a `ScrollView` VIRTUALIZES its rows, so any height guessed
            // OR measured from its own content is structurally fragile — the "measured"
            // variant even enters a feedback loop (shrinking the List renders fewer
            // rows, hence measures less, hence shrinks further). A `VStack` needs no
            // guessed height: SwiftUI sizes it to its real content. The accepted cost on
            // iOS: the native swipe is gone, the same actions stay reachable by long
            // press (`.contextMenu`, wired by `.rowActions` on both platforms).
            VStack(spacing: 0) {
                ForEach(viewModel.accounts) { account in
                    #if os(macOS)
                    // macOS: selecting an account swaps the module's content for its detail
                    // (see `dashboardContent`) — no push.
                    Button {
                        pushedAccount = account
                    } label: {
                        accountRow(account)
                            .padding(.vertical, 6)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowActions(
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingAccount = account }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { accountToDelete = account }]
                    )
                    #else
                    NavigationLink {
                        InvestmentAccountDetailView(viewModel: viewModel, account: account)
                    } label: {
                        accountRow(account)
                            .padding(.vertical, 6)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowActions(
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingAccount = account }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { accountToDelete = account }]
                    )
                    #endif
                    if account.id != viewModel.accounts.last?.id {
                        Divider()
                            .overlay(AppTheme.Colors.textSecondary.opacity(0.12))
                            .padding(.leading, AppTheme.Spacing.sm)
                    }
                }
            }
            // A single card, same visual language as .macGroupedRow elsewhere in the app
            // — one rounded background wrapping every row, separated by plain Dividers.
            // No first/last per row: a single group, no section.
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            // No presentation here (macOS): `pushedAccount` swaps the module's CONTENT
            // (see `dashboardContent`) — the account shows at full width, not in the pane.
        }
    }

    /// An account's row in the global dashboard list (Apple Stocks style).
    /// Shows: name · broker/type · 1M sparkline · current value, right-aligned.
    private func accountRow(_ account: InvestmentAccount) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text("\(account.broker.isEmpty ? account.accountType : account.broker) · \(account.accountType)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.sm)

            // 1-month sparkline — hidden when there isn't enough history.
            if let spark = viewModel.accountSparklines[account.id] {
                InvestmentSparkline(points: spark, height: 28, width: 56)
            }

            VStack(alignment: .trailing, spacing: 2) {
                // Total = positions + cash (consistent with the account hero)
                Text(account.totalValuation, format: .currency(code: account.currency))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                // Cash as a discreet sub-line if > 0 — the user sees that part of this
                // account's capital is held as cash
                if account.cashBalance > 0 {
                    Text("dont \(account.cashBalance, format: .currency(code: account.currency)) cash")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Empty state when no account exists yet — encourages creating one.
    private var emptyAccountsCard: some View {
        AppCard {
            EmptyStateView(
                icon: "building.columns",
                title: "Aucun compte",
                message: "Crée un compte PEA, CTO, crypto ou autre via le menu en haut à droite."
            )
        }
    }

    /// Label shown next to the variation % in the hero ("over 1 month", etc.)
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

    // MARK: - Import Tab

    private var importTab: some View {
        List {
            Section("Fichier") {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choisir un CSV", systemImage: "doc.badge.plus")
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                if !viewModel.csvHeaders.isEmpty {
                    LabeledContent("Colonnes", value: "\(viewModel.csvHeaders.count)")
                    LabeledContent("Lignes", value: "\(viewModel.csvRows.count)")
                }
            }

            if !viewModel.csvHeaders.isEmpty {
                Section("Mapping colonnes") {
                    Button {
                        showCSVAccountPicker = true
                    } label: {
                        HStack {
                            Text("Compte cible").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if let a = viewModel.accounts.first(where: { $0.id == viewModel.selectedAccountId }) {
                                Text("\(a.name) (\(a.broker))").foregroundStyle(AppTheme.Colors.textPrimary)
                            } else {
                                Text("Sélectionner…").foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                    Picker("Source CSV", selection: $csvProfile) {
                        ForEach(InvestmentCSVSourceProfile.allCases, id: \.self) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    mappingPicker(title: "ISIN (obligatoire)", keyPath: \.isin)
                    mappingPicker(title: "Quantité", keyPath: \.quantity)
                    mappingPicker(title: "Prix d'achat", keyPath: \.averageBuyPrice)
                    mappingPicker(title: "Date d'achat (optionnel)", keyPath: \.purchaseDate, allowEmpty: true)
                    Picker("Si date absente", selection: $datePolicy) {
                        Text("Bloquer l'import").tag(0)
                        Text("Utiliser aujourd'hui").tag(1)
                        Text("Date d'ouverture du compte").tag(2)
                    }

                    Button("Prévisualiser") {
                        Task {
                            viewModel.buildCSVPreview(mapping: csvMapping, dateStrategy: resolvedDateStrategy())
                            await viewModel.enrichPreviewRowsFromISIN()
                        }
                    }
                    .disabled(csvMapping.isin.isEmpty || csvMapping.quantity.isEmpty || csvMapping.averageBuyPrice.isEmpty || viewModel.selectedAccountId == nil || viewModel.isEnrichingPreview)
                    .tint(AppTheme.Colors.accent)
                }
            }

            if !viewModel.csvErrors.isEmpty {
                Section("Erreurs") {
                    ForEach(Array(viewModel.csvErrors.enumerated()), id: \.offset) { _, error in
                        Text(error).foregroundStyle(AppTheme.Colors.danger).font(.caption)
                    }
                }
            }

            if viewModel.isEnrichingPreview {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().tint(AppTheme.Colors.accent)
                        Text("Enrichissement ISIN en cours…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }

            if !viewModel.csvWarnings.isEmpty {
                Section("Avertissements ISIN") {
                    ForEach(Array(viewModel.csvWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                }
            }

            if !viewModel.previewRows.isEmpty {
                Section("Prévisualisation") {
                    ForEach(viewModel.previewRows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.assetName).font(.headline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text("\(row.assetType) · \(row.ticker)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Text("Qte: \(row.quantity, specifier: "%.4f") · Valeur: \(row.currentValue, specifier: "%.2f")")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                }

                Section {
                    Button("Importer les positions") {
                        let result = viewModel.importPreviewRows()
                        if result.failures.isEmpty {
                            importResultMessage = "\(result.insertedCount) position(s) importée(s)."
                        } else {
                            importResultMessage = "\(result.insertedCount) importée(s), \(result.failures.count) erreur(s)."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Colors.accent)
                }
            }

            if !viewModel.importFailures.isEmpty {
                Section("Erreurs d'import SQL") {
                    ForEach(viewModel.importFailures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ligne \(failure.sourceRow) : \(failure.reason)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.danger)
                            Text("ISIN: \(failure.identifier.isEmpty ? "N/A" : failure.identifier) · Qté: \(failure.quantity, specifier: "%.4f") · PRU: \(failure.averageBuyPrice, specifier: "%.4f")")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                }
            }

            if let importResultMessage {
                Section {
                    Text(importResultMessage).font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background)
        .adaptivePane(isPresented: $showCSVAccountPicker) {
            InvestmentAccountSearchSheet(accounts: viewModel.accounts, selectedId: viewModel.selectedAccountId, title: "Compte cible") { picked in
                viewModel.selectedAccountId = picked.id
            }
        }
    }

    @ViewBuilder
    private func mappingPicker(title: String, keyPath: WritableKeyPath<InvestmentCSVMapping, String>, allowEmpty: Bool = false) -> some View {
        Picker(title, selection: Binding(
            get: { csvMapping[keyPath: keyPath] },
            set: { csvMapping[keyPath: keyPath] = $0 }
        )) {
            if allowEmpty {
                Text("Non renseigné").tag("")
            }
            ForEach(viewModel.csvHeaders, id: \.self) { header in
                Text(header).tag(header)
            }
        }
    }

    private func hydrateDefaultMappingIfNeeded() {
        guard !viewModel.csvHeaders.isEmpty else { return }
        if csvMapping.isin.isEmpty { csvMapping.isin = viewModel.csvHeaders.first(where: { $0.lowercased().contains("isin") }) ?? "" }
        if csvMapping.quantity.isEmpty { csvMapping.quantity = viewModel.csvHeaders.first(where: { $0.lowercased().contains("quant") }) ?? (viewModel.csvHeaders.first ?? "") }
        if csvMapping.averageBuyPrice.isEmpty { csvMapping.averageBuyPrice = viewModel.csvHeaders.first(where: { $0.lowercased().contains("prix") || $0.lowercased().contains("avg") }) ?? (viewModel.csvHeaders.first ?? "") }
        if csvMapping.purchaseDate.isEmpty { csvMapping.purchaseDate = viewModel.csvHeaders.first(where: { $0.lowercased().contains("date") }) ?? "" }
        if csvProfile == .boursobank {
            if csvMapping.isin.isEmpty { csvMapping.isin = viewModel.csvHeaders.first(where: { $0.lowercased().contains("isin") }) ?? "" }
            if csvMapping.quantity.isEmpty { csvMapping.quantity = viewModel.csvHeaders.first(where: { $0.lowercased().contains("quant") }) ?? csvMapping.quantity }
            if csvMapping.averageBuyPrice.isEmpty { csvMapping.averageBuyPrice = viewModel.csvHeaders.first(where: { $0.lowercased().contains("prix") }) ?? csvMapping.averageBuyPrice }
            datePolicy = 2
        }
    }

    private func resolvedDateStrategy() -> InvestmentCSVDateStrategy {
        switch datePolicy {
        case 1:
            return .useToday
        case 2:
            return .useAccountOpeningDate(viewModel.selectedAccount?.openedAt ?? Date())
        default:
            return .requireDate
        }
    }
}

// MARK: - Form Views

// Also reachable from InvestmentAccountDetailView (account edit)
struct InvestmentAccountFormView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let account: InvestmentAccount?
    let onSave: (InvestmentAccount, Bool) -> Void

    @State private var name: String
    @State private var broker: String
    @State private var currency: String
    @State private var accountType: String
    @State private var openedAt: Date
    @State private var cashBalance: Double

    /// Management of the LiveSync links (Binance/EVM/BTC/SOL) attached to THIS
    /// account — see the header of `LiveSyncSettingsView.swift`. `nil` for a
    /// creation (no account id to filter on yet).
    @State private var linkedSources: [InvestmentLiveSyncLink] = []
    @State private var showLinkPicker = false
    @State private var selectedLinkForDetail: InvestmentLiveSyncLink?

    private var isNew: Bool { account == nil }

    /// init() sets every @State at build time from the given account, so SwiftUI
    /// reusing the instance of a previous presentation can't leave stale values.
    init(account: InvestmentAccount?, onSave: @escaping (InvestmentAccount, Bool) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account?.name ?? "")
        _broker = State(initialValue: account?.broker ?? "")
        _currency = State(initialValue: account?.currency ?? "EUR")
        _accountType = State(initialValue: account?.accountType ?? InvestmentAccountType.cto.rawValue)
        _openedAt = State(initialValue: account?.openedAt ?? Date())
        _cashBalance = State(initialValue: account?.cashBalance ?? 0)
    }

    var body: some View {
            Form {
                Section("Identité") {
                    TextField("Nom du compte", text: $name)
                    TextField("Courtier / banque", text: $broker)
                    TextField("Devise", text: $currency)
                        .textInputAutocapitalization(.characters)
                    Picker("Type", selection: $accountType) {
                        ForEach(InvestmentAccountType.allCases, id: \.rawValue) { type in
                            Text(LocalizedStringKey(type.label)).tag(type.rawValue)
                        }
                    }
                    DatePicker("Date d'ouverture", selection: $openedAt, displayedComponents: .date)
                }

                Section {
                    HStack {
                        Text("Trésorerie disponible")
                        Spacer()
                        TextField("0", value: $cashBalance, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        Text(currency.uppercased())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                } footer: {
                    Text("Cash en attente de placement (dividendes pas réinvestis, ventes en attente, dépôts récents). Vient s'ajouter à la valeur des positions pour le total du compte.")
                }

                // DERIVED values: shown read-only when editing an existing account. For a
                // creation, an explanatory section only.
                if let account {
                    Section {
                        LabeledContent("Valeur des positions",
                            value: account.currentValue,
                            format: .currency(code: account.currency))
                        LabeledContent("Trésorerie disponible",
                            value: account.cashBalance,
                            format: .currency(code: account.currency))
                        LabeledContent("Valorisation totale",
                            value: account.currentValue + account.cashBalance,
                            format: .currency(code: account.currency))
                            .fontWeight(.semibold)
                        LabeledContent("Montant investi",
                            value: account.investedAmount,
                            format: .currency(code: account.currency))
                        LabeledContent("Performance",
                            value: account.currentValue - account.investedAmount,
                            format: .currency(code: account.currency))
                    } header: {
                        Text("Récap")
                    } footer: {
                        Text("Les positions et la performance sont calculées automatiquement depuis les ordres. La trésorerie est éditable ci-dessus.")
                    }
                } else {
                    Section {
                        Label("La valeur et le montant investi du compte seront calculés depuis les positions et leurs ordres",
                              systemImage: "wand.and.stars")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                // A freshly created account has no id to filter on yet — the section is
                // visible only when editing, like the Summary.
                if let account {
                    linkedSourcesSection(account)
                }
            }
            .nemorisFormStyle()
            .onAppear(perform: loadLinkedSources)
            .adaptivePane(isPresented: $showLinkPicker, onDismiss: loadLinkedSources) {
                NavigationStack {
                    LiveSyncProviderPickerView(accountId: account?.id)
                }
                .paywallOverlay(for: .investmentsLiveSync)
            }
            .adaptivePane(item: $selectedLinkForDetail, onDismiss: loadLinkedSources) { link in
                LiveSyncLinkDetailView(link: link, onChange: loadLinkedSources)
            }
            // No .onAppear to repopulate the editable fields — init() already does it,
            // which avoids stale state when SwiftUI reuses the instance.
            // `linkedSources` is an auxiliary READ-ONLY list, not an editable field: the
            // `.onAppear` above is safe.
            .paneChrome(isNew ? "Nouveau compte" : "Modifier compte",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                onSave(InvestmentAccount(
                    id: account?.id ?? 0,
                    name: name,
                    broker: broker,
                    currency: currency.uppercased(),
                    accountType: accountType,
                    // Both fields stay on the struct for reads, but the repository doesn't write
                    // these columns (they are derived). Existing values are passed when editing,
                    // 0 when creating — no effect on what's persisted.
                    currentValue: account?.currentValue ?? 0,
                    investedAmount: account?.investedAmount ?? 0,
                    openedAt: openedAt,
                    cashBalance: cashBalance
                ), isNew)
                dismiss()
            }
    }

    // MARK: - Sync (LiveSync)

    @ViewBuilder
    private func linkedSourcesSection(_ account: InvestmentAccount) -> some View {
        Section {
            ForEach(linkedSources) { link in
                Button {
                    selectedLinkForDetail = link
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: LiveSyncRegistry.provider(for: link.providerId)?.iconName ?? "questionmark.circle")
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.displayName)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(LiveSyncRegistry.provider(for: link.providerId)?.displayName ?? link.providerId)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        if !link.enabled {
                            Text("Désactivé")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(AppTheme.Colors.textSecondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        } else if link.lastSyncStatus == .error {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.danger)
                        } else if link.lastSyncStatus == .ok {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.success)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                showLinkPicker = true
            } label: {
                Label(linkedSources.isEmpty ? "Lier un exchange / wallet" : "Lier une autre source",
                      systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("Synchronisation")
        } footer: {
            Text("Les identifiants restent dans le Keychain de cet appareil — un lien créé ici n'apparaît pas sur vos autres appareils, à refaire sur chacun.")
        }
    }

    private func loadLinkedSources() {
        guard let account else { linkedSources = []; return }
        linkedSources = LiveSyncRepository.shared.fetchLinks().filter { $0.accountId == account.id }
    }
}

// Also reachable from InvestmentAccountDetailView + InvestmentPositionDetailView
struct InvestmentPositionFormView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let accountId: Int
    let position: InvestmentPosition?
    let onSave: (InvestmentPosition, Bool) -> Void

    @State private var assetType: String
    @State private var assetName: String
    @State private var ticker: String
    @State private var isin: String
    @State private var currentValue: Double

    private var isNew: Bool { position == nil }

    /// init() sets the @State at build time from the given position, so a reused
    /// SwiftUI instance can't lose edits between two presentations.
    init(accountId: Int, position: InvestmentPosition?, onSave: @escaping (InvestmentPosition, Bool) -> Void) {
        self.accountId = accountId
        self.position = position
        self.onSave = onSave
        _assetType = State(initialValue: position?.assetType ?? InvestmentAssetType.stock.rawValue)
        _assetName = State(initialValue: position?.assetName ?? "")
        _ticker = State(initialValue: position?.ticker ?? "")
        _isin = State(initialValue: position?.isin ?? "")
        _currentValue = State(initialValue: position?.currentValue ?? 0)
    }

    /// ISIN validation: 12 chars (2 country letters + 10 alphanumerics). Empty
    /// (optional) or exactly 12 compliant chars pass — otherwise the user is
    /// alerted.
    private var isinValidationError: String? {
        let trimmed = isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return nil }
        if trimmed.count != 12 {
            return "L'ISIN doit faire exactement 12 caractères"
        }
        let pattern = "^[A-Z]{2}[A-Z0-9]{9}[0-9]$"
        if trimmed.range(of: pattern, options: .regularExpression) == nil {
            return "Format ISIN invalide (ex : FR0000121329)"
        }
        return nil
    }

    var body: some View {
            Form {
                Section {
                    Picker("Type", selection: $assetType) {
                        ForEach(InvestmentAssetType.allCases, id: \.rawValue) { type in
                            Text(LocalizedStringKey(type.label)).tag(type.rawValue)
                        }
                    }
                    TextField("Nom actif", text: $assetName)
                    TextField("Ticker (ex : HO.PA, AAPL)", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("ISIN (ex : FR0000121329)", text: $isin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if let err = isinValidationError {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                } header: {
                    Text("Identification")
                } footer: {
                    Text("L'ISIN est l'identifiant universel d'un actif (12 caractères, ex : FR0000121329). C'est ce qu'utilise la sync de cours pour trouver le bon symbole boursier — bien plus fiable que le ticker. Si tu l'as, renseigne-le.")
                }

                Section {
                    HStack {
                        Text("Valeur actuelle (marché)")
                        Spacer()
                        TextField("0", value: $currentValue, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        Text("€").foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                } footer: {
                    Text("Mise à jour automatiquement par la synchronisation de cours, ou modifiable manuellement.")
                }

                // Fields DERIVED from orders. Shown read-only to avoid any confusion: if the
                // user edited them here, the first order add/edit would silently overwrite
                // their values.
                if let position {
                    Section {
                        LabeledContent("Quantité",
                            value: formattedQty(position.quantity))
                        LabeledContent("PRU (Prix de Revient Unitaire)",
                            value: formattedMoney(position.averageBuyPrice))
                        LabeledContent("Date du premier achat",
                            value: position.purchaseDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appState.locale)))
                    } header: {
                        Text("Dérivé des ordres")
                    } footer: {
                        Text("Ces valeurs sont recalculées automatiquement à partir des ordres (achats, ventes, dividendes) rattachés à cette position. Pour les modifier, édite ou ajoute un ordre depuis la fiche de la position.")
                    }
                } else {
                    Section {
                        Label("Quantité, PRU et date d'achat seront calculés depuis les ordres",
                              systemImage: "wand.and.stars")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } footer: {
                        Text("Une fois la position créée, ajoute un ou plusieurs ordres (BUY/SELL/DIV) — la quantité nette et le PRU pondéré seront calculés automatiquement.")
                    }
                }
            }
            .nemorisFormStyle()
            // No .onAppear — init() sets everything at build time.
            .paneChrome(isNew ? "Nouvelle position" : "Modifier position",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        // Blocks saving if an ISIN was entered in an invalid format — avoids
                        // persisting a bogus ISIN that would break the sync.
                        confirmDisabled: assetName.trimmingCharacters(in: .whitespaces).isEmpty
                              || isinValidationError != nil) {
                onSave(InvestmentPosition(
                    id: position?.id ?? 0,
                    accountId: accountId,
                    assetType: assetType,
                    assetName: assetName,
                    ticker: ticker.uppercased(),
                    isin: isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                    // For a new position: 0/0/today (recomputed on the first order add). For an
                    // edit: the existing DERIVED values are read back (the repository doesn't
                    // write them anyway).
                    quantity: position?.quantity ?? 0,
                    averageBuyPrice: position?.averageBuyPrice ?? 0,
                    currentValue: currentValue,
                    purchaseDate: position?.purchaseDate ?? Date()
                ), isNew)
                dismiss()
            }
    }

    private func formattedQty(_ q: Double) -> String {
        String(format: "%g", q)
    }

    private func formattedMoney(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = appState.locale
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
