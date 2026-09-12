import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Tag color helpers
extension Tag {
    /// The tag's SwiftUI color. If the user hasn't chosen one, a
    /// tint is DETERMINISTICALLY derived from the id over a small palette
    /// — not a single copper shared by every uncolored tag. Otherwise
    /// several unrelated tags (e.g. two different trips) show
    /// EXACTLY the same color, which defeats the point of a color code
    /// (several tags never colored by hand used to look
    /// visually indistinguishable).
    var displayColor: Color {
        guard let hex = color, !hex.isEmpty else {
            return Tag.fallbackPalette[abs(id) % Tag.fallbackPalette.count]
        }
        return Color(tagHex: hex)
    }

    /// A fixed palette (like hand-picked tag colors: a raw hex,
    /// no dark/light variant) — just enough distinct tints
    /// that a nearby id doesn't visually fall on the same neighbor.
    private static let fallbackPalette: [Color] = [
        AppTheme.Colors.accentSecondary,
        Color(hex: "5B8DB8"),
        Color(hex: "6FA86F"),
        Color(hex: "8A7CB8"),
        Color(hex: "4FA8A0"),
        Color(hex: "B85B7A"),
        Color(hex: "9AA85B"),
        Color(hex: "C2914A"),
    ]
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

    // Data
    @State private var transactions: [FinanceTransaction] = []
    @State private var accounts: [Account] = []
    @State private var allTiers: [Tiers] = []
    @State private var allCategories: [Category] = []
    @State private var allMdps: [PaymentType] = []
    @State private var allTags: [Tag] = []

    // Lazy loading — `isLoading = true` at boot to show the skeleton from the 1st render.
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = true
    private let pageSize = 100

    // Selection — the anchor enables shift+click (a range), see `RangeSelection`
    // (DesignSystem/MultiSelect.swift).
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int> = []
    @State private var selectionAnchor: Int? = nil
    @State private var showDeleteConfirmation = false
    @State private var showBulkRemboursementPicker = false
    @State private var showBulkTagPicker = false
    @State private var showBulkCategoryPicker = false
    @State private var bulkTagInitialStates: [Int: TagSelectionState] = [:]

    // Editing
    /// Selected transaction: iOS → a direct edit sheet; macOS →
    /// a detail pane (Edit/Delete) then editing (adaptiveEntityPane).
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

    // Filtered analysis
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
    /// Manual dismissal of the "N uncategorized transactions" warning
    /// — reset to `false` as soon as the account changes (a new import, etc.),
    /// so a genuinely new batch to categorize isn't hidden indefinitely.
    @State private var uncategorizedBannerDismissed = false

    // Filters & display
    //
    // ⚠️ Category / tags / grouping are PERSISTED (`UserDefaults`, keys
    // `tx.filter.*`) — these filters used to reset on every app
    // launch. The text search (payee/label), however, is
    // deliberately NOT: a search term left active from one
    // session to the next would be more surprising than useful (unlike
    // "I always filter on this category", a real preference).
    @State private var showFilters = false
    @State private var payeeSearchText = ""
    @State private var labelSearchText = ""
    @State private var selectedCategoryId = UserDefaults.standard.object(forKey: "tx.filter.categoryId") as? Int ?? -1
    @State private var filterTagIds: Set<Int> = Set((UserDefaults.standard.array(forKey: "tx.filter.tagIds") as? [Int]) ?? [])
    @State private var tagFilteredTxIds: Set<Int>? = nil  // nil = pas de filtre tag actif
    @State private var grouping: TransactionGrouping =
        TransactionGrouping(rawValue: UserDefaults.standard.string(forKey: "tx.filter.grouping") ?? "") ?? .day

    // MARK: Computed

    /// `true` when the user picked the "All accounts" sentinel (id = 0) in
    /// the picker. Changes the UX: the account balance + per-row running
    /// balance are hidden (meaningless across accounts) and an account chip
    /// is shown on every row to tell the source apart.
    private var isAllAccountsMode: Bool {
        (appState.selectedAccountId ?? 0) == 0
    }

