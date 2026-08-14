import SwiftUI
import Charts

// MARK: - Phase 2 — Niveau Compte
//
// Écran de détail d'un compte d'investissement, accessible via NavigationLink depuis
// la liste des comptes du dashboard. Reproduit la structure du dashboard global mais
// restreint aux positions de ce compte :
//   - Hero card (valeur compte + variation + invested + P/L)
//   - Chart évolution du compte (chips temporelles)
//   - Donut allocation interne (par type d'actif)
//   - Liste des positions cliquables (NavigationLink → PositionDetailView)
//
// Toolbar : bouton "+ position" pour ajouter manuellement.

struct InvestmentAccountDetailView: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    /// macOS : retour au dashboard global. Le compte est affiché EN PLEINE PAGE
    /// dans la colonne du module (navigation interne par état — cf.
    /// `InvestmentsView.dashboardContent`), il fournit donc lui-même son retour.
    /// nil sur iOS, où la vue est poussée et le back du `NavigationStack` suffit.
    var onBack: (() -> Void)? = nil

    @State private var localTimeRange: InvestmentTimeRange = .threeMonth
    @State private var evolution: [PortfolioEvolutionPoint] = []
    /// Explication affichée quand la plage 1J n'a aucun cours intrajournalier
    /// (courbe volontairement vide plutôt que fabriquée depuis le quotidien).
    @State private var oneDayUnavailableNote: String?
    /// Positions sans price_history → empêchent l'affichage du chart de
    /// porter sur leur valeur. Affiché en card diagnostic.
    @State private var positionsWithoutHistory: [InvestmentPosition] = []
    @State private var positions: [InvestmentPosition] = []
    // add (Bool) + edit (Identifiable item) séparés pour éviter le bug
    // "edit ouvre parfois le formulaire d'ajout" causé par la race state.
    @State private var showAddPositionForm = false
    @State private var editingPosition: InvestmentPosition?
    #if os(macOS)
    /// macOS : la fiche position s'ouvre dans le PANNEAU LATÉRAL global
    /// (`.adaptivePane` → HStack custom de MainTabView, 100% SwiftUI).
    /// Historique : le push cliqué profondeur 1 → 2 déclenchait une récursion
    /// AutoLayout `_postWindowNeedsUpdateConstraints` (macOS 27 beta) même
    /// PILOTÉ PAR ÉTAT (navigationDestination) — le harnais -nemorisCrashRepro
    /// ne validait que les pushes programmés hors cycle d'événement, le clic
    /// réel crashait toujours (23/07). Le panneau n'empile aucune vue dans la
    /// NavigationStack → la machinerie en cause n'est plus jamais tapée.
    @State private var panePosition: InvestmentPosition?
    #endif

    // Édition / suppression compte
    @State private var showAccountEditForm = false
    @State private var showDeleteAccountConfirm = false
    // Suppression position
    @State private var positionToDelete: InvestmentPosition?

    // Sync de masse
    @State private var isSyncingAll = false
    @State private var syncAllStatus: String?
    /// Skeleton tant que le 1er `refresh()` n'est pas terminé.
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss
    // paneDismiss : fermeture depuis le panneau macOS (drill-down depuis
    // InvestmentsView, plus un push — cf. \.paneHostContext ci-dessous). Sans
    // effet sur iOS où cette vue reste poussée (NavigationLink, back auto).
    @Environment(\.paneDismiss) private var paneDismiss
    #if os(macOS)
    @Environment(\.paneHostContext) private var paneHostContext
    #endif
    @Environment(AppState.self) private var appState

    private var invested: Double {
        positions.reduce(0) { $0 + $1.investedAmount }
    }

    /// Valorisation totale = valeur des positions + trésorerie disponible.
    /// La trésorerie n'est PAS dans le calcul de performance — elle est neutre
    /// (cash investi vs cash brut). Performance = positions only.
    private var totalAccountValue: Double {
        account.currentValue + account.cashBalance
    }

    private var performance: Double {
        account.currentValue - invested
    }

    private var performanceColor: Color {
        performance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    /// True si aucune position du compte n'est syncée (`account.currentValue ≤ 0`)
    /// mais qu'on a au moins investi quelque chose. Évite l'affichage trompeur
    /// "€0 / Performance -100%" tant que les cours n'ont pas été récupérés.
    private var valuationIsEstimated: Bool {
        account.currentValue <= 0 && invested > 0
    }

    /// Hero shows market value if synced, else cost basis (= invested).
    /// Inclut la trésorerie SI le toggle utilisateur l'autorise.
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
        // Contenu de module (pleine page) sur les DEUX plateformes → toolbar
        // native. Sur macOS elle porte en plus le retour au dashboard.
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
        // Confirmation suppression compte
        .confirmationDialog(
            "Supprimer ce compte ?",
            isPresented: $showDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer le compte", role: .destructive) {
                viewModel.deleteAccount(id: account.id)
                appState.dataRefreshToken = UUID()
                // Les deux : `dismiss` pop (iOS, push), `paneDismiss` ferme le
                // panneau (macOS) — chacun no-op hors de son contexte.
                dismiss()
                paneDismiss()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Toutes les positions et ordres rattachés à ce compte seront aussi supprimés (cascade).")
        }
        // Confirmation suppression position (déclenché par contextMenu sur la row)
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
            // Plage 1J → fetch on-demand de la série intraday 30 min des
            // positions du compte, puis recalcul quand les points sont là.
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

    // MARK: - Toolbar (sortie en ViewBuilder pour aider le type-checker)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Sync déclenchée par pull-to-refresh sur la ScrollView — pas de bouton dédié.
        #if os(macOS)
        // Retour au dashboard global : le compte occupe la colonne du module
        // (pas un push), il fournit donc son propre retour. `.navigation` est le
        // placement du back système, à gauche du titre.
        if let onBack {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .help("Tous les comptes")
                .accessibilityLabel("Tous les comptes")
            }
        }
        // Menu "⋯" aplati en boutons icône + tooltip dans UNE pilule via
        // `ToolbarItemGroup` (groupement natif — `ControlGroup` rendait des
        // boutons isolés), cohérent avec les autres toolbars macOS de l'app.
        ToolbarItemGroup(placement: .topBarTrailing) {
            PaneToggleButton(label: "Ajouter une position", systemImage: "plus", isOn: $showAddPositionForm)
            // Apparaît uniquement si le compte contient des cryptos —
            // utile pour réparer des valeurs corrompues par d'anciens
            // sync Yahoo (FET → action FET cotée €53, ETH → Ethernity, etc.)
            if positions.contains(where: { $0.isCryptoAsset }) {
                Button {
                    repairCryptoValues()
                } label: {
                    Image(systemName: "wrench.adjustable")
                }
                .help("Réparer les valeurs crypto")
            }
            PaneToggleButton(label: "Modifier le compte", systemImage: "pencil", isOn: $showAccountEditForm)
            Button(role: .destructive) {
                showDeleteAccountConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Supprimer le compte")
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

    /// hero+chart sortis de la carte pour effet "premium" Robinhood/Finary.
    /// KPIs déplacés dans une carte dédiée en dessous pour respiration visuelle.
    /// Card affichée seulement quand au moins une position n'a pas de cours
    /// historique récupérable. Liste les positions concernées avec un CTA
    /// "Synchroniser celles-ci" qui ne sync QUE ces positions (pas les autres).
    ///
    /// Diagnostic critique : explique à l'utilisateur que le graphique est incomplet
    /// parce que ces positions ne contribuent pas (rien à multiplier par leur
    /// quantity), donc la valeur agrégée est tronquée.
    /// Chantier B — réduite à une ligne discrète tappable (au lieu d'une carte
    /// verbeuse listant chaque position). Tap → sync ciblée des positions
    /// sans historique.
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

    /// Purge les price_history scrappés à tort sur Yahoo pour les tickers
    /// crypto + reset current_value des positions crypto à 0. l'utilisateur doit
    /// ensuite relancer LiveSync Binance/wallet pour récupérer les vraies
    /// valeurs CoinGecko.
    private func repairCryptoValues() {
        let result = InvestmentRepository().purgeCorruptedCryptoData()
        syncAllStatus = "Crypto réparé : \(result.positionsReset) position(s) reset, \(result.historyRowsDeleted) cours Yahoo purgés. Relance ta sync Binance/wallet."
        viewModel.load()
        refresh()
    }

    /// Variante de `syncAllPositions` qui ne sync QUE les positions sans
    /// historique — utile depuis la card diagnostic. Route automatiquement
    /// vers CoinGecko ou Yahoo via InvestmentAutoSyncService (aucun load()
    /// par position — un seul refresh final).
    private func syncMissingHistoryPositions() async {
        let toSync = positionsWithoutHistory
        guard !toSync.isEmpty, !isSyncingAll else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        for position in toSync {
            let identifier = position.bestSyncIdentifier
            guard !identifier.isEmpty else { continue }
            _ = await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier)
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
                // Quand on bascule sur l'estimation, on annule la variation pour
                // ne pas afficher un faux -100% trompeur.
                previousValue: valuationIsEstimated ? displayedValuation : evolution.first?.value,
                currency: account.currency,
                rangeLabel: variationRangeLabel(localTimeRange),
                // ⚠️ basis variation = POSITIONS SEULES (sans cash). Sinon le calcul
                // de perf% serait gonflé artificiellement par la trésorerie ajoutée
                // au currentValue mais absente de evolution.first?.value.
                variationBasisValue: valuationIsEstimated ? displayedValuation : account.currentValue
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

            // Chart bord-à-bord, chips SOUS le chart (pattern Apple Stocks).
            // PAS de .clipped() — ça couperait les labels d'axe X (cf. EvolutionChart)
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
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    /// KPIs en ligne (investi · performance) + trésorerie si > 0. Style épuré
    /// à plat, plus de carte StatBadge.
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

            // Trésorerie : visible seulement si > 0 pour ne pas encombrer
            // les comptes sans cash.
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
            #if os(macOS)
            // ⚠️ macOS : ni List imbriquée, ni NavigationLink cliqué, ni PUSH
            // profondeur 2 (cf. doc de `panePosition`) — la fiche position
            // s'ouvre dans le panneau latéral global, comme les fiches de
            // ReferenceDataView. Le compte reste visible à gauche.
            VStack(spacing: 0) {
                ForEach(positions) { position in
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
                    if position.id != positions.last?.id {
                        Divider()
                            .overlay(AppTheme.Colors.textSecondary.opacity(0.12))
                            .padding(.leading, AppTheme.Spacing.sm)
                    }
                }
            }
            // Carte unique, même langage visuel que .macGroupedRow ailleurs dans
            // l'app (cf. accountsListSection d'InvestmentsView.swift) : pas de
            // List possible ici, donc un seul fond arrondi enveloppant les rows.
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .adaptivePane(item: $panePosition) { pushed in
                PositionPane(viewModel: viewModel, account: account, position: pushed)
            }
            #else
            // iOS : List conservée pour le swipe natif (RowActions → .swipeActions).
            List {
                ForEach(positions) { position in
                    NavigationLink {
                        InvestmentPositionDetailView(
                            viewModel: viewModel,
                            account: account,
                            position: position
                        )
                    } label: {
                        positionRow(position)
                    }
                    .listRowBackground(AppTheme.Colors.surface)
                    .listRowInsets(EdgeInsets(top: 6, leading: AppTheme.Spacing.sm, bottom: 6, trailing: AppTheme.Spacing.sm))
                    .listRowSeparatorTint(AppTheme.Colors.textSecondary.opacity(0.12))
                    .rowActions(
                        // .sheet(item:) s'ouvre dès qu'editingPosition devient non-nil
                        leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingPosition = position }],
                        trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { positionToDelete = position }],
                        leadingFullSwipe: false,
                        trailingFullSwipe: false
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            // Hauteur estimée : ~66pt par position (ticker + asset_name + valeur + PnL).
            .frame(height: CGFloat(positions.count) * 66)
            // .plain (nécessaire pour le calcul de hauteur) désactive le groupement
            // insetGrouped natif — même traitement que accountsListSection.
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
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
            // Pastille colorée par type d'actif (cohérent avec le donut)
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
            // Chevron supprimé : depuis le passage en List + NavigationLink,
            // iOS ajoute son propre chevron natif en bout de row.
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
        // Hero + chart + chips (à plat, chips sous le chart)
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
        // Allocation à plat
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SkeletonLine(width: 130, height: 15)
            SkeletonDonut(size: 150)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        // Positions à plat
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

    /// Synchronise tous les cours des positions du compte en une passe.
    /// Pipeline en 2 étapes :
    ///   1. LiveSync (Binance/EVM/BTC/SOL) si liens rattachés — refresh des
    ///      valeurs et insertion des trades crypto via CoinGecko en interne
    ///   2. InvestmentAutoSyncService.syncHistory pour chaque position →
    ///      route automatique CoinGecko (cryptos) vs Yahoo (titres), outcomes
    ///      typés, AUCUN load() par position — un seul refresh final.
    private func syncAllPositions() async {
        guard !isSyncingAll, !positions.isEmpty else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        // 1. LiveSync : refresh des valeurs + trades depuis providers externes
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

        // 2. Sync historique pour CHAQUE position (route auto CoinGecko vs Yahoo)
        var success = 0
        var upToDate = 0
        var rateLimited = 0
        var failed = 0
        for position in positions {
            let identifier = position.bestSyncIdentifier
            guard !identifier.isEmpty else { failed += 1; continue }
            switch await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier) {
            case .success:     success += 1
            case .upToDate:    upToDate += 1
            case .rateLimited: rateLimited += 1
            case .noData, .networkError, .invalidIdentifier: failed += 1
            }
        }

        var parts: [String] = []
        if success > 0      { parts.append("\(success) cours sync") }
        if upToDate > 0     { parts.append("\(upToDate) à jour") }
        if liveSyncOK > 0   { parts.append("\(liveSyncOK) LiveSync OK") }
        if liveSyncErr > 0  { parts.append("\(liveSyncErr) LiveSync KO") }
        if rateLimited > 0  { parts.append("\(rateLimited) limité\(rateLimited > 1 ? "s" : "") (réessaie plus tard)") }
        if failed > 0       { parts.append("\(failed) sans cours") }
        syncAllStatus = parts.isEmpty ? "Rien à synchroniser" : parts.joined(separator: " · ")
        // Refresh local + notification globale (→ bump dataRefreshToken dans
        // NemorisApp → reload du dashboard). Avant : viewModel.load() PAR position.
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

    private func variationRangeLabel(_ range: InvestmentTimeRange) -> String {
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

    /// Couleur stable par type d'actif — alignée sur la palette du donut.
    private func assetTypeColor(_ raw: String) -> Color {
        switch InvestmentAssetType(rawValue: raw) {
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
/// Contenu du panneau latéral pour une fiche position (contrat AdaptivePane :
/// la vue présentée garde sa NavigationStack + navigationTitle + toolbar).
/// Le bouton « Fermer » passe par `\.paneDismiss`, injecté par le wrapper.
/// `InvestmentPositionDetailView` déclare elle-même son chrome de panneau
/// (`.paneChrome` : Fermer / Supprimer / Modifier) — ce wrapper ne fait plus que
/// transmettre les paramètres. Un `NavigationStack` + `.toolbar` ici ferait
/// remonter un second jeu de boutons dans la barre du module.
private struct PositionPane: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    let position: InvestmentPosition

    var body: some View {
        InvestmentPositionDetailView(viewModel: viewModel, account: account, position: position)
    }
}
#endif
