import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Tag color helpers

extension Tag {
    /// Couleur SwiftUI du tag (cuivre Nemoris par défaut si nil).
    var displayColor: Color {
        guard let hex = color, !hex.isEmpty else { return AppTheme.Colors.accentSecondary }
        return Color(tagHex: hex)
    }
}

extension Color {
    init(tagHex hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            self = AppTheme.Colors.accentSecondary
            return
        }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double(value         & 0xFF) / 255
        )
    }

    func toTagHex() -> String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255), g = Int(components[1] * 255), b = Int(components[2] * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Groupement

enum TransactionGrouping: String, CaseIterable {
    case day   = "Jour"
    case week  = "Semaine"
    case month = "Mois"
}

// MARK: - TransactionsView

struct TransactionsView: View {
    @Environment(AppState.self) private var appState
    private let repository = TransactionRepository()

    // Données
    @State private var transactions: [FinanceTransaction] = []
    @State private var accounts: [Account] = []
    @State private var allTiers: [Tiers] = []
    @State private var allCategories: [Category] = []
    @State private var allMdps: [PaymentType] = []
    @State private var allTags: [Tag] = []

    // Lazy loading — `isLoading = true` au boot pour afficher le skeleton dès le 1er rendu.
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = true
    private let pageSize = 100

    // Sélection
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int> = []
    @State private var showDeleteConfirmation = false
    @State private var showBulkRemboursementPicker = false
    @State private var showBulkTagPicker = false
    @State private var showBulkCategoryPicker = false
    @State private var bulkTagInitialStates: [Int: TagSelectionState] = [:]

    // Édition
    /// Transaction sélectionnée : iOS → sheet d'édition directe ; macOS →
    /// panneau détail (Modifier/Supprimer) puis édition (adaptiveEntityPane).
    @State private var selectedTransaction: FinanceTransaction? = nil
    @State private var quickCategoryTx: FinanceTransaction? = nil
    @State private var tagQuickTx: FinanceTransaction? = nil
    @State private var txToDelete: FinanceTransaction? = nil

    // Remboursements
    @State private var showReimbursements = false
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true
    @State private var showTagSummary = false

    // Tips
    private let filterTip = TransactionFilterTip()
    private let multiSelectTip = MultiSelectTip()
    private let tagsTip = TagsTip()

    // Analyse filtrée
    @State private var showFilteredDashboard = false

    // Ajout manuel
    @State private var showAddTransaction = false

    // Tricount links (#5)
    private let tricountRepo = TricountRepository()
    @State private var linkedTricountTxIds: Set<Int> = []
    @State private var tricountDetailGroup: TricountGroup? = nil
    @State private var tricountDetailEntryId: Int? = nil

    // Tags par transaction
    @State private var txTags: [Int: [Tag]] = [:]

    // Soldes (#6)
    @State private var accountBalance: Double = 0
    @State private var uncategorizedCount: Int = 0

    // Filtres & affichage
    @State private var showFilters = false
    @State private var tiersSearchText = ""
    @State private var selectedCategoryId = -1
    @State private var filterTagIds: Set<Int> = []
    @State private var tagFilteredTxIds: Set<Int>? = nil  // nil = pas de filtre tag actif
    @State private var grouping: TransactionGrouping = .day

    // MARK: Computed

    /// `true` quand l'utilisateur a choisi le sentinel "Tous les comptes" (id = 0) dans
    /// le picker. Modifie l'UX : solde compte + balance courante par ligne masqués
    /// (incohérents inter-comptes) et chip compte affiché sur chaque row pour
    /// distinguer la provenance.
    private var isAllAccountsMode: Bool {
        (appState.selectedAccountId ?? 0) == 0
    }

    /// Lookup O(1) pour afficher le nom du compte sur chaque row en mode "Tous".
    private var accountsById: [Int: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    private var activeFiltersCount: Int {
        (tiersSearchText.isEmpty ? 0 : 1)
        + (selectedCategoryId == -1 ? 0 : 1)
        + (filterTagIds.isEmpty ? 0 : 1)
    }

    private var filteredTransactions: [FinanceTransaction] {
        transactions.filter { tx in
            let tiersMatch = tiersSearchText.isEmpty
                || tx.tiersName.localizedCaseInsensitiveContains(tiersSearchText)
                || tx.information.localizedCaseInsensitiveContains(tiersSearchText)
            let catMatch = selectedCategoryId == -1
                || (selectedCategoryId == -2 ? tx.categoryId == nil : tx.categoryId == selectedCategoryId)
            let tagMatch = tagFilteredTxIds.map { $0.contains(tx.id) } ?? true
            return tiersMatch && catMatch && tagMatch
        }
    }

    private func groupDate(for tx: FinanceTransaction) -> Date {
        let cal = Calendar.current
        switch grouping {
        case .day:
            return cal.startOfDay(for: tx.date)
        case .week:
            return cal.dateInterval(of: .weekOfYear, for: tx.date)?.start
                ?? cal.startOfDay(for: tx.date)
        case .month:
            var c = cal.dateComponents([.year, .month], from: tx.date)
            c.day = 1
            return cal.date(from: c) ?? cal.startOfDay(for: tx.date)
        }
    }

    private func groupLabel(for date: Date) -> String {
        switch grouping {
        case .day:
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            return "Semaine du \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }

    private var groupedTransactions: [(date: Date, label: String, transactions: [FinanceTransaction])] {
        Dictionary(grouping: filteredTransactions) { groupDate(for: $0) }
            .sorted { $0.key > $1.key }
            .map { (date, txs) in
                (date: date, label: groupLabel(for: date), transactions: txs)
            }
    }

    /// Solde du compte après chaque transaction (sans requête SQL supplémentaire).
    /// Calculé en partant de accountBalance (solde à la fin de la période) et en remontant
    /// du plus récent au plus ancien. Vide si des filtres actifs rendent les données incomplètes
    /// ou si on est en mode "Tous les comptes" (running balance n'a aucun sens inter-comptes).
    private var txBalances: [Int: Double] {
        guard activeFiltersCount == 0, !isAllAccountsMode else { return [:] }
        var result: [Int: Double] = [:]
        var running = accountBalance
        for tx in transactions { // trié du plus récent au plus ancien
            result[tx.id] = running
            running -= tx.amount
        }
        return result
    }

    // MARK: Body

    var isEmbedded: Bool = false

    var body: some View {
        if isEmbedded { navBody } else { NavigationStack { navBody } }
    }

    @ViewBuilder private var navBody: some View {
        Group {
                if isLoading {
                    transactionsSkeleton
                } else if transactions.isEmpty {
                    ContentUnavailableView(
                        "Aucune transaction",
                        systemImage: "tray",
                        description: Text("Vérifiez que le compte selectionné et la plage de temps correspondent. Sinon commencez par ajouter vos transactions ou les importer depuis un fichier sqlite existant ou un fichier csv.")
                    )
                } else if filteredTransactions.isEmpty {
                    ContentUnavailableView(
                        "Aucun résultat",
                        systemImage: "magnifyingglass",
                        description: Text("Aucune transaction ne correspond aux filtres actifs.")
                    )
                } else {
                    List {
                        // ── Soldes (#6) ─────────────────────────────────
                        // En mode "Tous les comptes" on n'affiche QUE la somme période (flux net).
                        // Le "Solde réel" agrège tous les comptes (CB + cash + épargne…) → lecture
                        // trompeuse, on le masque + on libère la largeur pour le flux net + count.
                        let periodBalance = filteredTransactions.reduce(0) { $0 + $1.amount }
                        Section {
                            if isAllAccountsMode {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Flux net période · tous comptes")
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                        Text(periodBalance, format: .currency(code: "EUR"))
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundStyle(periodBalance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                                    }
                                    Spacer()
                                    Image(systemName: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                                .padding(.vertical, 4)
                            } else {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Solde période")
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                        Text(periodBalance, format: .currency(code: "EUR"))
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundStyle(periodBalance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                                    }
                                    Spacer()
                                    Divider().frame(height: 32)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Solde réel")
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                        Text(accountBalance, format: .currency(code: "EUR"))
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundStyle(accountBalance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .macGroupedRow()

                        // ── Avertissement non catégorisé ────────────────
                        if uncategorizedCount > 0 && selectedCategoryId != -2 {
                            Section {
                                Button {
                                    selectedCategoryId = -2
                                    resetAndLoad()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(AppTheme.Colors.warning)
                                            .font(.title3)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(uncategorizedCount) transaction(s) sans catégorie")
                                                .font(.subheadline).fontWeight(.medium)
                                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                            Text("Toucher pour les afficher et catégoriser")
                                                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                            .macGroupedRow()
                        }

                        ForEach(groupedTransactions, id: \.date) { group in
                            Section {
                                ForEach(group.transactions) { item in
                                    transactionRow(item)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if isSelecting { toggleSelection(item.id) }
                                            else { selectedTransaction = item }
                                        }
                                        .rowActions(
                                            leading: isSelecting ? [] : [
                                                RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) {
                                                    selectedTransaction = item
                                                }
                                            ],
                                            trailing: isSelecting ? [] : [
                                                RowAction("Supprimer", systemImage: "trash", role: .destructive) {
                                                    txToDelete = item
                                                },
                                                RowAction("Tags", systemImage: "tag", tint: AppTheme.Colors.accentSecondary) {
                                                    tagQuickTx = item
                                                }
                                            ],
                                            leadingFullSwipe: false,
                                            trailingFullSwipe: false
                                        )
                                        .macGroupedRow(
                                            first: item.id == group.transactions.first?.id,
                                            last: item.id == group.transactions.last?.id
                                        ) {
                                            ZStack(alignment: .leading) {
                                                AppTheme.Colors.surface
                                                if linkedTricountTxIds.contains(item.id) {
                                                    AppTheme.Colors.accentSecondary.opacity(0.08)
                                                    Rectangle()
                                                        .fill(AppTheme.Colors.accentSecondary)
                                                        .frame(width: 3)
                                                }
                                            }
                                        }
                                }
                            } header: {
                                Text(group.label)
                                    .macGroupedSectionHeader()
                            }
                        }

                        // Sentinel pagination
                        if hasMore {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .listRowSeparator(.hidden)
                                .onAppear { loadMore() }
                        } else {
                            Text("\(transactions.count) transaction(s) sur la période")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    #if os(macOS)
                    // macOS : .plain = base neutre pour les cartes custom
                    // dessinées par macGroupedRow (coins arrondis first/last,
                    // inset, séparateurs internes). iOS garde son insetGrouped
                    // natif — macGroupedRow n'y pose que le listRowBackground.
                    .listStyle(.plain)
                    // Décolle la 1ʳᵉ carte de la toolbar (iOS insetGrouped ajoute
                    // cet espace automatiquement, pas `.plain`).
                    .contentMargins(.top, AppTheme.Spacing.md, for: .scrollContent)
                    #endif
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.Colors.background)
                }
            }
            .navigationTitle("Transactions")
            .toolbar {
                // #9 macOS : ne pas émettre d'item .navigation (mapping de
                // navigationBarLeading) — même vide il entre en collision avec le
                // back système + toggle sidebar du NavigationSplitView, d'où la
                // flèche de retour qui "voyage". Sur Mac, "Annuler" rejoint le
                // groupe trailing.
                #if !os(macOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelecting {
                        Button("Annuler") { cancelSelection() }
                    }
                }
                #endif
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelecting {
                        #if os(macOS)
                        Button("Annuler") { cancelSelection() }
                        #endif
                        if !selectedIds.isEmpty {
                            Button {
                                showBulkCategoryPicker = true
                            } label: {
                                Label("Catégorie", systemImage: "folder")
                            }
                            Button {
                                bulkTagInitialStates = computeBulkTagStates()
                                showBulkTagPicker = true
                            } label: {
                                Label("Tags", systemImage: "tag")
                            }
                            if reimbursementsEnabled {
                                Button {
                                    showBulkRemboursementPicker = true
                                } label: {
                                    Label("Remboursement", systemImage: "arrow.uturn.left.circle")
                                }
                            }
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Supprimer (\(selectedIds.count))", systemImage: "trash")
                                    .foregroundStyle(AppTheme.Colors.danger)
                            }
                        }
                    } else {
                        // Ajout manuel
                        Button { showAddTransaction = true } label: {
                            Image(systemName: "plus")
                        }
                        // Bouton filtre (badge si actif)
                        Button { showFilters = true } label: {
                            Image(systemName: activeFiltersCount > 0
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        #if os(macOS)
                        // macOS : la fenêtre a la place — actions secondaires
                        // étalées en boutons icône seule + tooltip natif (.help),
                        // au lieu du menu "⋯" iOS.
                        Button { showFilteredDashboard = true } label: {
                            Image(systemName: "chart.bar.xaxis.ascending")
                        }
                        .help("Analyse filtrée")
                        Button { showTagSummary = true } label: {
                            Image(systemName: "tag.circle")
                        }
                        .help("Dépenses par tag")
                        if reimbursementsEnabled {
                            Button { showReimbursements = true } label: {
                                Image(systemName: "arrow.uturn.left.circle")
                            }
                            .help("Remboursements")
                        }
                        Button { isSelecting = true } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .help("Sélectionner")
                        #else
                        // Menu actions secondaires
                        Menu {
                            Button { showFilteredDashboard = true } label: {
                                Label("Analyse filtrée", systemImage: "chart.bar.xaxis.ascending")
                            }
                            Button { showTagSummary = true } label: {
                                Label("Dépenses par tag", systemImage: "tag.circle")
                            }
                            if reimbursementsEnabled {
                                Button { showReimbursements = true } label: {
                                    Label("Remboursements", systemImage: "arrow.uturn.left.circle")
                                }
                            }
                            Divider()
                            Button { isSelecting = true } label: {
                                Label("Sélectionner", systemImage: "checkmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        #endif
                    }
                }
            }
            .confirmationDialog(
                "Supprimer \(selectedIds.count) transaction(s) ?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) { deleteSelected() }
            }
            .confirmationDialog(
                "Supprimer cette transaction ?",
                isPresented: Binding(get: { txToDelete != nil }, set: { if !$0 { txToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    if let tx = txToDelete {
                        deleteSingle(tx)
                    }
                }
            } message: {
                if let tx = txToDelete {
                    Text("\(tx.tiersName.isEmpty ? tx.information : tx.tiersName) · \(tx.amount.formatted(.currency(code: "EUR")))")
                }
            }
            .adaptivePane(isPresented: $showFilters) {
                TransactionFiltersSheet(
                    accounts: accounts,
                    allCategories: allCategories,
                    allTags: allTags,
                    tiersSearchText: $tiersSearchText,
                    selectedCategoryId: $selectedCategoryId,
                    filterTagIds: $filterTagIds,
                    grouping: $grouping,
                    onApply: {
                        tagFilteredTxIds = filterTagIds.isEmpty
                            ? nil
                            : repository.fetchTransactionIds(havingAnyTagIds: filterTagIds)
                        resetAndLoad()
                    }
                )
                .environment(appState)
            }
            .adaptivePane(item: $quickCategoryTx) { tx in
                CategoryQuickPickSheet(
                    currentCategoryId: tx.categoryId,
                    allCategories: allCategories
                ) { newId, newName in
                    if repository.updateTransactionCategory(id: tx.id, categoryId: newId) {
                        quickUpdateCategory(txId: tx.id, categoryId: newId, categoryName: newName)
                    }
                }
            }
            .adaptiveEntityPane(
                item: $selectedTransaction,
                title: "Transaction",
                refresh: { repository.fetchTransaction(id: $0.id) },
                onDelete: { txToDelete = $0 }
            ) { tx in
                TransactionDetailPane(
                    tx: tx,
                    accounts: accounts,
                    allTiers: allTiers,
                    allCategories: allCategories,
                    repository: repository
                )
            } edit: { tx in
                TransactionEditSheet(
                    draft: TransactionEditDraft(from: tx),
                    allTiers: allTiers,
                    allCategories: allCategories,
                    allMdps: allMdps,
                    allTags: allTags,
                    repository: repository
                ) {
                    resetAndLoad()
                }
            }
            .adaptivePane(item: $tagQuickTx, onDismiss: {
                txTags = repository.fetchTagsForTransactions(transactions.map { $0.id })
            }) { tx in
                TagQuickSheet(transactionId: tx.id, allTags: allTags, repository: repository) { newTag in
                    // Rafraîchit la liste des tags dispo si un nouveau tag a été créé
                    if !allTags.contains(where: { $0.id == newTag.id }) {
                        allTags.append(newTag)
                        allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                }
            }
            .adaptivePane(isPresented: $showAddTransaction) {
                // Si l'user est en mode "Tous" (selectedAccountId == 0), on retombe
                // sur le premier compte disponible pour l'ajout manuel (impossible
                // d'imputer une transaction au sentinel "Tous").
                AddTransactionSheet(
                    accounts: accounts,
                    defaultAccountId: {
                        let sel = appState.selectedAccountId ?? 0
                        return sel == 0 ? (accounts.first?.id ?? 0) : sel
                    }(),
                    allTiers: allTiers,
                    allCategories: allCategories,
                    allMdps: allMdps,
                    repository: repository,
                    onSave: { resetAndLoad() }
                )
            }
            .adaptivePane(isPresented: $showTagSummary) {
                TagSummaryView(repository: repository)
            }
            .adaptivePane(isPresented: $showFilteredDashboard) {
                FilteredDashboardView(filter: buildFilter())
            }
            .adaptivePane(isPresented: $showReimbursements) {
                ReimbursementsSheet(repository: repository,
                                    initialFrom: appState.filterFromDate,
                                    initialTo: appState.filterToDate)
            }
            // TricountDetailView gère son PROPRE chrome (Fermer/NavigationStack) —
            // niveau 2 ici (nichée dans une vue déjà hébergée), donc sheet, cf.
            // \.paneHostContext dans TricountDetailView.
            .adaptivePane(item: $tricountDetailGroup, onDismiss: { tricountDetailEntryId = nil }) { group in
                TricountDetailView(group: group, initialEntryId: tricountDetailEntryId)
            }
            .adaptivePane(isPresented: $showBulkRemboursementPicker) {
                RemboursementQuickPickSheet(allTiers: allTiers) { tiersId, tiersName in
                    let reimbursementRepo = ReimbursementRepository()
                    let updated = selectedIds.reduce(0) { count, id in
                        reimbursementRepo.setReimbursement(transactionId: id, payeeId: tiersId) ? count + 1 : count
                    }
                    if updated > 0 { quickUpdateRemboursement(ids: selectedIds, tiersId: tiersId, tiersName: tiersName) }
                    cancelSelection()
                }
            }
            .adaptivePane(isPresented: $showBulkCategoryPicker) {
                CategoryQuickPickSheet(
                    currentCategoryId: nil,
                    allCategories: allCategories
                ) { newId, newName in
                    let updated = repository.updateTransactionsCategory(ids: selectedIds, categoryId: newId)
                    if updated > 0 { quickUpdateBulkCategory(ids: selectedIds, categoryId: newId, categoryName: newName) }
                    cancelSelection()
                }
            }
            .adaptivePane(isPresented: $showBulkTagPicker) {
                BulkTagSheet(
                    allTags: allTags,
                    initialStates: bulkTagInitialStates,
                    repository: repository,
                    onSave: { finalStates in
                        applyBulkTagChanges(finalStates: finalStates)
                    },
                    onNewTag: { newTag in
                        if !allTags.contains(where: { $0.id == newTag.id }) {
                            allTags.append(newTag)
                            allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        }
                    }
                )
            }
            .task(id: appState.dataRefreshToken) {
                // 1-frame guard : laisse le skeleton se peindre avant la requête SQLite.
                await Task.yield()
                loadInitialData()
            }
            .refreshable {
                // Pas de skeleton sur pull-to-refresh : l'indicateur système suffit.
                loadInitialData()
            }
    }

    // MARK: Skeleton

    @ViewBuilder private var transactionsSkeleton: some View {
        List {
            // Solde period / réel header
            Section {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        SkeletonLine(width: 80, height: 10)
                        SkeletonLine(width: 90, height: 14)
                    }
                    Spacer()
                    Divider().frame(height: 32)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        SkeletonLine(width: 70, height: 10)
                        SkeletonLine(width: 90, height: 14)
                    }
                }
                .padding(.vertical, 4)
            }
            .macGroupedRow()

            Section {
                ForEach(0..<8, id: \.self) { i in
                    SkeletonTransactionRow()
                        .macGroupedRow(first: i == 0, last: i == 7)
                }
            } header: {
                SkeletonLine(width: 180, height: 13)
                    .padding(.vertical, 2)
                    .macGroupedSectionHeader()
            }
        }
        #if os(macOS)
        // Même base .plain que la liste chargée (cartes macGroupedRow).
        .listStyle(.plain)
        .contentMargins(.top, AppTheme.Spacing.md, for: .scrollContent)
        #endif
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background)
    }

    // MARK: Row

    @ViewBuilder
    private func transactionRow(_ item: FinanceTransaction) -> some View {
        let density = appState.transactionDensity
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIds.contains(item.id) ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            }
            if density.showLogo {
                MerchantLogo(transaction: item, allTiers: allTiers, allCategories: allCategories, size: density.logoSize)
            }
            VStack(alignment: .leading, spacing: density == .compact ? 2 : 5) {
                // Quand y'a pas de description, on centre verticalement le bloc texte
                // (titre + badges) par rapport au logo via Spacer top+bottom + minHeight.
                // Sinon : top alignment naturel (description prend de la place).
                if item.information.isEmpty {
                    Spacer(minLength: 0)
                }
                // Ligne 1 : libellé + montant SEUL (la balance est déplacée en bas
                // pour libérer 13pt sur cette ligne — c'était la balance qui empêchait
                // le bloc texte de tenir dans la hauteur du logo (52pt) et qui faisait
                // que le titre n'était jamais centré.
                HStack(alignment: .firstTextBaseline) {
                    Text(item.tiersName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(item.amount, format: .currency(code: "EUR"))
                        .fontWeight(.bold)
                        .foregroundStyle(item.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                }
                // Ligne 2 : info user (uniquement si remplie — plus de fallback sur libellé brut
                // ou paymentTypeName qui surchargeaient la cellule) + badges + balance courante.
                // En mode compact, on masque toute cette ligne pour avoir un row à 1 ligne.
                if density.showSecondaryInfo {
                HStack(spacing: 6) {
                    if !item.information.isEmpty {
                        Text(item.information)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Badge compte — visible uniquement en mode "Tous les comptes" pour
                    // distinguer la provenance de chaque transaction.
                    if isAllAccountsMode, let acc = accountsById[item.accountId] {
                        Text(acc.name)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.accentSecondary.opacity(0.13), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.accentSecondary)
                    }
                    // Badge remboursement
                    if reimbursementsEnabled && !item.remboursementTiersName.isEmpty {
                        Text("↩ \(item.remboursementTiersName)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.warning.opacity(0.13), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                    // Badge Tricount (lien) — tappable, intégré dans la ligne de badges
                    if !isSelecting && linkedTricountTxIds.contains(item.id) {
                        Button {
                            if let info = repository.fetchLinkedTricountInfo(transactionId: item.id) {
                                tricountDetailEntryId = info.entryId
                                tricountDetailGroup = tricountRepo.fetchGroup(id: info.groupId)
                            }
                        } label: {
                            Image(systemName: "person.2.fill")
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppTheme.Colors.accentSecondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(AppTheme.Colors.accentSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    // Badge catégorie — tappable pour modification rapide
                    let catLabel = item.categoryName.isEmpty ? "Catégorie" : item.categoryName
                    let catColor: Color = item.categoryName.isEmpty ? AppTheme.Colors.textSecondary : AppTheme.Colors.accent
                    let catIconName = allCategories.first(where: { $0.id == item.categoryId })?.displayIcon ?? "tag.fill"
                    Button {
                        quickCategoryTx = item
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: catIconName)
                                .font(.system(size: 9, weight: .semibold))
                            Text(catLabel)
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(catColor.opacity(0.13), in: Capsule())
                        .foregroundStyle(catColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelecting)
                    // Balance courante après la transaction (collée à droite, après les badges)
                    if let bal = txBalances[item.id] {
                        Text(bal, format: .currency(code: "EUR"))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(.leading, 4)
                    }
                }
                }  // end if density.showSecondaryInfo
                // Ligne 3 : tags (uniquement si présents). Aussi masquée en compact.
                let itemTags = density.showSecondaryInfo ? (txTags[item.id] ?? []) : []
                if !itemTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(itemTags) { tag in
                                Text(tag.name)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(tag.displayColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(tag.displayColor)
                            }
                        }
                    }
                }
                // Note : libelle_brut et paymentTypeName sont disponibles dans la sheet
                // d'édition de la transaction (TransactionEditSheet) — pas besoin de les
                // dupliquer dans chaque row de la liste.
                if item.information.isEmpty {
                    Spacer(minLength: 0)
                }
            }
            // minHeight pilotée par la densité — permet aux Spacer(minLength: 0)
            // de centrer verticalement le bloc texte par rapport au logo quand la
            // description est vide.
            .frame(minHeight: density.rowMinHeight)
        }
        .padding(.vertical, density.verticalPadding)
    }

    // MARK: Chargement

    private func loadInitialData() {
        accounts      = repository.fetchAccounts()
        allTiers      = repository.fetchTiers()
        allCategories = repository.fetchCategories()
        allMdps       = repository.fetchPaymentTypes()
        allTags       = repository.fetchAllTags()
        linkedTricountTxIds = repository.fetchLinkedTransactionIds()

        if appState.selectedAccountId == nil {
            // Utilise le compte par défaut si défini et présent dans la liste, sinon premier compte
            let preferred = appState.defaultAccountId
            let target = (preferred > 0 && accounts.contains(where: { $0.id == preferred }))
                ? accounts.first(where: { $0.id == preferred })
                : accounts.first
            if let a = target {
                appState.selectedAccountId   = a.id
                appState.selectedAccountName = a.name
            }
        } else if let accountId = appState.selectedAccountId, appState.selectedAccountName.isEmpty {
            appState.selectedAccountName = accounts.first(where: { $0.id == accountId })?.name ?? ""
        }
        resetAndLoad()
    }

    private func resetAndLoad() {
        // `accountId == 0` est le sentinel "Tous les comptes" → on le passe tel quel au
        // repository qui retire la clause WHERE account_id correspondante.
        let accountId = appState.selectedAccountId ?? 0
        isLoading    = true
        transactions = []
        hasMore      = true

        let hasActiveFilters = !tiersSearchText.isEmpty || selectedCategoryId != -1 || tagFilteredTxIds != nil

        if hasActiveFilters {
            // Filtres actifs : on charge TOUTES les transactions correspondantes en SQL
            // pour ne pas limiter la recherche aux 100 premières lignes paginées.
            let loaded = repository.fetchAllFilteredTransactions(filter: buildFilter())
            transactions = loaded.reversed()  // fetchAllFilteredTransactions renvoie ASC → on inverse en DESC
            hasMore = false
        } else {
            let page = repository.fetchTransactions(
                accountId: accountId,
                from: appState.filterFromDate,
                to: appState.filterToDate,
                limit: pageSize,
                offset: 0
            )
            transactions = page
            hasMore      = page.count == pageSize
        }

        isLoading = false
        txTags    = repository.fetchTagsForTransactions(transactions.map { $0.id })
        accountBalance    = repository.fetchAccountBalance(accountId: accountId, upToDate: appState.filterToDate)
        uncategorizedCount = repository.fetchUncategorizedCount(accountId: accountId, from: appState.filterFromDate, to: appState.filterToDate)
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore else { return }
        let accountId = appState.selectedAccountId ?? 0
        isLoadingMore = true

        let page = repository.fetchTransactions(
            accountId: accountId,
            from: appState.filterFromDate,
            to: appState.filterToDate,
            limit: pageSize,
            offset: transactions.count
        )
        transactions.append(contentsOf: page)
        hasMore       = page.count == pageSize
        isLoadingMore = false
        let newTags = repository.fetchTagsForTransactions(page.map { $0.id })
        txTags.merge(newTags) { _, new in new }
    }

    // MARK: Sélection

    private func toggleSelection(_ id: Int) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    private func cancelSelection() {
        isSelecting = false
        selectedIds.removeAll()
    }

    // MARK: Catégorie rapide

    private func quickUpdateBulkCategory(ids: Set<Int>, categoryId: Int?, categoryName: String) {
        for idx in transactions.indices where ids.contains(transactions[idx].id) {
            quickUpdateCategory(txId: transactions[idx].id, categoryId: categoryId, categoryName: categoryName)
        }
    }

    private func quickUpdateCategory(txId: Int, categoryId: Int?, categoryName: String) {
        guard let idx = transactions.firstIndex(where: { $0.id == txId }) else { return }
        let tx = transactions[idx]
        transactions[idx] = FinanceTransaction(
            id: tx.id, accountId: tx.accountId,
            tiersId: tx.tiersId, categoryId: categoryId, paymentTypeId: tx.paymentTypeId,
            remboursementTiersId: tx.remboursementTiersId,
            tiersName: tx.tiersName, categoryName: categoryName, paymentTypeName: tx.paymentTypeName,
            remboursementTiersName: tx.remboursementTiersName,
            information: tx.information, libelleBrut: tx.libelleBrut, amount: tx.amount, date: tx.date
        )
    }

    private func quickUpdateRemboursement(ids: Set<Int>, tiersId: Int?, tiersName: String) {
        for idx in transactions.indices where ids.contains(transactions[idx].id) {
            let tx = transactions[idx]
            transactions[idx] = FinanceTransaction(
                id: tx.id, accountId: tx.accountId,
                tiersId: tx.tiersId, categoryId: tx.categoryId, paymentTypeId: tx.paymentTypeId,
                remboursementTiersId: tiersId,
                tiersName: tx.tiersName, categoryName: tx.categoryName, paymentTypeName: tx.paymentTypeName,
                remboursementTiersName: tiersName,
                information: tx.information, libelleBrut: tx.libelleBrut, amount: tx.amount, date: tx.date
            )
        }
    }

    // MARK: Analyse filtrée

    private func buildFilter() -> TransactionFilter {
        let categoryName: String
        if selectedCategoryId == -1 {
            categoryName = ""
        } else if selectedCategoryId == -2 {
            categoryName = "Non catégorisé"
        } else {
            categoryName = allCategories.first(where: { $0.id == selectedCategoryId })?.name ?? ""
        }
        let tagNames = allTags
            .filter { filterTagIds.contains($0.id) }
            .map { $0.name }

        return TransactionFilter(
            accountId: appState.selectedAccountId ?? 0,
            accountName: appState.selectedAccountName,
            from: appState.filterFromDate,
            to: appState.filterToDate,
            tiersSearchText: tiersSearchText,
            categoryId: selectedCategoryId,
            categoryName: categoryName,
            tagNames: tagNames,
            tagFilteredTxIds: tagFilteredTxIds
        )
    }

    // MARK: Suppression

    private func deleteSelected() {
        let count = repository.deleteTransactions(ids: selectedIds)
        if count > 0 {
            transactions.removeAll { selectedIds.contains($0.id) }
        }
        cancelSelection()
    }

    private func deleteSingle(_ tx: FinanceTransaction) {
        if repository.deleteTransaction(id: tx.id) {
            transactions.removeAll { $0.id == tx.id }
            txTags.removeValue(forKey: tx.id)
        }
        txToDelete = nil
    }

    // MARK: Tags en masse (tri-state)

    private func computeBulkTagStates() -> [Int: TagSelectionState] {
        var result: [Int: TagSelectionState] = [:]
        for tag in allTags {
            let count = selectedIds.filter { txTags[$0]?.contains(where: { $0.id == tag.id }) ?? false }.count
            if count == 0 { result[tag.id] = TagSelectionState.none }
            else if count == selectedIds.count { result[tag.id] = .all }
            else { result[tag.id] = .some }
        }
        return result
    }

    private func applyBulkTagChanges(finalStates: [Int: TagSelectionState]) {
        for txId in selectedIds {
            var existing = Set(repository.fetchTags(forTransaction: txId).map(\.id))
            for (tagId, state) in finalStates {
                switch state {
                case .all:  existing.insert(tagId)
                case .none: existing.remove(tagId)
                case .some: break
                }
            }
            repository.setTags(Array(existing), forTransaction: txId)
        }
        txTags = repository.fetchTagsForTransactions(transactions.map { $0.id })
        cancelSelection()
    }
}

// MARK: - Filtre sheet

struct TransactionFiltersSheet: View {
    @Environment(AppState.self) private var appState
    // Fermeture via le panneau adaptatif (inspector macOS / sheet iOS), cf. AdaptivePane.
    @Environment(\.paneDismiss) private var paneDismiss

    let accounts: [Account]
    let allCategories: [Category]
    let allTags: [Tag]
    @Binding var tiersSearchText: String
    @Binding var selectedCategoryId: Int
    @Binding var filterTagIds: Set<Int>
    @Binding var grouping: TransactionGrouping
    let onApply: () -> Void

    // Local copies to avoid re-rendering parent on every keystroke
    @State private var localTiersSearch: String = ""

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Form {
                Section {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible").foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Picker("Compte", selection: Binding(
                            get: { appState.selectedAccountId ?? accounts.first?.id ?? 0 },
                            set: { newValue in
                                appState.selectedAccountId = newValue
                                if newValue == 0 {
                                    appState.selectedAccountName = "Tous les comptes"
                                } else {
                                    appState.selectedAccountName = accounts.first(where: { $0.id == newValue })?.name ?? "Compte"
                                }
                            }
                        )) {
                            // Sentinel : tag 0 = tous les comptes confondus.
                            // Aucun account.id ne vaut 0 (AUTOINCREMENT démarre à 1).
                            Label("Tous les comptes", systemImage: "rectangle.stack.fill").tag(0)
                            ForEach(accounts.groupedByType, id: \.type) { group in
                                Section(group.type.label) {
                                    ForEach(group.accounts) { a in Text(a.name).tag(a.id) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Compte")
                } footer: {
                    if (appState.selectedAccountId ?? 0) == 0 {
                        Text("Mode tous comptes : les transactions de tous les comptes sont mélangées. Le solde réel est masqué (incohérent inter-comptes) ; seul le flux net de la période est affiché.")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Section("Période") {
                    DatePicker("Du", selection: $appState.filterFromDate, displayedComponents: .date)
                    DatePicker("Au", selection: $appState.filterToDate, displayedComponents: .date)
                }

                Section("Recherche") {
                    TextField("Filtrer par tiers ou libellé…", text: $localTiersSearch)
                        .autocorrectionDisabled()

                    Picker("Catégorie", selection: $selectedCategoryId) {
                        Text("Toutes").tag(-1)
                        Text("Non catégorisé").tag(-2)
                        ForEach(allCategories) { c in Text(c.name).tag(c.id) }
                    }
                }

                if !allTags.isEmpty {
                    Section {
                        if filterTagIds.isEmpty {
                            Text("Tous les tags").foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            // Chips des tags sélectionnés
                            TagChipsRow(
                                tags: allTags.filter { filterTagIds.contains($0.id) },
                                onRemove: { filterTagIds.remove($0) }
                            )
                        }
                        // Liste toggleable
                        ForEach(allTags) { tag in
                            Button {
                                if filterTagIds.contains(tag.id) { filterTagIds.remove(tag.id) }
                                else { filterTagIds.insert(tag.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: filterTagIds.contains(tag.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(filterTagIds.contains(tag.id) ? AppTheme.Colors.accentSecondary : AppTheme.Colors.textSecondary)
                                    Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Tags")
                            Spacer()
                            if !filterTagIds.isEmpty {
                                Button("Effacer") { filterTagIds.removeAll() }
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                            }
                        }
                    }
                }

                Section {
                    Picker("Grouper par", selection: $grouping) {
                        ForEach(TransactionGrouping.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Picker de densité — 3 paliers (compact / normal / confortable).
                    // Tap haptique pour confirmer le changement.
                    Picker(selection: Binding(
                        get: { appState.transactionDensity },
                        set: { newValue in
                            appState.transactionDensity = newValue
                            HapticService.shared.selection()
                        }
                    )) {
                        ForEach(TransactionDensity.allCases) { d in
                            Label(d.label, systemImage: d.systemIcon).tag(d)
                        }
                    } label: {
                        Text("Densité")
                    }
                    Text(appState.transactionDensity.description)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: {
                    Text("Affichage")
                }

                Section {
                    Button("Réinitialiser les filtres") {
                        localTiersSearch   = ""
                        tiersSearchText    = ""
                        selectedCategoryId = -1
                        filterTagIds       = []
                    }
                    .foregroundStyle(AppTheme.Colors.danger)
                }
            }
            .nemorisFormStyle()
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { localTiersSearch = tiersSearchText }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { paneDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer") {
                        tiersSearchText = localTiersSearch
                        onApply()
                        paneDismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Tag chips (filtres actifs)

private struct TagChipsRow: View {
    let tags: [Tag]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption).fontWeight(.semibold)
                        Button { onRemove(tag.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AppTheme.Colors.accentSecondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                }
            }
        }
    }
}

// MARK: - Sélection rapide de catégorie

struct CategoryQuickPickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let currentCategoryId: Int?
    let allCategories: [Category]
    let onSelect: (Int?, String) -> Void

    @State private var search = ""

    var filtered: [Category] {
        guard !search.isEmpty else { return allCategories }
        return allCategories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
            List {
                Button("Aucune catégorie") {
                    onSelect(nil, ""); dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(filtered) { c in
                    Button {
                        onSelect(c.id, c.name); dismiss()
                    } label: {
                        HStack {
                            Text(c.name).foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if c.id == currentCategoryId {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher une catégorie…")
            .paneChrome("Catégorie", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}

// MARK: - Sélection rapide de remboursement (masse)

struct RemboursementQuickPickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let allTiers: [Tiers]
    let onSelect: (Int?, String) -> Void

    @State private var search = ""

    var filtered: [Tiers] {
        guard !search.isEmpty else { return allTiers }
        return allTiers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
            List {
                Button("Aucun remboursement") {
                    onSelect(nil, ""); dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(filtered) { t in
                    Button {
                        onSelect(t.id, t.name); dismiss()
                    } label: {
                        Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tiers…")
            .paneChrome("Remboursement par", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}

// MARK: - Recherche tiers (édition)

struct TiersSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let allTiers: [Tiers]
    @Binding var selectedId: Int
    /// Optional: called with the current search text when "+" is tapped. Parent opens a create form.
    var onCreateTiers: ((String) -> Void)? = nil

    @State private var search = ""

    var filtered: [Tiers] {
        guard !search.isEmpty else { return allTiers }
        return allTiers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button("Aucun") {
                    selectedId = -1
                    dismiss()
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(filtered) { t in
                    Button {
                        selectedId = t.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                if let r = t.regex, !r.isEmpty {
                                    Text(r).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                            Spacer()
                            if selectedId == t.id {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tiers…")
            .navigationTitle("Choisir un tiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                if let onCreateTiers {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            let prefill = search.trimmingCharacters(in: .whitespaces)
                            dismiss()
                            // Small delay so dismiss completes before parent opens next sheet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onCreateTiers(prefill)
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Formulaire création tiers (brouillon, sans écriture DB)

struct NewTiersFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prefilledName: String
    let prefilledRegex: String
    let allCategories: [Category]
    let onCreate: (String, String, Int?) -> Void  // name, regex, categoryId

    @State private var name: String
    @State private var regex: String
    @State private var categoryId: Int?

    init(prefilledName: String, prefilledRegex: String = "", allCategories: [Category],
         onCreate: @escaping (String, String, Int?) -> Void) {
        self.prefilledName = prefilledName
        self.prefilledRegex = prefilledRegex
        self.allCategories = allCategories
        self.onCreate = onCreate
        _name = State(initialValue: prefilledName)
        _regex = State(initialValue: prefilledRegex)
        _categoryId = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom", text: $name).autocorrectionDisabled()
                }
                Section("Regex de détection (optionnel)") {
                    TextEditor(text: $regex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
                Section("Catégorie par défaut") {
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Non catégorisé").tag(Int?.none)
                        ForEach(allCategories) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .nemorisFormStyle()
            .navigationTitle("Nouveau tiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirmer") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        onCreate(n, regex.trimmingCharacters(in: .whitespaces), categoryId)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Édition transaction

struct TransactionEditSheet: View {
    // Rebind sur paneDismiss (inspector macOS / sheet iOS) — dismiss() reste valide.
    @Environment(\.paneDismiss) private var dismiss

    let draft: TransactionEditDraft
    let allCategories: [Category]
    let allMdps: [PaymentType]
    let allTags: [Tag]
    let repository: TransactionRepository
    let onSave: () -> Void

    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    @State private var localTiers: [Tiers]
    @State private var tiersId: Int
    @State private var categoryId: Int
    @State private var paymentTypeId: Int
    @State private var remboursementTiersId: Int
    @State private var information: String
    @State private var amountText: String
    @State private var type: TransactionTypePicker
    @State private var date: Date
    @State private var selectedTagIds: Set<Int> = []
    @State private var showTiersPicker = false
    @State private var showRemboursementPicker = false
    @State private var showCreateTiersForm = false
    @State private var showTagPicker = false
    @State private var newTiersPrefillName = ""
    @State private var localAllTags: [Tag]

    init(draft: TransactionEditDraft, allTiers: [Tiers], allCategories: [Category],
         allMdps: [PaymentType], allTags: [Tag], repository: TransactionRepository, onSave: @escaping () -> Void) {
        self.draft          = draft
        self.allCategories  = allCategories
        self.allMdps        = allMdps
        self.allTags        = allTags
        self.repository     = repository
        self.onSave         = onSave
        _localTiers             = State(initialValue: allTiers)
        _localAllTags           = State(initialValue: allTags)
        _tiersId                = State(initialValue: draft.tiersId ?? -1)
        _categoryId             = State(initialValue: draft.categoryId ?? -1)
        _paymentTypeId          = State(initialValue: draft.paymentTypeId ?? -1)
        _remboursementTiersId   = State(initialValue: draft.remboursementTiersId ?? -1)
        _information            = State(initialValue: draft.information)
        _amountText             = State(initialValue: String(abs(draft.amount)))
        _date                   = State(initialValue: draft.date)
        _type                   = State(initialValue: draft.type)
    }

    private var tiersDisplayName: String {
        guard tiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == tiersId })?.name ?? "Inconnu"
    }

    private var remboursementDisplayName: String {
        guard remboursementTiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == remboursementTiersId })?.name ?? "Inconnu"
    }

    var body: some View {
            Form {
                Section("Détails") {
                    TextField("Description", text: $information)
                    if let brut = draft.libelleBrut, !brut.isEmpty {
                        LabeledContent("Libellé bancaire") {
                            Text(brut)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .font(.footnote)
                        }
                    }
                    HStack {
                        Text("Montant")
                        Spacer()
                        Button {
                            type = (type == .expense) ? .income : .expense
                        } label: {
                            Text(type == .expense ? "−" : "+")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(type == .expense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(type == .expense ? AppTheme.Colors.danger.opacity(0.12) : AppTheme.Colors.success.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Classification") {
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(tiersDisplayName).foregroundStyle(AppTheme.Colors.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }

                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(-1)
                        ForEach(allCategories) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(c.id)
                        }
                    }
                    Picker("Moyen de paiement", selection: $paymentTypeId) {
                        Text("Aucun").tag(-1)
                        ForEach(allMdps) { m in Text(m.name).tag(m.id) }
                    }
                }

                if reimbursementsEnabled {
                    Section("Remboursement") {
                        Button {
                            showRemboursementPicker = true
                        } label: {
                            HStack {
                                Text("Remboursé par").foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                Text(remboursementDisplayName)
                                    .foregroundStyle(remboursementTiersId == -1 ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            }
                        }
                    }
                }

                Section("Tags") {
                    Button {
                        showTagPicker = true
                    } label: {
                        HStack {
                            Label("Tags", systemImage: "tag").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if selectedTagIds.isEmpty {
                                Text("Aucun").foregroundStyle(AppTheme.Colors.textSecondary)
                            } else {
                                // Afficher les noms des tags sélectionnés
                                Text(localAllTags.filter { selectedTagIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear {
                selectedTagIds = Set(repository.fetchTags(forTransaction: draft.id).map(\.id))
            }
            .adaptivePane(isPresented: $showTagPicker) {
                TagPickerSheet(allTags: $localAllTags, selectedTagIds: $selectedTagIds, repository: repository)
            }
            .adaptivePane(isPresented: $showTiersPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $tiersId,
                                 onCreateTiers: { prefill in
                                     newTiersPrefillName = prefill
                                     showCreateTiersForm = true
                                 })
            }
            .adaptivePane(isPresented: $showRemboursementPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $remboursementTiersId)
            }
            .adaptivePane(isPresented: $showCreateTiersForm) {
                PayeeCreationFormSheet(prefilledName: newTiersPrefillName, allCategories: allCategories) { newTiers in
                    // Insert le tiers minimal puis updatePayeeFull pour tous les champs
                    guard let id = repository.addTiersAndGetId(
                        name: newTiers.name,
                        regex: newTiers.regex ?? "",
                        categoryId: newTiers.categoryId
                    ) else { return }
                    var fullTiers = newTiers
                    fullTiers = Tiers(
                        id: id, name: newTiers.name, regex: newTiers.regex,
                        categoryId: newTiers.categoryId, linkedCompteId: newTiers.linkedCompteId,
                        engineMerchantId: newTiers.engineMerchantId, domain: newTiers.domain,
                        address: newTiers.address, city: newTiers.city, country: newTiers.country,
                        groupId: newTiers.groupId, custom: newTiers.custom, note: newTiers.note,
                        tierType: newTiers.tierType, contactIdentifier: newTiers.contactIdentifier
                    )
                    repository.updatePayeeFull(fullTiers)
                    localTiers.append(fullTiers)
                    localTiers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    tiersId = id
                    if categoryId == -1 {
                        categoryId = newTiers.categoryId ?? -1
                    }
                }
            }
            .paneChrome("Modifier la transaction",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", onConfirm: { save() })
    }

    private func save() {
        let absValue = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? abs(draft.amount)
        let amount = type == .expense ? -absValue : absValue
        var updated = draft
        updated.tiersId             = tiersId == -1 ? nil : tiersId
        updated.categoryId          = categoryId == -1 ? nil : categoryId
        updated.paymentTypeId       = paymentTypeId == -1 ? nil : paymentTypeId
        updated.remboursementTiersId = remboursementTiersId == -1 ? nil : remboursementTiersId
        updated.information         = information
        updated.amount              = amount
        updated.date                = date
        repository.updateTransaction(updated)
        ReimbursementRepository().setReimbursement(transactionId: draft.id, payeeId: updated.remboursementTiersId)
        repository.setTags(Array(selectedTagIds), forTransaction: draft.id)
        onSave()
        dismiss()
    }
}

// MARK: - Ajout manuel de transaction

struct AddTransactionSheet: View {
    // Rebind sur paneDismiss (inspector macOS / sheet iOS) — dismiss() reste valide.
    @Environment(\.paneDismiss) private var dismiss

    let accounts: [Account]
    let allCategories: [Category]
    let allMdps: [PaymentType]
    let repository: TransactionRepository
    let onSave: () -> Void

    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    @State private var localTiers: [Tiers]
    @State private var accountId: Int
    @State private var tiersId: Int = -1
    @State private var categoryId: Int = -1
    @State private var paymentTypeId: Int = -1
    @State private var remboursementTiersId: Int = -1
    @State private var information: String = ""
    @State private var amountText: String = ""
    @State private var type: TransactionTypePicker = .expense
    @State private var date: Date = Date()
    @State private var showTiersPicker = false
    @State private var showRemboursementPicker = false
    @State private var showCreateTiersForm = false
    @State private var newTiersPrefillName = ""
    @State private var errorMessage: String? = nil

    init(accounts: [Account], defaultAccountId: Int, allTiers: [Tiers],
         allCategories: [Category], allMdps: [PaymentType],
         repository: TransactionRepository, onSave: @escaping () -> Void) {
        self.accounts = accounts
        self.allCategories = allCategories
        self.allMdps = allMdps
        self.repository = repository
        self.onSave = onSave
        _localTiers = State(initialValue: allTiers)
        _accountId = State(initialValue: defaultAccountId)
    }

    private var tiersDisplayName: String {
        guard tiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == tiersId })?.name ?? "Inconnu"
    }
    private var remboursementDisplayName: String {
        guard remboursementTiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == remboursementTiersId })?.name ?? "Inconnu"
    }
    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
            Form {
                Section("Compte") {
                    Picker("Compte", selection: $accountId) {
                        ForEach(accounts.groupedByType, id: \.type) { group in
                            Section(group.type.label) {
                                ForEach(group.accounts) { a in Text(a.name).tag(a.id) }
                            }
                        }
                    }
                }

                Section("Détails") {
                    HStack {
                        Text("Montant")
                        Spacer()
                        Button {
                            type = (type == .expense) ? .income : .expense
                        } label: {
                            Text(type == .expense ? "−" : "+")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(type == .expense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(type == .expense ? AppTheme.Colors.danger.opacity(0.12) : AppTheme.Colors.success.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Information / description", text: $information)
                }

                Section("Classification") {
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(tiersDisplayName).foregroundStyle(AppTheme.Colors.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(-1)
                        ForEach(allCategories) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(c.id)
                        }
                    }
                    Picker("Moyen de paiement", selection: $paymentTypeId) {
                        Text("Aucun").tag(-1)
                        ForEach(allMdps) { m in Text(m.name).tag(m.id) }
                    }
                }

                if reimbursementsEnabled {
                    Section("Remboursement") {
                        Button {
                            showRemboursementPicker = true
                        } label: {
                            HStack {
                                Text("Remboursé par").foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                Text(remboursementDisplayName)
                                    .foregroundStyle(remboursementTiersId == -1 ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            }
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(AppTheme.Colors.danger).font(.caption)
                    }
                }
            }
            .nemorisFormStyle()
            .adaptivePane(isPresented: $showTiersPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $tiersId,
                                 onCreateTiers: { prefill in
                                     newTiersPrefillName = prefill
                                     showCreateTiersForm = true
                                 })
            }
            .adaptivePane(isPresented: $showRemboursementPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $remboursementTiersId)
            }
            .adaptivePane(isPresented: $showCreateTiersForm) {
                PayeeCreationFormSheet(prefilledName: newTiersPrefillName, allCategories: allCategories) { newTiers in
                    guard let id = repository.addTiersAndGetId(
                        name: newTiers.name,
                        regex: newTiers.regex ?? "",
                        categoryId: newTiers.categoryId
                    ) else { return }
                    var fullTiers = Tiers(
                        id: id, name: newTiers.name, regex: newTiers.regex,
                        categoryId: newTiers.categoryId, linkedCompteId: newTiers.linkedCompteId,
                        engineMerchantId: newTiers.engineMerchantId, domain: newTiers.domain,
                        address: newTiers.address, city: newTiers.city, country: newTiers.country,
                        groupId: newTiers.groupId, custom: newTiers.custom, note: newTiers.note,
                        tierType: newTiers.tierType, contactIdentifier: newTiers.contactIdentifier
                    )
                    repository.updatePayeeFull(fullTiers)
                    localTiers.append(fullTiers)
                    localTiers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    tiersId = id
                    if categoryId == -1 {
                        categoryId = newTiers.categoryId ?? -1
                    }
                }
            }
            .onChange(of: tiersId) { _, newId in
                guard newId != -1, categoryId == -1 else { return }
                if let tiers = localTiers.first(where: { $0.id == newId }) {
                    categoryId = tiers.categoryId ?? -1
                }
            }
            .paneChrome("Nouvelle transaction",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Ajouter",
                        confirmDisabled: parsedAmount == nil || amountText.isEmpty,
                        onConfirm: { save() })
    }

    private func save() {
        guard let absValue = parsedAmount else { return }
        let amount = type == .expense ? -abs(absValue) : abs(absValue)
        let newId = repository.addTransaction(
            accountId: accountId,
            tiersId: tiersId == -1 ? nil : tiersId,
            categoryId: categoryId == -1 ? nil : categoryId,
            paymentTypeId: paymentTypeId == -1 ? nil : paymentTypeId,
            information: information,
            amount: amount,
            date: date
        )
        if let newId {
            if remboursementTiersId != -1 {
                ReimbursementRepository().setReimbursement(transactionId: newId, payeeId: remboursementTiersId)
            }
            onSave()
            dismiss()
        } else {
            errorMessage = "Impossible d'enregistrer la transaction."
        }
    }
}

// MARK: - Vue remboursements

struct ReimbursementsSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss
    let repository: TransactionRepository
    private let reimbursementRepo = ReimbursementRepository()

    @State private var fromDate: Date
    @State private var toDate: Date
    @State private var groups: [ReimbursementGroup] = []
    @State private var expandedIds: Set<Int> = []
    /// Groupement TOUJOURS par payee — ce toggle ne fait que sous-détailler les
    /// items D'UN MÊME payee par catégorie, il ne remplace pas le groupement.
    @State private var detailByCategory = false
    /// Disclosure des sous-groupes catégorie, repliés par défaut. Clé composite
    /// "payeeId|categoryId" : un même categoryId peut apparaître sous plusieurs
    /// payees (ex. "Alimentation" chez Papa ET chez Maman) — un Set<Int> seul
    /// ferait coïncider à tort leurs états d'expansion.
    @State private var expandedCategoryKeys: Set<String> = []

    init(repository: TransactionRepository, initialFrom: Date, initialTo: Date) {
        self.repository = repository
        _fromDate = State(initialValue: initialFrom)
        _toDate   = State(initialValue: initialTo)
    }

    private var isEmpty: Bool { groups.isEmpty }
    private var grandTotal: Double { groups.reduce(0) { $0 + $1.total } }

    var body: some View {
            // Form (pas List) : contenu type formulaire → boxes arrondies
            // natives macOS via nemorisFormStyle(), insetGrouped natif sur iOS.
            Form {
                // Période
                Section("Période") {
                    DatePicker("Du", selection: $fromDate, displayedComponents: .date)
                    DatePicker("Au", selection: $toDate, displayedComponents: .date)
                    Button("Appliquer") { load() }
                        .frame(maxWidth: .infinity)
                }

                if !isEmpty {
                    Section {
                        Toggle("Détailler par catégorie", isOn: $detailByCategory)
                    }
                }

                if isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Aucun remboursement",
                            systemImage: "arrow.uturn.left.circle",
                            description: Text("Aucune transaction avec remboursement sur cette période.")
                        )
                    }
                } else {
                    // Total global
                    Section {
                        HStack {
                            Text("Total à recevoir").fontWeight(.semibold)
                            Spacer()
                            Text(grandTotal, format: .currency(code: "EUR"))
                                .fontWeight(.bold)
                                .foregroundStyle(grandTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }

                    // Liste unifiée — toujours groupée par payee
                    ForEach(groups) { group in
                        Section {
                            groupHeader(id: group.id, title: group.payeeName, total: group.total,
                                        transactionCount: group.transactionCount, tricountCount: group.tricountCount)
                            if expandedIds.contains(group.id) {
                                if detailByCategory {
                                    ForEach(categorySubgroups(of: group.items)) { sub in
                                        let key = categoryKey(payeeId: group.id, sub: sub)
                                        categorySubheader(sub, isExpanded: expandedCategoryKeys.contains(key)) {
                                            if expandedCategoryKeys.contains(key) { expandedCategoryKeys.remove(key) }
                                            else { expandedCategoryKeys.insert(key) }
                                        }
                                        if expandedCategoryKeys.contains(key) {
                                            ForEach(sub.items) { item in itemRow(item) }
                                        }
                                    }
                                } else {
                                    ForEach(group.items) { item in itemRow(item) }
                                }
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear { load() }
            .paneChrome("Remboursements", cancelLabel: "Fermer", onCancel: { paneDismiss() })
    }

    // MARK: En-tête de groupe (tappable pour expand)

    @ViewBuilder
    private func groupHeader(id: Int, title: String, total: Double, transactionCount: Int, tricountCount: Int) -> some View {
        Button {
            if expandedIds.contains(id) { expandedIds.remove(id) }
            else { expandedIds.insert(id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(AppTheme.Colors.textPrimary)
                    groupSubtitle(transactionCount: transactionCount, tricountCount: tricountCount)
                }
                Spacer()
                Text(total, format: .currency(code: "EUR"))
                    .fontWeight(.semibold)
                    .foregroundStyle(total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Image(systemName: expandedIds.contains(id) ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Sous-titre du groupe

    @ViewBuilder
    private func groupSubtitle(transactionCount: Int, tricountCount: Int) -> some View {
        if transactionCount > 0 && tricountCount > 0 {
            HStack(spacing: 4) {
                Text("\(transactionCount) transaction(s)").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Text("·").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(AppTheme.Colors.accentSecondary)
                    Text("\(tricountCount) Tricount").font(.caption).foregroundStyle(AppTheme.Colors.accentSecondary)
                }
            }
        } else if tricountCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(AppTheme.Colors.accentSecondary)
                Text("\(tricountCount) dépense(s) Tricount").font(.caption).foregroundStyle(AppTheme.Colors.accentSecondary)
            }
        } else {
            Text("\(transactionCount) transaction(s)").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: Sous-détail par catégorie (au sein d'un même payee)

    /// Découpe les items d'UN payee par catégorie — calculé en mémoire à partir
    /// des données déjà chargées (categoryId/categoryName portés par
    /// Reimbursement), pas de requête supplémentaire. Tri par montant absolu
    /// décroissant : la catégorie la plus lourde en premier.
    private func categorySubgroups(of items: [Reimbursement]) -> [CategoryReimbursementGroup] {
        var grouped: [Int: (name: String, items: [Reimbursement])] = [:]
        for item in items {
            let key = item.categoryId ?? -1
            let name = item.categoryId == nil ? "Non catégorisé" : item.categoryName
            grouped[key, default: (name, [])].items.append(item)
        }
        return grouped.map { id, pair in
            CategoryReimbursementGroup(categoryId: id == -1 ? nil : id, categoryName: pair.name, items: pair.items)
        }.sorted { abs($0.total) > abs($1.total) }
    }

    /// Clé composite payee+catégorie pour l'état d'expansion — cf. commentaire
    /// sur `expandedCategoryKeys`.
    private func categoryKey(payeeId: Int, sub: CategoryReimbursementGroup) -> String {
        "\(payeeId)|\(sub.id)"
    }

    private func categorySubheader(_ sub: CategoryReimbursementGroup, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Text(sub.categoryName).font(.subheadline).fontWeight(.semibold).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text(sub.total, format: .currency(code: "EUR"))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: Ligne item

    /// Repli : la note libre (`information`) est souvent vide (transactions
    /// importées, jamais annotées par l'user) → repli sur le payee ORIGINAL de
    /// la transaction (ex. "Netflix"), pas sur un libellé générique.
    private func displayLabel(_ item: Reimbursement) -> String {
        if !item.originDescription.isEmpty { return item.originDescription }
        if !item.originPayeeName.isEmpty { return item.originPayeeName }
        return item.isTricountOrigin ? "Tricount" : "Transaction"
    }

    @ViewBuilder
    private func itemRow(_ item: Reimbursement) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayLabel(item)).font(.subheadline)
                    if item.isTricountOrigin {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill").font(.caption2)
                            Text("Tricount").font(.caption2).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.accentSecondary.opacity(0.13), in: Capsule())
                        .foregroundStyle(AppTheme.Colors.accentSecondary)
                    }
                }
                Text(item.originDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.needsConversion {
                    Text(item.amount.formatted(.currency(code: item.currency)))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("non converti")
                        .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                } else {
                    Text(item.effectiveEurAmount.formatted(.currency(code: "EUR")))
                        .font(.subheadline)
                        .foregroundStyle(item.effectiveEurAmount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    if item.isConverted {
                        Text(item.amount.formatted(.currency(code: item.currency)))
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    // MARK: Chargement

    private func load() {
        groups = reimbursementRepo.fetchReimbursementGroups(from: fromDate, to: toDate)
    }
}

// MARK: - BulkTagSheet (sélection multiple avec état tri-state)

struct BulkTagSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let initialStates: [Int: TagSelectionState]
    let repository: TransactionRepository
    let onSave: ([Int: TagSelectionState]) -> Void
    let onNewTag: (Tag) -> Void

    @State private var states: [Int: TagSelectionState]
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""

    init(allTags: [Tag], initialStates: [Int: TagSelectionState], repository: TransactionRepository,
         onSave: @escaping ([Int: TagSelectionState]) -> Void, onNewTag: @escaping (Tag) -> Void) {
        self.initialStates = initialStates
        self.repository = repository
        self.onSave = onSave
        self.onNewTag = onNewTag
        _states = State(initialValue: initialStates)
        _localAllTags = State(initialValue: allTags)
    }

    var body: some View {
            List {
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Tags") {
                    ForEach(localAllTags) { tag in
                        Button { toggleTag(tag) } label: {
                            HStack(spacing: 12) {
                                stateIcon(for: tag)
                                Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                if states[tag.id] == .some {
                                    Text("partiel")
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .paneChrome("Tags — sélection multiple",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Appliquer") {
                onSave(states); dismiss()
            }
    }

    @ViewBuilder
    private func stateIcon(for tag: Tag) -> some View {
        switch states[tag.id] ?? .none {
        case .all:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tag.displayColor).font(.title3)
        case .some:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(AppTheme.Colors.textSecondary).font(.title3)
        case .none:
            Image(systemName: "circle")
                .foregroundStyle(AppTheme.Colors.textSecondary).font(.title3)
        }
    }

    private func toggleTag(_ tag: Tag) {
        states[tag.id, default: .none].toggle()
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            states[id] = .all
            let tag = Tag(id: id, name: name)
            if !localAllTags.contains(where: { $0.id == id }) {
                localAllTags.append(tag)
                localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onNewTag(tag)
            }
        }
        newTagName = ""
    }
}

// MARK: - TagManagementSheet (générique : transactions ET entrées Tricount)

struct TagManagementSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let initialTagIds: Set<Int>
    let allTags: [Tag]
    let repository: TransactionRepository
    let onSave: (Set<Int>) -> Void
    let onNewTag: (Tag) -> Void

    @State private var selectedTagIds: Set<Int>
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""
    @State private var tagColors: [Int: Color] = [:]

    init(initialTagIds: Set<Int>, allTags: [Tag], repository: TransactionRepository,
         onSave: @escaping (Set<Int>) -> Void, onNewTag: @escaping (Tag) -> Void) {
        self.initialTagIds = initialTagIds
        self.allTags = allTags
        self.repository = repository
        self.onSave = onSave
        self.onNewTag = onNewTag
        _selectedTagIds = State(initialValue: initialTagIds)
        _localAllTags = State(initialValue: allTags)
    }

    var body: some View {
            List {
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section(localAllTags.isEmpty ? "Aucun tag créé" : "Tags") {
                    ForEach($localAllTags) { $tag in
                        HStack(spacing: 12) {
                            Button {
                                if selectedTagIds.contains(tag.id) { selectedTagIds.remove(tag.id) }
                                else { selectedTagIds.insert(tag.id) }
                            } label: {
                                Image(systemName: selectedTagIds.contains(tag.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTagIds.contains(tag.id) ? tag.displayColor : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            // Color picker inline
                            ColorPicker("", selection: Binding(
                                get: { tag.displayColor },
                                set: { newColor in
                                    if let hex = newColor.toTagHex() {
                                        tag.color = hex
                                        repository.updateTagColor(id: tag.id, colorHex: hex)
                                    }
                                }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 28, height: 28)
                        }
                    }
                }
            }
            .paneChrome("Tags",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer") {
                onSave(selectedTagIds); dismiss()
            }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            selectedTagIds.insert(id)
            let tag = Tag(id: id, name: name)
            if !localAllTags.contains(where: { $0.id == id }) {
                localAllTags.append(tag)
                localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onNewTag(tag)
            }
        }
        newTagName = ""
    }
}

// MARK: - TagSummaryView (solde et liste des dépenses par tag)

struct TagSummaryView: View {
    @Environment(\.paneDismiss) private var paneDismiss
    let repository: TransactionRepository
    @State private var summaries: [TagExpenseSummary] = []
    @State private var isSyncingRates = false
    /// État à la place d'un `NavigationLink` : un push depuis ce contenu, une
    /// fois hébergé dans le panneau macOS, ferait remonter le titre/back-button
    /// de `TagDetailView` dans la barre du MODULE (aucune fenêtre séparée pour
    /// l'absorber). Le détail s'ouvre en sheet (niveau 2, scopée) à la place.
    @State private var selectedTag: Tag?

    var body: some View {
            Group {
                if summaries.isEmpty && !isSyncingRates {
                    ContentUnavailableView(
                        "Aucun tag utilisé",
                        systemImage: "tag.slash",
                        description: Text("Assignez des tags à vos transactions ou dépenses Tricount.")
                    )
                } else {
                    List {
                        if isSyncingRates {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Récupération des taux de change…")
                                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            .listRowSeparator(.hidden)
                        }
                        ForEach(summaries) { summary in
                            Button {
                                selectedTag = summary.tag
                            } label: {
                                HStack {
                                    tagSummaryRow(summary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onAppear {
                summaries = repository.fetchTagExpenseSummary()
                Task {
                    isSyncingRates = true
                    await CurrencyRateService.syncAllGroups()
                    summaries = repository.fetchTagExpenseSummary()
                    isSyncingRates = false
                }
            }
            .adaptivePane(item: $selectedTag) { tag in
                TagDetailView(tag: tag, repository: repository)
                    .paneChrome(tag.name, cancelLabel: "Fermer", onCancel: { selectedTag = nil })
            }
            .paneChrome("Dépenses par tag", cancelLabel: "Fermer", onCancel: { paneDismiss() })
    }

    @ViewBuilder
    private func tagSummaryRow(_ summary: TagExpenseSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .foregroundStyle(summary.tag.displayColor)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.tag.name).font(.headline)
                HStack(spacing: 8) {
                    if summary.transactionTotal != 0 {
                        Label(summary.transactionTotal.formatted(.currency(code: "EUR")), systemImage: "creditcard")
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    if summary.tricountTotal != 0 {
                        Label(summary.tricountTotal.formatted(.currency(code: "EUR")), systemImage: "person.2")
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            Text(summary.total.formatted(.currency(code: "EUR")))
                .fontWeight(.semibold)
                .foregroundStyle(summary.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - TagDetailView (liste des éléments d'un tag)

struct TagDetailView: View {
    let tag: Tag
    let repository: TransactionRepository

    @State private var transactions: [FinanceTransaction] = []
    @State private var tricountEntries: [TaggedTricountEntry] = []
    @State private var isSyncingRates = false

    private var txTotal: Double { transactions.reduce(0) { $0 + $1.amount } }
    // Exclut les entrées sans taux (devise étrangère non convertie) du total EUR
    private var tcTotal: Double { tricountEntries.reduce(0) { $0 + ($1.needsConversion ? 0 : $1.signedAmount) } }
    private var grandTotal: Double { txTotal + tcTotal }
    private var hasConvertedEntries: Bool { tricountEntries.contains { $0.isConverted } }
    private var hasUnconvertedEntries: Bool { tricountEntries.contains { $0.needsConversion } }

    var body: some View {
        List {
            // Résumé
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total").font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(grandTotal.formatted(.currency(code: "EUR")))
                            .font(.title3).fontWeight(.bold)
                            .foregroundStyle(grandTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    Spacer()
                    if transactions.count > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(transactions.count) transaction(s)")
                                .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                            Text(txTotal.formatted(.currency(code: "EUR")))
                                .font(.caption).foregroundStyle(txTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                    if tricountEntries.count > 0 {
                        Divider().frame(height: 32)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tricountEntries.count) Tricount\(hasConvertedEntries ? " ~EUR" : "")\(hasUnconvertedEntries ? " ⚠" : "")")
                                .font(.caption2).foregroundStyle(hasUnconvertedEntries ? AppTheme.Colors.warning : AppTheme.Colors.textSecondary)
                            Text((hasUnconvertedEntries ? "≈ " : "") + tcTotal.formatted(.currency(code: "EUR")))
                                .font(.caption).foregroundStyle(tcTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if !transactions.isEmpty {
                Section("Transactions (\(transactions.count))") {
                    ForEach(transactions) { tx in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                    .font(.subheadline)
                                HStack(spacing: 4) {
                                    if !tx.categoryName.isEmpty {
                                        Text(tx.categoryName)
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                            .foregroundStyle(AppTheme.Colors.accent)
                                    }
                                    Text(tx.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                            Spacer()
                            Text(tx.amount.formatted(.currency(code: "EUR")))
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !tricountEntries.isEmpty {
                Section {
                    ForEach(tricountEntries) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.description.isEmpty ? entry.groupTitle : entry.description)
                                    .font(.subheadline)
                                HStack(spacing: 4) {
                                    Text(entry.groupTitle)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(tag.displayColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(tag.displayColor)
                                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if entry.needsConversion {
                                    // Pas de taux disponible : afficher en devise originale avec indicateur
                                    let rawSigned = entry.isExpense ? -entry.myShare : entry.myShare
                                    Text(rawSigned.formatted(.currency(code: entry.currency)))
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(AppTheme.Colors.warning)
                                    Text("non converti")
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                                } else {
                                    // Montant en EUR (signé : négatif si dépense, positif si revenu)
                                    Text(entry.signedAmount.formatted(.currency(code: "EUR")))
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(entry.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                    // Montant original si devise étrangère convertie
                                    if entry.isConverted {
                                        let rawSigned = entry.isExpense ? -entry.myShare : entry.myShare
                                        Text(rawSigned.formatted(.currency(code: entry.currency)))
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Tricount (\(tricountEntries.count))")
                        if hasConvertedEntries {
                            Spacer()
                            Label("Converti en EUR", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSyncingRates {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .onAppear {
            transactions = repository.fetchTransactions(forTagId: tag.id)
            tricountEntries = repository.fetchTricountEntries(forTagId: tag.id)
            // Si des entrées non-EUR sont sans taux, déclencher la sync
            if tricountEntries.contains(where: { $0.needsConversion }) {
                Task {
                    isSyncingRates = true
                    await CurrencyRateService.syncAllGroups()
                    tricountEntries = repository.fetchTricountEntries(forTagId: tag.id)
                    isSyncingRates = false
                }
            }
        }
    }
}

// MARK: - TagPickerSheet (sélection multi-tags + création)

struct TagPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var allTags: [Tag]
    @Binding var selectedTagIds: Set<Int>
    let repository: TransactionRepository

    @State private var newTagName = ""
    @State private var search = ""

    var filtered: [Tag] {
        guard !search.isEmpty else { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Création rapide
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // Liste des tags
                Section("Tags disponibles") {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Aucun tag créé" : "Aucun résultat")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        ForEach($allTags) { $tag in
                            // N'afficher que les tags correspondant à la recherche
                            if search.isEmpty || tag.name.localizedCaseInsensitiveContains(search) {
                                HStack(spacing: 12) {
                                    Button {
                                        if selectedTagIds.contains(tag.id) { selectedTagIds.remove(tag.id) }
                                        else { selectedTagIds.insert(tag.id) }
                                    } label: {
                                        Image(systemName: selectedTagIds.contains(tag.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedTagIds.contains(tag.id) ? tag.displayColor : .secondary)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.plain)
                                    Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    ColorPicker("", selection: Binding(
                                        get: { tag.displayColor },
                                        set: { newColor in
                                            if let hex = newColor.toTagHex() {
                                                tag.color = hex
                                                repository.updateTagColor(id: tag.id, colorHex: hex)
                                            }
                                        }
                                    ), supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 28, height: 28)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher un tag…")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            selectedTagIds.insert(id)
            if !allTags.contains(where: { $0.id == id }) {
                allTags.append(Tag(id: id, name: name))
                allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        newTagName = ""
    }
}

// MARK: - TagQuickSheet (raccourci swipe → tags)

struct TagQuickSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let transactionId: Int
    let allTags: [Tag]
    let repository: TransactionRepository
    let onNewTag: (Tag) -> Void

    @State private var selectedTagIds: Set<Int> = []
    @State private var localAllTags: [Tag]
    @State private var newTagName = ""
    @State private var isLoaded = false

    init(transactionId: Int, allTags: [Tag], repository: TransactionRepository, onNewTag: @escaping (Tag) -> Void) {
        self.transactionId = transactionId
        self.allTags = allTags
        self.repository = repository
        self.onNewTag = onNewTag
        _localAllTags = State(initialValue: allTags)
    }

    var body: some View {
            List {
                Section {
                    HStack {
                        TextField("Nouveau tag…", text: $newTagName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Ajouter") { createTag() }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section(localAllTags.isEmpty ? "Aucun tag créé" : "Tags") {
                    ForEach($localAllTags) { $tag in
                        HStack(spacing: 12) {
                            Button { toggle(tag.id) } label: {
                                Image(systemName: selectedTagIds.contains(tag.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTagIds.contains(tag.id) ? tag.displayColor : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            ColorPicker("", selection: Binding(
                                get: { tag.displayColor },
                                set: { newColor in
                                    if let hex = newColor.toTagHex() {
                                        tag.color = hex
                                        repository.updateTagColor(id: tag.id, colorHex: hex)
                                    }
                                }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 28, height: 28)
                        }
                    }
                }
            }
            .onAppear {
                guard !isLoaded else { return }
                selectedTagIds = Set(repository.fetchTags(forTransaction: transactionId).map(\.id))
                isLoaded = true
            }
            .paneChrome("Tags",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", onConfirm: { save() })
    }

    private func toggle(_ tagId: Int) {
        if selectedTagIds.contains(tagId) { selectedTagIds.remove(tagId) }
        else { selectedTagIds.insert(tagId) }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = repository.findOrCreateTag(name: name) {
            let tag = Tag(id: id, name: name)
            selectedTagIds.insert(id)
            if !localAllTags.contains(where: { $0.id == id }) {
                localAllTags.append(tag)
                localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onNewTag(tag)
            }
        }
        newTagName = ""
    }

    private func save() {
        repository.setTags(Array(selectedTagIds), forTransaction: transactionId)
        dismiss()
    }
}

// MARK: - TransactionDetailPane (panneau détail macOS)

/// Détail lecture seule d'une transaction, affiché dans le panneau latéral
/// macOS par `adaptiveEntityPane` (jamais instancié sur iOS, où le tap ouvre
/// directement l'édition en sheet — comportement historique).
struct TransactionDetailPane: View {
    let tx: FinanceTransaction
    let accounts: [Account]
    let allTiers: [Tiers]
    let allCategories: [Category]
    let repository: TransactionRepository

    /// Lecture fraîche à chaque rendu : après une édition (tags modifiés dans
    /// le sheet), le retour au détail reflète l'état réel en base.
    private var tags: [Tag] {
        repository.fetchTagsForTransactions([tx.id])[tx.id] ?? []
    }

    private var accountName: String {
        accounts.first { $0.id == tx.accountId }?.name ?? "Compte #\(tx.accountId)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    MerchantLogo(transaction: tx, allTiers: allTiers, allCategories: allCategories, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tx.tiersName.isEmpty ? "Sans tiers" : tx.tiersName)
                            .font(AppTheme.Typography.bodyMedium)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(2)
                        Text(tx.date.formatted(date: .long, time: .omitted))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(tx.amount, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneyMedium)
                        .foregroundStyle(tx.amount >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent("Compte", value: accountName)
                LabeledContent("Catégorie", value: tx.categoryName.isEmpty ? "—" : tx.categoryName)
                LabeledContent("Moyen de paiement", value: tx.paymentTypeName.isEmpty ? "—" : tx.paymentTypeName)
                if !tx.remboursementTiersName.isEmpty {
                    LabeledContent("Remboursement", value: tx.remboursementTiersName)
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    Text(tags.map(\.name).joined(separator: " · "))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            if !tx.information.isEmpty {
                Section("Note") {
                    Text(tx.information)
                        .font(AppTheme.Typography.bodySmall)
                }
            }

            if let brut = tx.libelleBrut, !brut.isEmpty {
                Section("Libellé bancaire brut") {
                    Text(brut)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
