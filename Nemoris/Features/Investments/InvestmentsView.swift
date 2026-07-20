import SwiftUI
import UniformTypeIdentifiers
import Charts
import TipKit

/// Chantier D — wrapper Identifiable pour présenter l'import intelligent
/// pré-rempli via `.sheet(item:)` (document déposé par un raccourci Siri).
struct PreloadedInvestmentImport: Identifiable {
    let id = UUID()
    let url: URL
}

struct InvestmentsView: View {
    @Environment(PurchaseManager.self) private var store
    @Environment(AppState.self) private var appState
    @State private var viewModel = InvestmentsViewModel()
    private let overviewTip = InvestmentsOverviewTip()

    // AXE M : sheet add/edit séparées pour éviter la race entre `editingAccount` et
    // `showAccountForm` (qui causait "edit ouvre le formulaire d'ajout" parfois).
    // - `showAddAccountForm` (Bool) : nouvelle entrée
    // - `editingAccount` (Identifiable optional) : édition via `.sheet(item:)`
    @State private var showAddAccountForm = false
    @State private var editingAccount: InvestmentAccount?
    @State private var accountToDelete: InvestmentAccount?

    @State private var showAddPositionForm = false
    @State private var editingPosition: InvestmentPosition?

    // AXE J Phase 2 : import devient un sheet dédié, plus un onglet.
    @State private var showImportSheet = false
    @State private var showPDFImportSheet = false
    @State private var showFilePicker = false

    /// Chantier D — import intelligent pré-rempli par un raccourci Siri.
    @State private var preloadedImport: PreloadedInvestmentImport?

    @State private var csvRawContent = ""
    @State private var csvMapping = InvestmentCSVMapping(
        isin: "", quantity: "", averageBuyPrice: "", purchaseDate: ""
    )
    @State private var csvProfile: InvestmentCSVSourceProfile = .generic
    @State private var datePolicy: Int = 1
    @State private var importResultMessage: String?

    /// Skeleton tant que le 1er `viewModel.load()` n'est pas terminé.
    @State private var hasLoaded = false

    var isEmbedded: Bool = false

    var body: some View {
        Group {
            if isEmbedded { navContent } else { NavigationStack { navContent } }
        }
        .paywallOverlay(for: .investments)
    }

