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

    private func groupLabel(for date: Date) -> Text {
        switch grouping {
        case .day:
            return Text(date, format: .dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            return Text("Semaine du ") + Text(date, format: .dateTime.day().month(.abbreviated).year())
        case .month:
            return Text(date, format: .dateTime.month(.wide).year())
        }
    }

    private var groupedTransactions: [(date: Date, label: Text, transactions: [FinanceTransaction])] {
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
                    EmptyStateView(
                        icon: "tray",
                        title: "Aucune transaction",
                        message: "Vérifiez que le compte selectionné et la plage de temps correspondent. Sinon commencez par ajouter vos transactions ou les importer depuis un fichier sqlite existant ou un fichier csv."
                    )
                } else if filteredTransactions.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Aucun résultat",
                        message: "Aucune transaction ne correspond aux filtres actifs."
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
                                group.label
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
                            PaneToggleButton(label: "Catégorie", systemImage: "folder", isOn: $showBulkCategoryPicker)
                            // Binding custom : le calcul des états initiaux doit
                            // rester déclenché à l'OUVERTURE (comme avant), pas à
                            // chaque bascule.
                            PaneToggleButton(label: "Tags", systemImage: "tag", isOn: Binding(
                                get: { showBulkTagPicker },
                                set: { newValue in
                                    if newValue { bulkTagInitialStates = computeBulkTagStates() }
                                    showBulkTagPicker = newValue
                                }
                            ))
                            if reimbursementsEnabled {
                                PaneToggleButton(label: "Remboursement", systemImage: "arrow.uturn.left.circle", isOn: $showBulkRemboursementPicker)
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
                        PaneToggleButton(label: "Ajouter une transaction", systemImage: "plus", isOn: $showAddTransaction)
                        // Bouton filtre (badge si actif)
                        PaneToggleButton(
                            label: "Filtrer",
                            systemImage: activeFiltersCount > 0
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle",
                            isOn: $showFilters
                        )
                        #if os(macOS)
                        // macOS : la fenêtre a la place — actions secondaires
                        // étalées en boutons icône seule + tooltip natif (.help),
                        // au lieu du menu "⋯" iOS.
                        PaneToggleButton(label: "Analyse filtrée", systemImage: "chart.bar.xaxis.ascending", isOn: $showFilteredDashboard)
                        PaneToggleButton(label: "Dépenses par tag", systemImage: "tag.circle", isOn: $showTagSummary)
                        if reimbursementsEnabled {
                            PaneToggleButton(label: "Remboursements", systemImage: "arrow.uturn.left.circle", isOn: $showReimbursements)
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
                    Text("\(tx.tiersName.isEmpty ? tx.information : tx.tiersName) · ") + Text(tx.amount, format: .currency(code: "EUR"))
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
                // Si l'utilisateur est en mode "Tous" (selectedAccountId == 0), on retombe
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