    /// O(1) lookup to show the account name on each row in "All" mode.
    private var accountsById: [Int: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    private var activeFiltersCount: Int {
        (payeeSearchText.isEmpty ? 0 : 1)
        + (labelSearchText.isEmpty ? 0 : 1)
        + (selectedCategoryId == -1 ? 0 : 1)
        + (filterTagIds.isEmpty ? 0 : 1)
    }

    private var filteredTransactions: [FinanceTransaction] {
        transactions.filter { tx in
            let payeeMatch = payeeSearchText.isEmpty
                || tx.tiersName.localizedCaseInsensitiveContains(payeeSearchText)
            let labelMatch = labelSearchText.isEmpty
                || tx.information.localizedCaseInsensitiveContains(labelSearchText)
            let catMatch = selectedCategoryId == -1
                || (selectedCategoryId == -2 ? tx.categoryId == nil : tx.categoryId == selectedCategoryId)
            let tagMatch = tagFilteredTxIds.map { $0.contains(tx.id) } ?? true
            return payeeMatch && labelMatch && catMatch && tagMatch
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

    /// The account balance after each transaction (with no extra SQL query).
    /// Computed starting from accountBalance (the balance at the end of the period) and
    /// walking backward from the most recent to the oldest. Empty if active
    /// filters make the data incomplete, or in "All accounts" mode (a
    /// running balance makes no sense across accounts).
    private var txBalances: [Int: Double] {
        guard activeFiltersCount == 0, !isAllAccountsMode else { return [:] }
        var result: [Int: Double] = [:]
        var running = accountBalance
        for tx in transactions { // sorted most recent to oldest
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

    // ⚠️ The body is split into a CHAIN of computed properties (`listContent` →
    // `bodyWithChrome` → … → `navBody`) rather than a single
    // `Group { … }.modifier().modifier()…` expression. With ~30 chained
    // modifiers (a dozen of them `.adaptivePane` closures), Xcode 26 used to fail with
    // "The compiler is unable to type-check this expression in reasonable
    // time": the type checker treats the whole chain as ONE
    // expression and blows up combinatorially. Each link is now a
    // separate expression, resolved in isolation. Don't merge them back —
    // add a new pane in its matching thematic link.
    private var navBody: some View {
        bodyWithLifecycle
    }

    @ViewBuilder private var listContent: some View {
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
            transactionsList
        }
    }

    private var transactionsList: some View {
        List {
            balancesSection
            uncategorizedWarningSection
            transactionGroupsSections
            paginationFooter
        }
        #if os(macOS)
        // macOS: .plain = a neutral base for the custom cards
        // drawn by macGroupedRow (first/last rounded corners,
        // inset, internal separators). iOS keeps its native
        // insetGrouped — macGroupedRow there only sets the listRowBackground.
        .listStyle(.plain)
        // Detaches the 1st card from the toolbar (iOS insetGrouped adds
        // this space automatically, `.plain` doesn't).
        .macGroupedListTopGap()
        #endif
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background)
        // ⌘A: selects everything already loaded (see `selectAllLoaded`).
        .background(SelectAllShortcut(isSelecting: $isSelecting, selected: $selectedIds, allIds: transactions.map(\.id)))
    }

    private var bodyWithChrome: some View {
        listContent
            .localizedNavigationTitle("Transactions")
            .toolbar { transactionsToolbar }
    }

    @ToolbarContentBuilder private var transactionsToolbar: some ToolbarContent {
        // #9 macOS: don't emit a .navigation item (the
        // navigationBarLeading mapping) — even empty it collides with the
        // NavigationSplitView's system back + sidebar toggle, hence the
        // back arrow that "travels". On Mac, "Cancel" joins
        // the trailing group.
        #if !os(macOS)
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
                Button("Annuler") { cancelSelection() }
            }
        }
        #endif
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                selectionToolbarButtons
            } else {
                browsingToolbarButtons
            }
        }
    }

    @ViewBuilder private var selectionToolbarButtons: some View {
        #if os(macOS)
        Button { cancelSelection() } label: {
            Image(systemName: "xmark.circle")
        }
        .localizedHelp("Annuler la sélection")
        .localizedAccessibilityLabel("Annuler la sélection")
        
        Spacer()
        #endif
        Button {
            selectAllLoaded()
        } label: {
            Image(systemName: "checklist")
        }
        .localizedHelp("Tout sélectionner")
        .localizedAccessibilityLabel("Tout sélectionner")
        if !selectedIds.isEmpty {
            PaneToggleButton(label: "Catégorie", systemImage: "folder", isOn: $showBulkCategoryPicker)
            // Custom binding: computing the initial states must
            // stay triggered on OPEN (as before), not on
            // every toggle.
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
    }

    @ViewBuilder private var browsingToolbarButtons: some View {
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
        // macOS: the window has the room — secondary actions
        // spread out as icon-only buttons + a native tooltip (.help),
        // instead of iOS's "⋯" menu.
        PaneToggleButton(label: "Analyse filtrée", systemImage: "chart.bar.xaxis.ascending", isOn: $showFilteredDashboard)
        Spacer()
        PaneToggleButton(label: "Dépenses par tag", systemImage: "tag.circle", isOn: $showTagSummary)
        if reimbursementsEnabled {
            PaneToggleButton(label: "Remboursements", systemImage: "arrow.uturn.left.circle", isOn: $showReimbursements)
        }
        Spacer()
        Button { isSelecting = true } label: {
            Image(systemName: "checkmark.circle")
        }
        .localizedHelp("Sélectionner")
        #else
        // Menu actions secondaires
        Menu {
            Button { showFilteredDashboard = true } label: {
                Label("Analyse filtrée", systemImage: "chart.bar.xaxis.ascending")
            }
            Divider()
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

    private var bodyWithDialogs: some View {
        bodyWithChrome
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
    }

    private var bodyWithFilters: some View {
        bodyWithDialogs
            .adaptivePane(isPresented: $showFilters) {
                TransactionFiltersSheet(
                    accounts: accounts,
                    allCategories: allCategories,
                    allTags: allTags,
                    allTiers: allTiers,
                    payeeSearchText: $payeeSearchText,
                    labelSearchText: $labelSearchText,
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
            // Persisting filter preferences (category/tags/grouping,
            // not the text search — see the comment on their declarations).
            .onChange(of: selectedCategoryId) { _, new in
                UserDefaults.standard.set(new, forKey: "tx.filter.categoryId")
            }
            .onChange(of: filterTagIds) { _, new in
                UserDefaults.standard.set(Array(new), forKey: "tx.filter.tagIds")
            }
            .onChange(of: grouping) { _, new in
                UserDefaults.standard.set(new.rawValue, forKey: "tx.filter.grouping")
            }
    }

    private var bodyWithEntityPanes: some View {
        bodyWithFilters
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
                    // Refreshes the list of available tags if a new one was created
                    if !allTags.contains(where: { $0.id == newTag.id }) {
                        allTags.append(newTag)
                        allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                }
            }
    }

    private var bodyWithActionPanes: some View {
        bodyWithEntityPanes
            .adaptivePane(isPresented: $showAddTransaction) {
                // If the user is in "All" mode (selectedAccountId == 0), fall back
                // to the first available account for manual entry (a transaction can't
                // be charged to the "All" sentinel).
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
            // TricountDetailView manages ITS OWN chrome (Close/NavigationStack) —
            // level 2 here (nested inside a view already hosted), so a sheet, see
            // \.paneHostContext in TricountDetailView.
            .adaptivePane(item: $tricountDetailGroup, onDismiss: { tricountDetailEntryId = nil }) { group in
                TricountDetailView(group: group, initialEntryId: tricountDetailEntryId)
            }
    }

    private var bodyWithBulkPanes: some View {
        bodyWithActionPanes
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
    }

    private var bodyWithLifecycle: some View {
        bodyWithBulkPanes
            .task(id: appState.dataRefreshToken) {
                // 1-frame guard: lets the skeleton paint before the SQLite query.
                await Task.yield()
                loadInitialData()
            }
            .refreshable {
                // No skeleton on pull-to-refresh: the system indicator is enough.
                loadInitialData()
            }
            .onChange(of: uncategorizedCount) { old, new in
                if new != old { uncategorizedBannerDismissed = false }
            }
    }

    // MARK: Skeleton

    @ViewBuilder private var transactionsSkeleton: some View {
        List {
            // Period / actual balance header
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
        // Same .plain base as the loaded list (macGroupedRow cards).
        .listStyle(.plain)
        .macGroupedListTopGap()
        #endif
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background)
    }

    // MARK: List sections
    //
    // Each of these sections used to live inline in `navBody`'s
    // `List` — one huge ViewBuilder block (balances + warning +
    // groups + pagination, with nested conditionals and ternaries). Xcode 26
    // (release) fails to type-check that block in reasonable time
    // ("the compiler is unable to type-check this expression") whereas Xcode 27
    // beta, with a faster type solver, doesn't have this problem — splitting
    // it into separate properties gives the type checker clear bounds,
    // independent of the compiler version.

    /// Period/account balances (#6). In "All accounts" mode, ONLY
    /// the period sum (net flow) is shown — "Actual balance" would aggregate every
    /// account (checking + cash + savings…), a misleading reading.
    @ViewBuilder
    private var balancesSection: some View {
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
    }

    /// "N uncategorized transactions" banner, dismissible per session
    /// (`uncategorizedBannerDismissed`).
    @ViewBuilder
    private var uncategorizedWarningSection: some View {
        if uncategorizedCount > 0 && selectedCategoryId != -2 && !uncategorizedBannerDismissed {
            Section {
                HStack(spacing: 12) {
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Close without categorizing: stays dismissed as long as the
                    // uncategorized count doesn't change (a new import, etc. makes
                    // it reappear — see `.onChange(of: uncategorizedCount)`).
                    Button {
                        uncategorizedBannerDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(AppTheme.Colors.surfaceSecondary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .localizedAccessibilityLabel("Fermer cet avertissement")
                }
                .padding(.vertical, 2)
            }
            .macGroupedRow()
        }
    }

    /// Transaction groups by date, each as a `Section`.
    ///
    /// `flatIds`/`flatIndex`: the GLOBAL index (across every section) of
    /// each visible transaction — needed for shift+click, whose range
    /// can cross a group boundary (day/week/month). Computed
    /// ONCE per list render (not per row), otherwise O(n²) on a
    /// history of several hundred rows.
    @ViewBuilder
    private var transactionGroupsSections: some View {
        let flatIds = groupedTransactions.flatMap { $0.transactions.map(\.id) }
        let flatIndex = Dictionary(uniqueKeysWithValues: flatIds.enumerated().map { ($1, $0) })
        ForEach(groupedTransactions, id: \.date) { group in
            Section {
                ForEach(group.transactions) { item in
                    transactionListRow(item, index: flatIndex[item.id] ?? 0, allIds: flatIds, in: group.transactions)
                }
            } header: {
                group.label
                    .macGroupedSectionHeader()
            }
        }
    }

    /// Pagination sentinel (triggers `loadMore()`) or the final count.
    @ViewBuilder
    private var paginationFooter: some View {
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

    // MARK: Row

    // Extracted into separate functions (instead of one modifier chain
    // in the ForEach): the Swift 6 compiler takes an unreasonable
    // amount of time to type-check a `.contentShape().onTapGesture().rowActions().macGroupedRow { … }`
    // chain when it's nested as-is in a ForEach/Section — splitting it into
    // re-annotated sub-expressions gives the type checker clear bounds.
    private func leadingRowActions(for item: FinanceTransaction) -> [RowAction] {
        guard !isSelecting else { return [] }
        return [
            RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) {
                selectedTransaction = item
            }
        ]
    }

    private func trailingRowActions(for item: FinanceTransaction) -> [RowAction] {
        guard !isSelecting else { return [] }
        return [
            RowAction("Supprimer", systemImage: "trash", role: .destructive) {
                txToDelete = item
            },
            RowAction("Tags", systemImage: "tag", tint: AppTheme.Colors.accentSecondary) {
                tagQuickTx = item
            }
        ]
    }

    /// Context-menu selection entries (macOS right-click / iOS long
    /// press) — "Select" outside selection mode, group actions if
    /// several transactions are already selected. See `selectionRowActions`.
    private func selectionActions(for item: FinanceTransaction, index: Int, allIds: [Int]) -> [RowAction] {
        selectionRowActions(
            isSelecting: isSelecting,
            isSelected: selectedIds.contains(item.id),
            selectionCount: selectedIds.count,
            toggle: { RangeSelection.toggle(item.id, index: index, selected: &selectedIds, anchor: &selectionAnchor) },
            selectAll: selectAllLoaded,
            clearSelection: { selectedIds = [] },
            deleteSelection: { showDeleteConfirmation = true }
        )
    }

    @ViewBuilder
    private func transactionRowBackground(for item: FinanceTransaction) -> some View {
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

    @ViewBuilder
    private func transactionListRow(_ item: FinanceTransaction, index: Int, allIds: [Int], in groupTransactions: [FinanceTransaction]) -> some View {
        let isFirst = item.id == groupTransactions.first?.id
        let isLast = item.id == groupTransactions.last?.id
        transactionRow(item)
            .selectableRow(
                id: item.id, index: index, allIds: allIds,
                isSelecting: $isSelecting, selected: $selectedIds, anchor: $selectionAnchor
            ) {
                selectedTransaction = item
            }
            .rowActions(
                selection: selectionActions(for: item, index: index, allIds: allIds),
                leading: leadingRowActions(for: item),
                trailing: trailingRowActions(for: item),
                leadingFullSwipe: false,
                trailingFullSwipe: false
            )
            .macGroupedRow(first: isFirst, last: isLast) {
                transactionRowBackground(for: item)
            }
    }

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
                // When there's no description, the text block (title + badges) is
                // centered vertically relative to the logo via top+bottom Spacers + minHeight.
                // Otherwise: natural top alignment (the description takes up space).
                if item.information.isEmpty {
                    Spacer(minLength: 0)
                }
                // Line 1: label + amount ONLY (the balance is moved to the bottom
                // to free up 13pt on this line — it was the balance that kept
                // the text block from fitting the logo's height (52pt) and kept
                // the title from ever being centered.
                HStack(alignment: .firstTextBaseline) {
                    Text(item.tiersName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(item.amount, format: .currency(code: "EUR"))
                        .fontWeight(.bold)
                        .foregroundStyle(item.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                }
                // Line 2: user info (only if filled in — no more fallback to the raw label
                // or paymentTypeName, which used to clutter the cell) + badges + running balance.
                // In compact mode, this whole line is hidden to get a 1-line row.
                if density.showSecondaryInfo {
                HStack(spacing: 6) {
                    if !item.information.isEmpty {
                        Text(item.information)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Account badge — shown only in "All accounts" mode to
                    // tell each transaction's source apart.
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
                    // Tricount badge (a link) — tappable, part of the badge row
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
                    // Category badge — tappable for a quick edit
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
                    // Running balance after the transaction (pinned right, after the badges)
                    if let bal = txBalances[item.id] {
                        Text(bal, format: .currency(code: "EUR"))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(.leading, 4)
                    }
                }
                }  // end if density.showSecondaryInfo
                // Line 3: tags (only if present). Also hidden in compact mode.
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
                // Note: libelle_brut and paymentTypeName are available in the
                // transaction's edit sheet (TransactionEditSheet) — no need to
                // duplicate them in every list row.
                if item.information.isEmpty {
                    Spacer(minLength: 0)
                }
            }
            // minHeight driven by density — lets the Spacer(minLength: 0)s
            // vertically center the text block relative to the logo when the
            // description is empty.
            .frame(minHeight: density.rowMinHeight)
        }
        .padding(.vertical, density.verticalPadding)
    }

    // MARK: Loading

    private func loadInitialData() {
        // Navigation from a payee's detail sheet ("View transactions"):
        // the same reset doctrine as the "Reset filters" button in
        // `TransactionFiltersSheet` — without it, an active category/tag
        // filter would hide part of the target payee's transactions,
        // against what the button promises. "All accounts": a
        // payee isn't tied to a particular account.
        //
        // ⚠️ The ACTIVE date range (the previous month by default) does
        // exactly the same thing, silently: without widening it, the
        // payee's older transactions stay hidden with no clue at all that it's
        // THIS filter limiting the display. Widened rather than removed — the
        // bound stays visible and editable in `TransactionFiltersSheet` (the
        // "From"/"To" DatePickers).
        if let pendingPayeeName = appState.pendingPayeeFilterName {
            payeeSearchText    = pendingPayeeName
            labelSearchText    = ""
            selectedCategoryId = -1
            filterTagIds       = []
            tagFilteredTxIds   = nil
            appState.selectedAccountId   = 0
            appState.selectedAccountName = ""
            appState.filterFromDate = Calendar.current.date(byAdding: .year, value: -50, to: Date()) ?? .distantPast
            appState.filterToDate   = Date()
            appState.pendingPayeeFilterName = nil
        }

        accounts      = repository.fetchAccounts()
        allTiers      = repository.fetchTiers()
        allCategories = repository.fetchCategories()
        allMdps       = repository.fetchPaymentTypes()
        allTags       = repository.fetchAllTags()
        linkedTricountTxIds = repository.fetchLinkedTransactionIds()

        if appState.selectedAccountId == nil {
            // Uses the default account if set and present in the list, otherwise the first account
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
        // `filterTagIds` can arrive pre-filled (persisted, see its declaration)
        // even before the user opens the filter sheet — without this
        // initial recompute, `tagFilteredTxIds` would stay nil and the persisted
        // tag filter would have no effect until "Apply" is tapped again.
        if !filterTagIds.isEmpty {
            tagFilteredTxIds = repository.fetchTransactionIds(havingAnyTagIds: filterTagIds)
        }
        resetAndLoad()
    }

    private func resetAndLoad() {
        // `accountId == 0` is the "All accounts" sentinel → passed as-is to the
        // repository, which drops the matching account_id WHERE clause.
        let accountId = appState.selectedAccountId ?? 0
        isLoading    = true
        transactions = []
        hasMore      = true

        let hasActiveFilters = !payeeSearchText.isEmpty || !labelSearchText.isEmpty || selectedCategoryId != -1 || tagFilteredTxIds != nil

        if hasActiveFilters {
            // Active filters: EVERY matching transaction is loaded in SQL
            // so the search isn't limited to the first 100 paginated rows.
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

    // MARK: Selection

    private func cancelSelection() {
        isSelecting = false
        selectedIds.removeAll()
        selectionAnchor = nil
    }

    /// ⌘A / "Select all": only covers what's already LOADED in
    /// memory (`transactions`), never a fetch of the whole history — on
    /// a paginated list, a shortcut shouldn't silently pull in
    /// years of undisplayed data.
    private func selectAllLoaded() {
        isSelecting = true
        selectedIds = Set(transactions.map(\.id))
    }

    // MARK: Quick category

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

    // MARK: Filtered analysis

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
            payeeSearchText: payeeSearchText,
            labelSearchText: labelSearchText,
            categoryId: selectedCategoryId,
            categoryName: categoryName,
            tagNames: tagNames,
            tagFilteredTxIds: tagFilteredTxIds
        )
    }

    // MARK: Deletion

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

    // MARK: Bulk tags (tri-state)

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