    @ViewBuilder private var navContent: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            // AXE J Phase 2 : un seul écran d'accueil = dashboard global.
            // L'accès aux comptes/positions se fait par drill-down (NavigationLink).
            // L'import CSV est accessible via le toolbar Menu (anciennement onglet).
            dashboardTab
        }
        .navigationTitle("Investissements")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddAccountForm = true
                    } label: {
                        Label("Ajouter un compte", systemImage: "building.columns")
                    }
                    // Entrée d'import UNIQUE : le parcours intelligent gère déjà
                    // PDF / capture d'écran / image / CSV. Si Apple Intelligence
                    // n'est pas dispo, il propose lui-même le repli vers l'import
                    // CSV déterministe (mapping de colonnes) — l'offline-first
                    // reste garanti sans IA.
                    Button {
                        showPDFImportSheet = true
                    } label: {
                        Label("Importer un relevé…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        // Add : sheet déclenchée par un Bool, passe toujours nil → mode création.
        .sheet(isPresented: $showAddAccountForm) {
            InvestmentAccountFormView(account: nil) { account, isNew in
                viewModel.saveAccount(account, isNew: isNew)
            }
        }
        // Edit : sheet item-driven, fresh View pour chaque account → pas de stale state.
        .sheet(item: $editingAccount) { account in
            InvestmentAccountFormView(account: account) { updated, isNew in
                viewModel.saveAccount(updated, isNew: isNew)
            }
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
        .sheet(isPresented: $showAddPositionForm) {
            if let accountId = viewModel.selectedAccountId {
                InvestmentPositionFormView(accountId: accountId, position: nil) { position, isNew in
                    viewModel.savePosition(position, isNew: isNew)
                }
            }
        }
        .sheet(item: $editingPosition) { position in
            InvestmentPositionFormView(accountId: position.accountId, position: position) { updated, isNew in
                viewModel.savePosition(updated, isNew: isNew)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            NavigationStack {
                importTab
                    .navigationTitle("Importer un CSV")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { showImportSheet = false }
                                .tint(AppTheme.Colors.accent)
                        }
                    }
            }
        }
        .sheet(isPresented: $showPDFImportSheet) {
            // Repli sans Apple Intelligence → import CSV déterministe.
            InvestmentPDFImportView(onFallbackToCSV: { showImportSheet = true })
        }
        // Chantier D — import intelligent ouvert par un raccourci Siri (document
        // pré-rempli). Consomme aussi l'URL en attente si la vue vient d'être
        // montée par navigateToTab(.investments) avant que .onChange ne s'attache.
        .sheet(item: $preloadedImport) { item in
            InvestmentPDFImportView(preloadedFileURL: item.url,
                                    onFallbackToCSV: { showImportSheet = true })
        }
        .onChange(of: appState.pendingInvestmentImportURL) { _, url in
            consumePendingInvestmentImport(url)
        }
        .onAppear {
            consumePendingInvestmentImport(appState.pendingInvestmentImportURL)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            guard let rawContent = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .windowsCP1252))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
                importResultMessage = "Impossible de lire le fichier CSV"
                return
            }
            csvRawContent = rawContent
            viewModel.loadCSV(content: rawContent)
            hydrateDefaultMappingIfNeeded()
        }
        // viewModel.load() est appelé dans .task du dashboardTab pour piloter le skeleton.
    }

    // MARK: - Chantier A — statut de sync (hook minimal, restylé au chantier B)

    @MainActor
    private static let syncRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
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
                // Erreurs éventuelles de la dernière passe, en une ligne discrète.
                if let summary = service.lastSummary,
                   summary.contains("limité") || summary.contains("erreur") || summary.contains("KO") {
                    Text("· \(summary)")
                        .lineLimit(1)
                }
            }
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.Colors.textSecondary)
    }

    /// Ligne KPI compacte "Investi X · Plus-value Y" (remplace la carte 2 badges).
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

    // MARK: - Dashboard Tab (AXE J — refonte style Finary, DA Nemoris)

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

                // ── Hero + chart + chips (style Apple Stocks épuré) ──────
                // Tout vit directement sur le fond : grand chiffre, chart qui
                // respire bord-à-bord, chips SOUS le chart (pattern Stocks).
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    InvestmentHeroCard(
                        title: "Valorisation totale",
                        currentValue: viewModel.portfolioCurrentValue
                            + (appState.investmentsIncludeCashInTotal ? viewModel.portfolioTotalCash : 0),
                        previousValue: viewModel.portfolioStartValue,
                        currency: "EUR",
                        rangeLabel: variationRangeLabel(viewModel.selectedTimeRange),
                        // basis variation = positions seules pour cohérence avec portfolioStartValue
                        variationBasisValue: viewModel.portfolioCurrentValue
                    )

                    // KPI en ligne discrète (remplace la carte 2 StatBadge).
                    kpiInlineLine(invested: stats.totalInvested, performance: stats.performance)
                        .padding(.top, 2)

                    // Chart sur fond direct. PAS de .clipped() ici : ça couperait
                    // les labels d'axe X qui sont positionnés sous le plot area.
                    EvolutionChart(
                        points: viewModel.portfolioEvolution,
                        height: 210,
                        timeRange: viewModel.selectedTimeRange
                    )
                    .padding(.top, AppTheme.Spacing.xs)

                    TimeRangeChips(
                        selection: Binding(
                            get: { viewModel.selectedTimeRange },
                            set: { newValue in
                                viewModel.selectedTimeRange = newValue
                                viewModel.recomputePortfolioEvolution()
                                // Plage 1J → il faut la série INTRADAY (30 min).
                                // Fetch on-demand (skip si fraîche < 25 min) puis
                                // recalcul quand les points sont arrivés.
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
                        // Compte le plus ancien comme référence : pas de sens
                        // d'afficher 10A si l'user le plus ancien a 6 mois.
                        ranges: InvestmentTimeRange.availableRanges(
                            since: viewModel.accounts.map(\.openedAt).min() ?? Date()
                        )
                    )

                    // Chantier A — statut de la sync auto (spinner + progression
                    // pendant, "Actualisé il y a X" après).
                    syncStatusLine
                        .padding(.top, 2)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)

                // ── Allocation (donut à plat, sans carte) ────────────────
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
        // `.task(id:)` se redéclenche dès que dataRefreshToken change. Permet aux
        // child views (PositionDetail, AccountDetail) de marquer le global comme
        // dirty après save/delete d'un ordre via `appState.dataRefreshToken = UUID()`.
        .task(id: appState.dataRefreshToken) {
            // 1-frame guard : laisse le skeleton s'afficher avant la requête SQLite.
            await Task.yield()
            viewModel.load()
            // Recompute si on a des comptes mais pas encore d'évolution chargée
            if viewModel.portfolioEvolution.isEmpty && !viewModel.accounts.isEmpty {
                viewModel.recomputePortfolioEvolution()
            }
            hasLoaded = true
        }
        // Chantier A — déclencheur d'auto-sync à l'ouverture du module.
        // ⚠️ Task SÉPARÉE du .task(id: dataRefreshToken) ci-dessus : la fin de
        // passe bumpe le token, ce qui annulerait/relancerait cette task et
        // re-déclencherait la sync en boucle.
        .task {
            await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .investmentsOpened)
        }
        .refreshable {
            // Pull-to-refresh : force une passe complète (bypass de l'intervalle
            // 4 h, pas du verrou isSyncing). Le reload principal arrive via
            // .nemorisInvestmentsDidSync → bump du token ; reloadAll() en filet
            // si la passe n'a rien fait (toggle off / sync déjà en cours).
            await InvestmentAutoSyncService.shared.autoSyncIfNeeded(trigger: .pullToRefresh)
            reloadAll()
        }
    }

    /// Helper centralisé : reload positions + évolution. Utilisé par pull-to-refresh.
    private func reloadAll() {
        viewModel.load()
        viewModel.recomputePortfolioEvolution()
    }

    /// Chantier D — présente l'import intelligent pré-rempli et libère l'URL en
    /// attente (one-shot). No-op si nil ou si une sheet est déjà en cours.
    private func consumePendingInvestmentImport(_ url: URL?) {
        guard let url, preloadedImport == nil else { return }
        preloadedImport = PreloadedInvestmentImport(url: url)
        appState.pendingInvestmentImportURL = nil
    }

    // MARK: - Skeleton

    @ViewBuilder private var investmentsSkeleton: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            // Hero + KPI line + chart + chips (à plat, style Apple Stocks)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonHero()
                SkeletonLine(width: 200, height: 13)
                SkeletonChart(height: 210)
                // TimeRange chips SOUS le chart, pleine largeur
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { _ in
                        SkeletonBlock(width: 40, height: 28, cornerRadius: 14)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)

            // Allocation donut à plat
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    SkeletonLine(width: 110, height: 15)
                    Spacer()
                    SkeletonBlock(width: 150, height: 26, cornerRadius: 13)
                }
                SkeletonDonut(size: 150)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)

            // Liste comptes à plat
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonLine(width: 130, height: 15)
                SkeletonAccountRow()
                SkeletonAccountRow()
                SkeletonAccountRow()
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
        }
    }

    /// Donut allocation à plat (sans carte) + toggle "Par type"/"Par compte".
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

    /// Section comptes à plat (sans carte) avec NavigationLink vers AccountDetailView.
    /// Chantier B : style Apple Stocks — rows aérées, sparkline 1M au centre,
    /// valeur en chiffres alignés à droite. `.swipeActions` natif conservé (AXE M).
    @ViewBuilder
    private func accountsListSection() -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SectionHeader(title: "Comptes (\(viewModel.accounts.count))")
                .padding(.horizontal, AppTheme.Spacing.sm)
            List {
                ForEach(viewModel.accounts) { account in
                    NavigationLink {
                        InvestmentAccountDetailView(viewModel: viewModel, account: account)
                    } label: {
                        accountRow(account)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: AppTheme.Spacing.sm, bottom: 6, trailing: AppTheme.Spacing.sm))
                    .listRowSeparatorTint(AppTheme.Colors.textSecondary.opacity(0.12))
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            // .sheet(item:) s'ouvre dès qu'editingAccount devient non-nil
                            editingAccount = account
                        } label: {
                            Label("Modifier", systemImage: "pencil")
                        }
                        .tint(AppTheme.Colors.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            accountToDelete = account
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            // Hauteur estimée : ~64pt par row (titre + sous-titre + paddings aérés).
            .frame(height: CGFloat(viewModel.accounts.count) * 64)
        }
    }

    /// Row d'un compte dans la liste du dashboard global (style Apple Stocks).
    /// Affiche : nom · broker/type · sparkline 1M · valeur courante alignée.
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

            // Sparkline 1 mois (enfin utilisée) — masquée si pas assez d'historique.
            if let spark = viewModel.accountSparklines[account.id] {
                InvestmentSparkline(points: spark, height: 28, width: 56)
            }

            VStack(alignment: .trailing, spacing: 2) {
                // Total = positions + trésorerie (cohérent avec le hero compte)
                Text(account.totalValuation, format: .currency(code: account.currency))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                // Cash en sous-ligne discrète si > 0 — l'user voit que sur ce
                // compte une partie du capital est en trésorerie
                if account.cashBalance > 0 {
                    Text("dont \(account.cashBalance, format: .currency(code: account.currency)) cash")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            // Chevron supprimé : depuis le passage en List + NavigationLink (AXE M),
            // iOS ajoute son propre chevron natif en bout de row. On évite le doublon.
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// État vide quand aucun compte n'existe encore — incite à en créer un.
    private var emptyAccountsCard: some View {
        AppCard {
            EmptyStateView(
                icon: "building.columns",
                title: "Aucun compte",
                message: "Crée un compte PEA, CTO, crypto ou autre via le menu en haut à droite."
            )
        }
    }

    /// Label affiché à côté du % de variation dans le hero ("sur 1 mois", etc.)
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
                    Picker("Compte cible", selection: Binding(
                        get: { viewModel.selectedAccountId ?? 0 },
                        set: { viewModel.selectedAccountId = ($0 == 0 ? nil : $0) }
                    )) {
                        Text("Sélectionner un compte").tag(0)
                        ForEach(viewModel.accounts) { account in
                            Text(account.name).tag(account.id)
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

// Accessible aussi depuis InvestmentAccountDetailView (édition compte)
struct InvestmentAccountFormView: View {
    @Environment(\.dismiss) private var dismiss
    let account: InvestmentAccount?
    let onSave: (InvestmentAccount, Bool) -> Void

    @State private var name: String
    @State private var broker: String
    @State private var currency: String
    @State private var accountType: String
    @State private var openedAt: Date
    @State private var cashBalance: Double

    private var isNew: Bool { account == nil }

    /// AXE M : init() set tous les @State au build time depuis l'account passé en
    /// argument. Avant on faisait `.onAppear { populateFields() }`, ce qui causait
    /// des bugs de stale state quand SwiftUI réutilisait l'instance d'une présentation
    /// précédente. Ici les valeurs sont figées dès la construction de la View.
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
        NavigationStack {
            Form {
                Section("Identité") {
                    TextField("Nom du compte", text: $name)
                    TextField("Courtier / banque", text: $broker)
                    TextField("Devise", text: $currency)
                        .textInputAutocapitalization(.characters)
                    Picker("Type", selection: $accountType) {
                        ForEach(InvestmentAccountType.allCases, id: \.rawValue) { type in
                            Text(type.label).tag(type.rawValue)
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

                // Valeurs DÉRIVÉES (depuis migration v30) : affichées en lecture
                // seule sur l'édition d'un compte existant. Pour une création,
                // section explicative seulement.
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
            }
            .navigationTitle(isNew ? "Nouveau compte" : "Modifier compte")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        onSave(InvestmentAccount(
                            id: account?.id ?? 0,
                            name: name,
                            broker: broker,
                            currency: currency.uppercased(),
                            accountType: accountType,
                            // Les 2 champs sont conservés dans le struct pour
                            // rétro-compat des lectures, mais le repo n'écrit
                            // plus ces colonnes (droppées en v30). On passe les
                            // valeurs existantes pour une édition ou 0 pour
                            // une création — sans effet sur le persisté.
                            currentValue: account?.currentValue ?? 0,
                            investedAmount: account?.investedAmount ?? 0,
                            openedAt: openedAt,
                            cashBalance: cashBalance
                        ), isNew)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            // Pas de .onAppear pour repopulate — l'init() le fait déjà,
            // ce qui évite la stale state quand SwiftUI réutilise l'instance.
        }
    }
}

// Accessible aussi depuis InvestmentAccountDetailView + InvestmentPositionDetailView (AXE J)
struct InvestmentPositionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let accountId: Int
    let position: InvestmentPosition?
    let onSave: (InvestmentPosition, Bool) -> Void

    @State private var assetType: String
    @State private var assetName: String
    @State private var ticker: String
    @State private var isin: String
    @State private var currentValue: Double

    private var isNew: Bool { position == nil }

    /// AXE M : init() set @State au build time depuis la position passée. Évite
    /// la stale state qui causait "modifications pas enregistrées" quand la même
    /// instance était réutilisée par SwiftUI entre deux présentations.
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

    /// Validation ISIN : 12 chars (2 lettres pays + 10 alphanum). On laisse passer
    /// vide (optionnel) ou exactement 12 chars conformes — sinon on alerte l'user.
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
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $assetType) {
                        ForEach(InvestmentAssetType.allCases, id: \.rawValue) { type in
                            Text(type.label).tag(type.rawValue)
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

                // Champs DÉRIVÉS des ordres (AXE K). Affichés en lecture seule
                // pour éviter toute confusion : si l'user les modifiait ici, le
                // premier add/edit d'ordre écraserait silencieusement leurs valeurs.
                if let position {
                    Section {
                        LabeledContent("Quantité",
                            value: formattedQty(position.quantity))
                        LabeledContent("PRU (Prix de Revient Unitaire)",
                            value: formattedMoney(position.averageBuyPrice))
                        LabeledContent("Date du premier achat",
                            value: position.purchaseDate.formatted(date: .abbreviated, time: .omitted))
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
            .navigationTitle(isNew ? "Nouvelle position" : "Modifier position")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        onSave(InvestmentPosition(
                            id: position?.id ?? 0,
                            accountId: accountId,
                            assetType: assetType,
                            assetName: assetName,
                            ticker: ticker.uppercased(),
                            isin: isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                            // Pour une nouvelle position : 0/0/today (seront recalculés
                            // au premier add d'ordre). Pour une édition : on relit
                            // les valeurs DÉRIVÉES existantes (le repo ne les écrit
                            // de toute façon plus).
                            quantity: position?.quantity ?? 0,
                            averageBuyPrice: position?.averageBuyPrice ?? 0,
                            currentValue: currentValue,
                            purchaseDate: position?.purchaseDate ?? Date()
                        ), isNew)
                        dismiss()
                    }
                    // Bloque le save si ISIN saisi mais format invalide — évite
                    // de persister un ISIN bidon qui ferait planter la sync.
                    .disabled(assetName.trimmingCharacters(in: .whitespaces).isEmpty
                              || isinValidationError != nil)
                }
            }
            // Pas de .onAppear — init() set tout au build time.
        }
    }

    private func formattedQty(_ q: Double) -> String {
        String(format: "%g", q)
    }

    private func formattedMoney(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
