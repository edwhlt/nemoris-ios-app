import SwiftUI

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

    // Lazy loading
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    private let pageSize = 100

    // Sélection
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int> = []
    @State private var showDeleteConfirmation = false

    // Édition
    @State private var editingTransaction: TransactionEditDraft? = nil
    @State private var quickCategoryTx: FinanceTransaction? = nil

    // Filtres & affichage
    @State private var showFilters = false
    @State private var tiersSearchText = ""
    @State private var selectedCategoryId = -1
    @State private var grouping: TransactionGrouping = .day

    // MARK: Computed

    private var activeFiltersCount: Int {
        (tiersSearchText.isEmpty ? 0 : 1) + (selectedCategoryId == -1 ? 0 : 1)
    }

    private var filteredTransactions: [FinanceTransaction] {
        transactions.filter { tx in
            let tiersMatch = tiersSearchText.isEmpty
                || tx.tiersName.localizedCaseInsensitiveContains(tiersSearchText)
                || tx.information.localizedCaseInsensitiveContains(tiersSearchText)
            let catMatch = selectedCategoryId == -1 || tx.categoryId == selectedCategoryId
            return tiersMatch && catMatch
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

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Chargement…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if transactions.isEmpty {
                    ContentUnavailableView(
                        "Aucune transaction",
                        systemImage: "tray",
                        description: Text("Importe d'abord un fichier finance.sqlite ou ajuste la période.")
                    )
                } else if filteredTransactions.isEmpty {
                    ContentUnavailableView(
                        "Aucun résultat",
                        systemImage: "magnifyingglass",
                        description: Text("Aucune transaction ne correspond aux filtres actifs.")
                    )
                } else {
                    List {
                        ForEach(groupedTransactions, id: \.date) { group in
                            Section(group.label) {
                                ForEach(group.transactions) { item in
                                    transactionRow(item)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if isSelecting { toggleSelection(item.id) }
                                        }
                                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                            if !isSelecting {
                                                Button {
                                                    editingTransaction = TransactionEditDraft(from: item)
                                                } label: {
                                                    Label("Modifier", systemImage: "pencil")
                                                }
                                                .tint(.blue)
                                            }
                                        }
                                }
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
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelecting {
                        Button("Annuler") { cancelSelection() }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelecting {
                        if !selectedIds.isEmpty {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Supprimer (\(selectedIds.count))", systemImage: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        // Bouton filtre (badge si actif)
                        Button { showFilters = true } label: {
                            Image(systemName: activeFiltersCount > 0
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        // Sélection
                        Button { isSelecting = true } label: {
                            Image(systemName: "checkmark.circle")
                        }
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
            .sheet(isPresented: $showFilters) {
                TransactionFiltersSheet(
                    accounts: accounts,
                    allCategories: allCategories,
                    tiersSearchText: $tiersSearchText,
                    selectedCategoryId: $selectedCategoryId,
                    grouping: $grouping,
                    onApply: { resetAndLoad() }
                )
                .environment(appState)
            }
            .sheet(item: $quickCategoryTx) { tx in
                CategoryQuickPickSheet(
                    currentCategoryId: tx.categoryId,
                    allCategories: allCategories
                ) { newId, newName in
                    if repository.updateTransactionCategory(id: tx.id, categoryId: newId) {
                        quickUpdateCategory(txId: tx.id, categoryId: newId, categoryName: newName)
                    }
                }
            }
            .sheet(item: $editingTransaction) { draft in
                TransactionEditSheet(
                    draft: draft,
                    allTiers: allTiers,
                    allCategories: allCategories,
                    allMdps: allMdps,
                    repository: repository
                ) {
                    resetAndLoad()
                }
            }
            .task(id: appState.dataRefreshToken) {
                loadInitialData()
            }
            .refreshable {
                loadInitialData()
            }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func transactionRow(_ item: FinanceTransaction) -> some View {
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIds.contains(item.id) ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                // Ligne 1 : libellé + montant
                HStack(alignment: .firstTextBaseline) {
                    Text(item.tiersName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(item.amount, format: .currency(code: "EUR"))
                        .fontWeight(.bold)
                        .foregroundStyle(item.amount < 0 ? .red : .green)
                }
                // Ligne 2 : tiers + badge catégorie
                HStack(spacing: 6) {
                    if !item.information.isEmpty {
                        Text(item.information)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Badge catégorie — tappable pour modification rapide
                    let catLabel = item.categoryName.isEmpty ? "Catégorie" : item.categoryName
                    let catColor: Color = item.categoryName.isEmpty ? .secondary : .blue
                    Button {
                        quickCategoryTx = item
                    } label: {
                        Text(catLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(catColor.opacity(0.13), in: Capsule())
                            .foregroundStyle(catColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelecting)
                }
                // Ligne 3 : moyen de paiement
                if !item.paymentTypeName.isEmpty {
                    Text(item.paymentTypeName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Chargement

    private func loadInitialData() {
        accounts      = repository.fetchAccounts()
        allTiers      = repository.fetchTiers()
        allCategories = repository.fetchCategories()
        allMdps       = repository.fetchPaymentTypes()

        if appState.selectedAccountId == nil, let first = accounts.first {
            appState.selectedAccountId   = first.id
            appState.selectedAccountName = first.name
        }
        resetAndLoad()
    }

    private func resetAndLoad() {
        guard let accountId = appState.selectedAccountId else {
            transactions = []
            return
        }
        isLoading    = true
        transactions = []
        hasMore      = true

        let page = repository.fetchTransactions(
            accountId: accountId,
            from: appState.filterFromDate,
            to: appState.filterToDate,
            limit: pageSize,
            offset: 0
        )
        transactions = page
        hasMore      = page.count == pageSize
        isLoading    = false
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore,
              let accountId = appState.selectedAccountId else { return }
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

    private func quickUpdateCategory(txId: Int, categoryId: Int?, categoryName: String) {
        guard let idx = transactions.firstIndex(where: { $0.id == txId }) else { return }
        let tx = transactions[idx]
        transactions[idx] = FinanceTransaction(
            id: tx.id, accountId: tx.accountId,
            tiersId: tx.tiersId, categoryId: categoryId, paymentTypeId: tx.paymentTypeId,
            tiersName: tx.tiersName, categoryName: categoryName, paymentTypeName: tx.paymentTypeName,
            information: tx.information, amount: tx.amount, date: tx.date
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
}

// MARK: - Filtre sheet

struct TransactionFiltersSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let allCategories: [Category]
    @Binding var tiersSearchText: String
    @Binding var selectedCategoryId: Int
    @Binding var grouping: TransactionGrouping
    let onApply: () -> Void

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Form {
                Section("Compte") {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible").foregroundStyle(.secondary)
                    } else {
                        Picker("Compte", selection: Binding(
                            get: { appState.selectedAccountId ?? accounts.first?.id ?? 0 },
                            set: { newValue in
                                appState.selectedAccountId = newValue
                                appState.selectedAccountName = accounts.first(where: { $0.id == newValue })?.name ?? "Compte"
                            }
                        )) {
                            ForEach(accounts) { a in Text(a.name).tag(a.id) }
                        }
                    }
                }

                Section("Période") {
                    DatePicker("Du", selection: $appState.filterFromDate, displayedComponents: .date)
                    DatePicker("Au", selection: $appState.filterToDate, displayedComponents: .date)
                }

                Section("Recherche") {
                    TextField("Filtrer par tiers ou libellé…", text: $tiersSearchText)
                        .autocorrectionDisabled()

                    Picker("Catégorie", selection: $selectedCategoryId) {
                        Text("Toutes").tag(-1)
                        ForEach(allCategories) { c in Text(c.name).tag(c.id) }
                    }
                }

                Section("Affichage") {
                    Picker("Grouper par", selection: $grouping) {
                        ForEach(TransactionGrouping.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Réinitialiser les filtres") {
                        tiersSearchText    = ""
                        selectedCategoryId = -1
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer") { onApply(); dismiss() }
                }
            }
        }
    }
}

// MARK: - Sélection rapide de catégorie

struct CategoryQuickPickSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentCategoryId: Int?
    let allCategories: [Category]
    let onSelect: (Int?, String) -> Void

    @State private var search = ""

    var filtered: [Category] {
        guard !search.isEmpty else { return allCategories }
        return allCategories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button("Aucune catégorie") {
                    onSelect(nil, ""); dismiss()
                }
                .foregroundStyle(.secondary)

                ForEach(filtered) { c in
                    Button {
                        onSelect(c.id, c.name); dismiss()
                    } label: {
                        HStack {
                            Text(c.name).foregroundStyle(.primary)
                            Spacer()
                            if c.id == currentCategoryId {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher une catégorie…")
            .navigationTitle("Catégorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
    }
}

// MARK: - Recherche tiers (édition)

struct TiersSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let allTiers: [Tiers]
    @Binding var selectedId: Int
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
                .foregroundStyle(.secondary)

                ForEach(filtered) { t in
                    Button {
                        selectedId = t.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(.primary)
                                if let r = t.regex, !r.isEmpty {
                                    Text(r).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedId == t.id {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
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
            }
        }
    }
}

// MARK: - Édition transaction

struct TransactionEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draft: TransactionEditDraft
    let allTiers: [Tiers]
    let allCategories: [Category]
    let allMdps: [PaymentType]
    let repository: TransactionRepository
    let onSave: () -> Void

    @State private var tiersId: Int
    @State private var categoryId: Int
    @State private var paymentTypeId: Int
    @State private var information: String
    @State private var amountText: String
    @State private var date: Date
    @State private var showTiersPicker = false

    init(draft: TransactionEditDraft, allTiers: [Tiers], allCategories: [Category],
         allMdps: [PaymentType], repository: TransactionRepository, onSave: @escaping () -> Void) {
        self.draft          = draft
        self.allTiers       = allTiers
        self.allCategories  = allCategories
        self.allMdps        = allMdps
        self.repository     = repository
        self.onSave         = onSave
        _tiersId        = State(initialValue: draft.tiersId ?? -1)
        _categoryId     = State(initialValue: draft.categoryId ?? -1)
        _paymentTypeId  = State(initialValue: draft.paymentTypeId ?? -1)
        _information    = State(initialValue: draft.information)
        _amountText     = State(initialValue: String(draft.amount))
        _date           = State(initialValue: draft.date)
    }

    private var tiersDisplayName: String {
        guard tiersId != -1 else { return "Aucun" }
        return allTiers.first(where: { $0.id == tiersId })?.name ?? "Inconnu"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Détails") {
                    TextField("Information", text: $information)
                    HStack {
                        Text("Montant")
                        Spacer()
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Classification") {
                    // Tiers : ouvre une sheet de recherche
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(.primary)
                            Spacer()
                            Text(tiersDisplayName).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(-1)
                        ForEach(allCategories) { c in Text(c.name).tag(c.id) }
                    }
                    Picker("Moyen de paiement", selection: $paymentTypeId) {
                        Text("Aucun").tag(-1)
                        ForEach(allMdps) { m in Text(m.name).tag(m.id) }
                    }
                }
            }
            .navigationTitle("Modifier la transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                }
            }
            .sheet(isPresented: $showTiersPicker) {
                TiersSearchSheet(allTiers: allTiers, selectedId: $tiersId)
            }
        }
    }

    private func save() {
        let amount = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? draft.amount
        var updated        = draft
        updated.tiersId       = tiersId == -1 ? nil : tiersId
        updated.categoryId    = categoryId == -1 ? nil : categoryId
        updated.paymentTypeId = paymentTypeId == -1 ? nil : paymentTypeId
        updated.information   = information
        updated.amount        = amount
        updated.date          = date
        repository.updateTransaction(updated)
        onSave()
        dismiss()
    }
}
