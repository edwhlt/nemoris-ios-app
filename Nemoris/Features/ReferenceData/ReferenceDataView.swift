import SwiftUI
import TipKit

struct ReferenceDataView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    private let repository = TransactionRepository()

    enum ReferenceTab: String, CaseIterable, Identifiable {
        case comptes        = "Comptes"
        case categories     = "Catégories"
        case tiers          = "Tiers"
        case moyensPaiement = "Paiement"
        case tags           = "Tags"
        var id: String { rawValue }
    }

    @State private var selectedTab: ReferenceTab = .comptes
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    @State private var tiers: [Tiers] = []
    @State private var paymentTypes: [PaymentType] = []
    @State private var tags: [Tag] = []
    @State private var payeeGroups: [PayeeGroup] = []
    /// Skeleton tant que le 1er `loadReferenceData()` n'est pas terminé.
    @State private var hasLoaded = false

    // Tri
    enum SortOrder { case alphabetical, creation }
    @State private var sortOrder: SortOrder = .alphabetical

    /// Cible d'une suppression déclenchée par swipe (avant confirmation).
    struct DeleteTarget: Identifiable {
        let id = UUID()
        let tab: ReferenceTab
        let entityId: Int
        let name: String
        let count: Int          // transactions associées
        let childIds: [Int]     // sous-catégories emportées (catégories parentes)
        let blocked: Bool       // true = suppression impossible (compte encore utilisé)
    }

    // Recherche
    @State private var searchText = ""

    // Édition / ajout
    @State private var showEditSheet = false
    @State private var editDraftName  = ""
    @State private var editDraftRegex = ""
    @State private var editDraftCategoryId: Int? = nil
    @State private var editDraftParentCategoryId: Int? = nil  // pour l'édition de catégorie
    @State private var editDraftIcon: String? = nil           // pour l'édition de catégorie
    @State private var editDraftAccountType: String = "COURANT"
    @State private var editDraftLinkedCompteId: Int? = nil
    @State private var editItemId: Int? = nil   // nil = nouvel élément

    // AXE C : édition complète d'un payee via PayeeDetailView.
    @State private var editingPayee: Tiers? = nil

    // Nombre de transactions associées, par entité (id → count).
    @State private var categoryCounts: [Int: Int] = [:]
    @State private var tierCounts: [Int: Int] = [:]
    @State private var paymentTypeCounts: [Int: Int] = [:]
    @State private var accountCounts: [Int: Int] = [:]
    @State private var tagCounts: [Int: Int] = [:]

    // Suppression unitaire par swipe (toutes les tables).
    @State private var pendingDelete: DeleteTarget? = nil

    // Arbre des catégories — recalculé à la volée pour réagir au tri.
    private var categoryForest: [CategoryNode] {
        CategoryNode.buildForest(from: categories,
                                 sort: sortOrder == .creation ? .creation : .alphabetical)
    }

    // Sélection / suppression tiers
    @State private var isSelectingTiers = false
    @State private var selectedTiersIds: Set<Int> = []
    @State private var showDeleteConfirm = false

    // Import CSV des tiers : retiré lors du cleanup AXE B (cluster SmartImport legacy supprimé).

    // MARK: Filtrage + tri

    private func sorted<T: Identifiable>(_ items: [T], name: (T) -> String) -> [T] where T.ID == Int {
        sortOrder == .alphabetical
            ? items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            : items.sorted { $0.id < $1.id }
    }

    var filteredAccounts: [Account] {
        let base = searchText.isEmpty ? accounts
            : accounts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return sorted(base, name: \.name)
    }
    var filteredCategories: [Category] {
        let base = searchText.isEmpty ? categories
            : categories.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return sorted(base, name: \.name)
    }
    var filteredTiers: [Tiers] {
        let base = searchText.isEmpty ? tiers
            : tiers.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.regex?.localizedCaseInsensitiveContains(searchText) == true)
            }
        return sorted(base, name: \.name)
    }
    var filteredPaymentTypes: [PaymentType] {
        let base = searchText.isEmpty ? paymentTypes
            : paymentTypes.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.regex?.localizedCaseInsensitiveContains(searchText) == true)
            }
        return sorted(base, name: \.name)
    }
    var filteredTags: [Tag] {
        let base = searchText.isEmpty ? tags
            : tags.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return sorted(base, name: \.name)
    }

    // MARK: Body

    var isEmbedded: Bool = false

    var body: some View {
        if isEmbedded { navBody } else { NavigationStack { navBody } }
    }

    @ViewBuilder private var navBody: some View {
            VStack(spacing: 0) {
                Picker("Table", selection: $selectedTab) {
                    ForEach(ReferenceTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)

                Divider()

                List {
                    if !hasLoaded {
                        ForEach(0..<8, id: \.self) { _ in
                            SkeletonReferenceListRow()
                                .listRowBackground(AppTheme.Colors.surface)
                        }
                    } else {
                    switch selectedTab {
                    case .comptes:
                        if filteredAccounts.isEmpty { emptyRow
                        } else if sortOrder == .alphabetical && searchText.isEmpty {
                            // Groupé par type, trié alphabétiquement
                            ForEach(accounts.groupedByType, id: \.type) { group in
                                Section(group.type.label) {
                                    ForEach(group.accounts) { a in accountRow(a) }
                                }
                            }
                        } else {
                            // Plat : résultats de recherche ou tri par création
                            ForEach(filteredAccounts) { a in accountRow(a) }
                        }
                    case .categories:
                        if categories.isEmpty {
                            emptyRow
                        } else if !searchText.isEmpty {
                            // Mode recherche : liste plate avec indicateur visuel
                            ForEach(filteredCategories) { c in
                                flatCategoryRow(c)
                            }
                        } else {
                            // Mode normal : arbre hiérarchique
                            ForEach(categoryForest) { node in
                                CategoryTreeRow(
                                    node: node,
                                    countFor: { categoryCounts[$0.id] ?? 0 },
                                    onEdit: { c in
                                        startEdit(id: c.id, name: c.name, regex: "", parentCategoryId: c.parentId, icon: c.icon)
                                    },
                                    onDelete: { n in pendingDelete = deleteTargetForNode(n) }
                                )
                            }
                        }
                    case .tiers:
                        if filteredTiers.isEmpty { emptyRow } else {
                            ForEach(filteredTiers) { t in
                                HStack(spacing: 12) {
                                    if isSelectingTiers {
                                        Image(systemName: selectedTiersIds.contains(t.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedTiersIds.contains(t.id) ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
                                            .imageScale(.large)
                                    }
                                    MerchantLogo(tiers: t, allCategories: categories, size: 36)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.name)
                                        if let subtitle = tierSubtitle(t) {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if t.linkedCompteId != nil {
                                        Image(systemName: "arrow.left.arrow.right")
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                                    }
                                    EntityIdCountBadge(id: t.id, count: tierCounts[t.id] ?? 0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isSelectingTiers {
                                        if selectedTiersIds.contains(t.id) { selectedTiersIds.remove(t.id) }
                                        else { selectedTiersIds.insert(t.id) }
                                    } else {
                                        editingPayee = t
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !isSelectingTiers {
                                        deleteSwipe(DeleteTarget(tab: .tiers, entityId: t.id, name: t.name,
                                                                 count: tierCounts[t.id] ?? 0, childIds: [], blocked: false))
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if !isSelectingTiers {
                                        editButton { editingPayee = t }
                                    }
                                }
                            }
                        }
                    case .moyensPaiement:
                        if filteredPaymentTypes.isEmpty { emptyRow } else {
                            ForEach(filteredPaymentTypes) { p in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(p.name)
                                        if let r = p.regex, !r.isEmpty {
                                            Text(r).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    EntityIdCountBadge(id: p.id, count: paymentTypeCounts[p.id] ?? 0)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    deleteSwipe(DeleteTarget(tab: .moyensPaiement, entityId: p.id, name: p.name,
                                                             count: paymentTypeCounts[p.id] ?? 0, childIds: [], blocked: false))
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    editButton { startEdit(id: p.id, name: p.name, regex: p.regex ?? "") }
                                }
                            }
                        }
                    case .tags:
                        if filteredTags.isEmpty { emptyRow } else {
                            ForEach(filteredTags) { tag in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(tag.displayColor)
                                        .frame(width: 10, height: 10)
                                    Text(tag.name)
                                    Spacer()
                                    EntityIdCountBadge(id: tag.id, count: tagCounts[tag.id] ?? 0)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    deleteSwipe(DeleteTarget(tab: .tags, entityId: tag.id, name: tag.name,
                                                             count: tagCounts[tag.id] ?? 0, childIds: [], blocked: false))
                                }
                            }
                        }
                    }
                    }  // end else (hasLoaded)
                }
                .searchable(text: $searchText, prompt: "Rechercher…")
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectingTiers && !selectedTiersIds.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            selectedTiersIds = Set(filteredTiers.map(\.id))
                        } label: {
                            Text("Tout sélectionner").font(.callout)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer \(selectedTiersIds.count)", systemImage: "trash")
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .navigationTitle("Données")
            .toolbar {
                // Bouton Sélectionner/Annuler (tiers uniquement, leading)
                if selectedTab == .tiers {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(isSelectingTiers ? "Annuler" : "Sélectionner") {
                            isSelectingTiers.toggle()
                            selectedTiersIds = []
                        }
                        .foregroundStyle(isSelectingTiers ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                    }
                }
                // Actions secondaires dans un Menu explicite + bouton +
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { startAdd() } label: { Image(systemName: "plus") }
                        .opacity(isSelectingTiers ? 0 : 1)
                        .disabled(isSelectingTiers)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            sortOrder = sortOrder == .alphabetical ? .creation : .alphabetical
                        } label: {
                            Label(
                                sortOrder == .alphabetical ? "Trier par création" : "Trier par ordre alphabétique",
                                systemImage: sortOrder == .alphabetical ? "clock" : "textformat.abc"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .opacity(isSelectingTiers ? 0 : 1)
                    .disabled(isSelectingTiers)
                }
            }
            .sheet(isPresented: $showEditSheet) {
                editSheet
            }
            .sheet(item: $editingPayee) { payee in
                PayeeDetailView(
                    payee: payee,
                    allCategories: categories,
                    allAccounts: accounts,
                    onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() }
                )
            }
            .confirmationDialog(
                "Supprimer \(selectedTiersIds.count) tiers ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    repository.deleteTiers(ids: selectedTiersIds)
                    loadReferenceData()
                    appState.dataRefreshToken = UUID()
                    isSelectingTiers = false
                    selectedTiersIds = []
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les transactions associées seront conservées mais sans tiers assigné.")
            }
            .confirmationDialog(
                pendingDelete.map { "Supprimer « \($0.name) » ?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { target in
                if target.blocked {
                    Button("OK", role: .cancel) {}
                } else {
                    Button("Supprimer", role: .destructive) { performDelete(target) }
                    Button("Annuler", role: .cancel) {}
                }
            } message: { target in
                Text(deleteMessage(target))
            }
            .onChange(of: selectedTab) { _, _ in
                isSelectingTiers = false
                selectedTiersIds = []
            }
            .task(id: appState.dataRefreshToken) {
                // 1-frame guard pour afficher le skeleton avant la lecture SQLite.
                await Task.yield()
                loadReferenceData()
                hasLoaded = true
            }
            .refreshable { loadReferenceData() }
    }

    // MARK: Edit sheet

    @ViewBuilder
    private var editSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom", text: $editDraftName)
                        .autocorrectionDisabled()
                    if selectedTab == .tiers || selectedTab == .moyensPaiement {
                        TextField("Regex (optionnel)", text: $editDraftRegex)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                if selectedTab == .comptes {
                    Section("Type de compte") {
                        Picker("Type", selection: $editDraftAccountType) {
                            ForEach(AccountType.allCases, id: \.rawValue) { t in
                                Text(t.label).tag(t.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if selectedTab == .tiers {
                    Section {
                        TipView(TiersRegexTip(), arrowEdge: .none)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section("Catégorie par défaut") {
                        Picker("Catégorie", selection: $editDraftCategoryId) {
                            Text("Non catégorisé").tag(Int?.none)
                            ForEach(categories) { c in
                                Text(c.name).tag(Int?.some(c.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("Virement interne") {
                        Picker("Compte lié", selection: $editDraftLinkedCompteId) {
                            Text("Aucun (tiers externe)").tag(Int?.none)
                            ForEach(accounts.groupedByType, id: \.type) { group in
                                Section(group.type.label) {
                                    ForEach(group.accounts) { a in
                                        Text(a.name).tag(Int?.some(a.id))
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if selectedTab == .categories {
                    Section {
                        TipView(CategoryHierarchyTip(), arrowEdge: .none)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section("Catégorie parente") {
                        // Seules les racines (sans parent) peuvent être choisies comme parent
                        let roots = categories.filter { $0.parentId == nil && $0.id != editItemId }
                        Picker("Parent", selection: $editDraftParentCategoryId) {
                            Text("Aucun (catégorie racine)").tag(Int?.none)
                            ForEach(roots) { c in
                                Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section {
                        NavigationLink {
                            ScrollView {
                                CategoryIconPicker(
                                    selectedIcon: $editDraftIcon,
                                    categoryName: editDraftName,
                                    isParent: editDraftParentCategoryId == nil
                                )
                                .padding()
                            }
                            .background(Color(.systemGroupedBackground))
                            .navigationTitle("Choisir une icône")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(AppTheme.Colors.accent.opacity(0.15))
                                        .frame(width: 32, height: 32)
                                    // Affiche l'icône RÉELLEMENT utilisée — soit celle stockée,
                                    // soit le fallback auto calculé sur le nom.
                                    Image(systemName: previewCategoryIcon)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppTheme.Colors.accent)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Icône")
                                        .font(.body)
                                    Text(editDraftIcon == nil
                                         ? "Auto (selon le nom) — tap pour personnaliser"
                                         : "Personnalisée — tap pour modifier")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                        }
                    } header: { Text("Icône") }
                    footer: {
                        if editDraftIcon == nil {
                            Text("Si tu ne choisis rien, l'icône est calculée automatiquement depuis le nom. Toute icône choisie est mémorisée et a la priorité.")
                        }
                    }
                }
            }
            .navigationTitle(editItemId == nil ? "Ajouter" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showEditSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { saveEdit() }
                        .disabled(editDraftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: Helpers

    private var emptyRow: some View {
        Text(searchText.isEmpty
             ? "Aucune donnée. Importe d'abord un fichier sqlite ou commence à les ajouter."
             : "Aucun résultat pour « \(searchText) »")
            .foregroundStyle(AppTheme.Colors.textSecondary)
    }

    @ViewBuilder
    private func accountRow(_ a: Account) -> some View {
        Button {
            appState.selectedAccountId = a.id
            appState.selectedAccountName = a.name
            appState.selectedTab = MainTabItem.transactions.rawValue
        } label: {
            HStack {
                Text(a.name).foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                if a.accountType != .courant {
                    Text(a.accountType.label)
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accountTypeColor(a.accountType), in: Capsule())
                }
                EntityIdCountBadge(id: a.id, count: accountCounts[a.id] ?? 0)
                if appState.selectedAccountId == a.id {
                    Image(systemName: "checkmark")
                        .font(.caption).foregroundStyle(AppTheme.Colors.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteSwipe(DeleteTarget(tab: .comptes, entityId: a.id, name: a.name,
                                     count: accountCounts[a.id] ?? 0, childIds: [],
                                     blocked: (accountCounts[a.id] ?? 0) > 0))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            editButton { startEdit(id: a.id, name: a.name, regex: "", accountType: a.type) }
        }
    }

    @ViewBuilder
    private func editButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Modifier", systemImage: "pencil") }
            .tint(AppTheme.Colors.accent)
    }

    private func startEdit(id: Int, name: String, regex: String, categoryId: Int? = nil, parentCategoryId: Int? = nil, icon: String? = nil, accountType: String = "COURANT", linkedCompteId: Int? = nil) {
        editItemId = id
        editDraftName = name
        editDraftRegex = regex
        editDraftCategoryId = categoryId
        editDraftParentCategoryId = parentCategoryId
        editDraftIcon = icon
        editDraftAccountType = accountType
        editDraftLinkedCompteId = linkedCompteId
        showEditSheet = true
    }

    private func startAdd() {
        editItemId = nil
        editDraftName = ""
        editDraftRegex = ""
        editDraftCategoryId = nil
        editDraftParentCategoryId = nil
        editDraftIcon = nil
        editDraftAccountType = "COURANT"
        editDraftLinkedCompteId = nil
        showEditSheet = true
    }

    private func saveEdit() {
        let name  = editDraftName.trimmingCharacters(in: .whitespaces)
        let regex = editDraftRegex.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch selectedTab {
        case .comptes:
            if let id = editItemId { repository.updateAccount(id: id, name: name, type: editDraftAccountType) }
            else { repository.addAccount(name: name, type: editDraftAccountType) }
        case .categories:
            if let id = editItemId { repository.updateCategory(id: id, name: name, parentId: editDraftParentCategoryId, icon: editDraftIcon) }
            else { repository.addCategory(name: name, parentId: editDraftParentCategoryId, icon: editDraftIcon) }
        case .tiers:
            if let id = editItemId { repository.updateTiers(id: id, name: name, regex: regex, categoryId: editDraftCategoryId, linkedCompteId: editDraftLinkedCompteId) }
            else { repository.addTiers(name: name, regex: regex, categoryId: editDraftCategoryId, linkedCompteId: editDraftLinkedCompteId) }
        case .moyensPaiement:
            if let id = editItemId { repository.updatePaymentType(id: id, name: name, regex: regex) }
            else { repository.addPaymentType(name: name, regex: regex) }
        case .tags:
            break  // Les tags ne sont pas éditables ici
        }
        loadReferenceData()
        showEditSheet = false
    }

    private func loadReferenceData() {
        accounts        = repository.fetchAccounts()
        categories      = repository.fetchCategories()
        tiers           = repository.fetchTiers()
        paymentTypes    = repository.fetchPaymentTypes()
        tags            = repository.fetchAllTags()
        payeeGroups     = repository.fetchPayeeGroups()

        // Compteurs de transactions associées (une passe GROUP BY par table).
        categoryCounts    = repository.countTransactionsByCategory()
        tierCounts        = repository.countTransactionsByPayee()
        paymentTypeCounts = repository.countTransactionsByPaymentType()
        accountCounts     = repository.countTransactionsByAccount()
        tagCounts         = repository.countTransactionsByTag()
    }

    // MARK: Suppression

    /// Nombre de transactions d'une catégorie, sous-catégories incluses.
    private func categoryTransactionCount(_ ids: [Int]) -> Int {
        ids.reduce(0) { $0 + (categoryCounts[$1] ?? 0) }
    }

    private func performDelete(_ target: DeleteTarget) {
        switch target.tab {
        case .comptes:        repository.deleteAccount(id: target.entityId)
        case .categories:     repository.deleteCategory(id: target.entityId, includingChildren: target.childIds)
        case .tiers:          repository.deleteTiers(ids: [target.entityId])
        case .moyensPaiement: repository.deletePaymentType(id: target.entityId)
        case .tags:           repository.deleteTag(id: target.entityId)
        }
        loadReferenceData()
        appState.dataRefreshToken = UUID()
    }

    private func deleteMessage(_ target: DeleteTarget) -> String {
        if target.blocked {
            return "« \(target.name) » porte \(target.count) transaction\(target.count > 1 ? "s" : ""). Réassigne-les à un autre compte avant de le supprimer."
        }
        if target.count == 0 && target.childIds.isEmpty {
            return "« \(target.name) » n'est associé à aucune transaction."
        }
        var parts: [String] = []
        if !target.childIds.isEmpty {
            parts.append("\(target.childIds.count) sous-catégorie\(target.childIds.count > 1 ? "s" : "") supprimée\(target.childIds.count > 1 ? "s" : "")")
        }
        if target.count > 0 {
            let noun: String
            switch target.tab {
            case .tags:    noun = "détaguée"
            default:       noun = "conservée"
            }
            parts.append("\(target.count) transaction\(target.count > 1 ? "s" : "") \(noun)\(target.count > 1 ? "s" : "")")
        }
        return parts.isEmpty ? "Supprimer « \(target.name) » ?" : parts.joined(separator: " · ") + "."
    }

    /// Bouton de suppression (swipe leading = « glisser à droite »).
    @ViewBuilder
    private func deleteSwipe(_ target: DeleteTarget) -> some View {
        Button(role: .destructive) { pendingDelete = target } label: {
            Label("Supprimer", systemImage: "trash")
        }
        .tint(AppTheme.Colors.danger)
    }


    /// Icône à afficher dans la preview de la sheet d'édition : reflète l'icône RÉELLE
    /// utilisée à l'affichage (custom si définie, sinon fallback auto sur le nom).
    private var previewCategoryIcon: String {
        Category(
            id: editItemId ?? 0,
            name: editDraftName,
            parentId: editDraftParentCategoryId,
            icon: editDraftIcon
        ).displayIcon
    }

    /// Sous-titre d'un tier dans la liste : ville · pays · groupe (les champs vides sont skip).
    private func tierSubtitle(_ t: Tiers) -> String? {
        var parts: [String] = []
        if let c = t.city, !c.isEmpty { parts.append(c) }
        if let cc = t.country, !cc.isEmpty { parts.append(cc.uppercased()) }
        if let gid = t.groupId,
           let g = payeeGroups.first(where: { $0.id == gid }) {
            parts.append(g.displayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Account type helpers

    private func accountTypeColor(_ type: AccountType) -> Color {
        switch type {
        case .courant: return AppTheme.Colors.accent
        case .epargne: return AppTheme.Colors.success
        case .differe: return AppTheme.Colors.warning
        case .autre:   return AppTheme.Colors.textSecondary
        }
    }

    // MARK: - Category helpers

    /// Ligne plate pour le mode recherche
    @ViewBuilder
    private func flatCategoryRow(_ c: Category) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill((c.parentId == nil ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary).opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: c.displayIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(c.parentId == nil ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            }
            if c.parentId != nil {
                Text("↳").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
            Text(c.name)
                .fontWeight(c.parentId == nil ? .semibold : .regular)
            Spacer()
            EntityIdCountBadge(id: c.id, count: categoryCounts[c.id] ?? 0)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteSwipe(deleteTargetForCategory(c))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            editButton { startEdit(id: c.id, name: c.name, regex: "", parentCategoryId: c.parentId, icon: c.icon) }
        }
    }

    /// Construit la cible de suppression d'une catégorie, en emportant ses sous-catégories.
    private func deleteTargetForCategory(_ c: Category) -> DeleteTarget {
        let childIds = categories.filter { $0.parentId == c.id }.map(\.id)
        let allIds = [c.id] + childIds
        return DeleteTarget(tab: .categories, entityId: c.id, name: c.name,
                            count: categoryTransactionCount(allIds), childIds: childIds, blocked: false)
    }

    /// Idem depuis un nœud de l'arbre (emporte toute la sous-arborescence).
    private func deleteTargetForNode(_ node: CategoryNode) -> DeleteTarget {
        let allIds = node.allIds()
        let childIds = Array(allIds.dropFirst())
        return DeleteTarget(tab: .categories, entityId: node.category.id, name: node.category.name,
                            count: categoryTransactionCount(allIds), childIds: childIds, blocked: false)
    }

}

// MARK: - CategoryTreeRow

/// Nœud de l'arbre des catégories avec visuels distincts parent / enfant.
private struct CategoryTreeRow: View {
    let node: CategoryNode
    let countFor: (Category) -> Int
    let onEdit: (Category) -> Void
    let onDelete: (CategoryNode) -> Void
    @State private var isExpanded = true

    var body: some View {
        if node.isLeaf {
            leafRow(node.category, isRootLevel: node.category.parentId == nil)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    CategoryTreeRow(node: child, countFor: countFor, onEdit: onEdit, onDelete: onDelete)
                }
            } label: {
                parentLabel(node)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { onDelete(node) } label: { Label("Supprimer", systemImage: "trash") }
                            .tint(AppTheme.Colors.danger)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { onEdit(node.category) } label: { Label("Modifier", systemImage: "pencil") }
                            .tint(AppTheme.Colors.accent)
                    }
            }
        }
    }


    @ViewBuilder
    private func parentLabel(_ node: CategoryNode) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: node.category.displayIcon)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(node.category.name)
                .fontWeight(.semibold)
            Spacer()
            EntityIdCountBadge(id: node.category.id, count: countFor(node.category))
            Text("\(node.children.count)")
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(AppTheme.Colors.accent, in: Capsule())
        }
    }

    @ViewBuilder
    private func leafRow(_ category: Category, isRootLevel: Bool) -> some View {
        HStack(spacing: 10) {
            if isRootLevel {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.textSecondary.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: category.displayIcon)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.system(size: 13))
                }
            } else {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppTheme.Colors.accent.opacity(0.25))
                        .frame(width: 2, height: 18)
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.10))
                            .frame(width: 24, height: 24)
                        Image(systemName: category.displayIcon)
                            .foregroundStyle(AppTheme.Colors.accent.opacity(0.8))
                            .font(.system(size: 11))
                    }
                }
            }
            Text(category.name).foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            EntityIdCountBadge(id: category.id, count: countFor(category))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDelete(node) } label: { Label("Supprimer", systemImage: "trash") }
                .tint(AppTheme.Colors.danger)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { onEdit(category) } label: { Label("Modifier", systemImage: "pencil") }
                .tint(AppTheme.Colors.accent)
        }
    }
}

// MARK: - Icon picker for categories

/// Badge combiné « identifiant technique + usage ».
///
/// Les deux informations sont volontairement DISTINCTES visuellement :
///   - `#42` en monospace discret = l'ID en base (utile pour la console SQL,
///     les rapprochements et le debug) ;
///   - la capsule ⟷ N = le nombre de transactions associées.
/// Avant, seul le compteur était affiché et l'ID n'était plus consultable
/// depuis l'UI.
private struct EntityIdCountBadge: View {
    let id: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(id)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                .accessibilityLabel("Identifiant \(id)")

            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(count)")
                    .font(.caption2).fontWeight(.medium)
            }
            .foregroundStyle(count == 0
                             ? AppTheme.Colors.textSecondary.opacity(0.4)
                             : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((count == 0 ? Color.clear : AppTheme.Colors.textSecondary.opacity(0.12)),
                        in: Capsule())
            .accessibilityLabel("\(count) transaction(s)")
        }
    }
}

private struct CategoryIconPicker: View {
    @Binding var selectedIcon: String?
    let categoryName: String
    let isParent: Bool
    @Environment(\.dismiss) private var dismiss

    /// Icône RÉELLEMENT utilisée (custom si définie, sinon fallback auto sur le nom).
    private var effectiveIcon: String {
        Category(id: 0, name: categoryName, parentId: isParent ? nil : 1, icon: selectedIcon).displayIcon
    }

    /// Filtre de recherche dans le catalogue (et saisie libre d'un nom SF Symbol).
    @State private var searchText = ""

    /// Existence d'un SF Symbol sur l'OS courant. Permet (a) d'accepter la
    /// saisie libre de N'IMPORTE lequel des milliers de symboles Apple sans
    /// embarquer la liste complète, et (b) de filtrer le catalogue pour ne
    /// jamais afficher une case vide si un symbole n'existe pas sur cette version.
    nonisolated private static func symbolExists(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        #if os(macOS)
        return NSImage(systemSymbolName: clean, accessibilityDescription: nil) != nil
        #else
        return UIKit.UIImage(systemName: clean) != nil
        #endif
    }

    /// Catalogue brut, largement étendu (~230 symboles) et thématisé.
    /// Il ne prétend PAS couvrir les 5000+ SF Symbols : la saisie libre en haut
    /// de la sheet donne accès à tout le reste.
    private static let rawGroups: [(title: String, icons: [String])] = [
        ("Alimentation", ["cart.fill", "basket.fill", "fork.knife", "cup.and.saucer.fill", "mug.fill",
                          "wineglass.fill", "birthday.cake.fill", "fish.fill", "carrot.fill",
                          "takeoutbag.and.cup.and.straw.fill", "popcorn.fill", "leaf.fill", "flame.fill"]),
        ("Transport",    ["car.fill", "car.2.fill", "bolt.car.fill", "tram.fill", "bus.fill", "ferry.fill",
                          "fuelpump.fill", "airplane", "bicycle", "scooter", "figure.walk", "parkingsign",
                          "road.lanes", "truck.box.fill", "train.side.front.car"]),
        ("Logement",     ["house.fill", "house.lodge.fill", "building.2.fill", "key.fill", "bolt.fill",
                          "wifi", "lightbulb.fill", "wrench.and.screwdriver.fill", "bed.double.fill",
                          "sofa.fill", "shower.fill", "spigot.fill", "washer.fill", "chair.fill",
                          "lamp.floor.fill", "hammer.fill", "paintbrush.fill"]),
        ("Santé",        ["heart.fill", "stethoscope", "pills.fill", "cross.fill", "cross.case.fill",
                          "bandage.fill", "syringe.fill", "eye.fill", "ear.fill", "brain.head.profile",
                          "lungs.fill", "tooth.fill", "waveform.path.ecg", "facemask.fill"]),
        ("Loisirs",      ["gamecontroller.fill", "film.fill", "music.note", "headphones", "book.fill",
                          "photo.fill", "theatermasks.fill", "ticket.fill", "tv.fill", "guitars.fill",
                          "paintpalette.fill", "puzzlepiece.fill", "die.face.5.fill", "camera.fill",
                          "binoculars.fill", "party.popper.fill"]),
        ("Sport",        ["figure.run", "figure.hiking", "figure.pool.swim", "figure.outdoor.cycle",
                          "sportscourt.fill", "trophy.fill", "dumbbell.fill", "figure.yoga",
                          "figure.strengthtraining.traditional", "soccerball", "basketball.fill",
                          "tennis.racket", "figure.skiing.downhill", "medal.fill"]),
        ("Shopping",     ["bag.fill", "tag.fill", "gift.fill", "tshirt.fill", "watch.analog", "sparkles",
                          "shippingbox.fill", "cart.badge.plus", "handbag.fill", "eyeglasses",
                          "shoeprints.fill", "scissors", "comb.fill"]),
        ("Finance",      ["banknote.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
                          "chart.pie.fill", "chart.bar.fill", "arrow.uturn.left.circle.fill",
                          "creditcard.fill", "dollarsign.circle.fill", "eurosign.circle.fill", "percent",
                          "wallet.pass.fill", "signature", "doc.text.fill", "scalemass.fill",
                          "arrow.left.arrow.right", "bitcoinsign.circle.fill", "giftcard.fill"]),
        ("Travail",      ["briefcase.fill", "laptopcomputer", "desktopcomputer", "printer.fill",
                          "person.2.fill", "person.crop.circle.fill", "calendar", "clock.fill",
                          "envelope.fill", "phone.fill", "folder.fill", "tray.full.fill",
                          "pencil.and.ruler.fill", "chart.xyaxis.line", "network"]),
        ("Éducation",    ["graduationcap.fill", "book.closed.fill", "books.vertical.fill", "pencil",
                          "highlighter", "text.book.closed.fill", "globe.europe.africa.fill",
                          "function", "atom", "testtube.2", "backpack.fill", "ruler.fill"]),
        ("Famille",      ["figure.2.and.child.holdinghands", "figure.and.child.holdinghands",
                          "person.3.fill", "heart.circle.fill", "pawprint.fill", "dog.fill", "cat.fill",
                          "stroller.fill", "teddybear.fill", "balloon.2.fill", "hands.clap.fill"]),
        ("Voyage",       ["suitcase.fill", "beach.umbrella.fill", "map.fill", "mappin.and.ellipse",
                          "globe", "tent.fill", "mountain.2.fill", "sun.max.fill", "snowflake",
                          "camera.viewfinder", "passport", "signpost.right.fill"]),
        ("Technologie",  ["iphone", "ipad", "applewatch", "airpods.gen3", "display", "externaldrive.fill",
                          "internaldrive.fill", "server.rack", "antenna.radiowaves.left.and.right",
                          "cloud.fill", "lock.fill", "shield.fill", "cpu.fill", "battery.100percent",
                          "cable.connector", "gearshape.fill"]),
        ("Nature",       ["leaf.fill", "tree.fill", "drop.fill", "flame.fill", "wind", "cloud.rain.fill",
                          "moon.stars.fill", "sunrise.fill", "water.waves", "bird.fill", "ant.fill",
                          "camera.macro", "globe.americas.fill"]),
        ("Divers",       ["star.fill", "bell.fill", "paperclip", "ellipsis.circle.fill",
                          "questionmark.circle.fill", "folder.fill", "repeat", "flag.fill",
                          "bookmark.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill",
                          "trash.fill", "archivebox.fill", "square.grid.2x2.fill", "circle.hexagongrid.fill",
                          "infinity", "number"]),
    ]

    /// Catalogue effectif : symboles réellement disponibles sur cet OS (calculé
    /// une seule fois). Évite les cases vides si un symbole a été introduit dans
    /// une version d'iOS/macOS plus récente que celle de l'appareil.
    private static let groups: [(title: String, icons: [String])] = rawGroups
        .map { (title: $0.title, icons: $0.icons.filter(symbolExists)) }
        .filter { !$0.icons.isEmpty }

    /// Catalogue filtré par la recherche (sur le nom du symbole ET le thème).
    private var filteredGroups: [(title: String, icons: [String])] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.groups }
        return Self.groups
            .map { group in
                group.title.lowercased().contains(q)
                    ? group
                    : (title: group.title, icons: group.icons.filter { $0.lowercased().contains(q) })
            }
            .filter { !$0.icons.isEmpty }
    }

    /// Nom SF Symbol saisi à la main, valide et absent du catalogue → proposé
    /// tel quel. C'est ce qui ouvre l'accès aux milliers de symboles Apple.
    private var customSymbolCandidate: String? {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, Self.symbolExists(q) else { return nil }
        let alreadyListed = filteredGroups.contains { $0.icons.contains(q) }
        return alreadyListed ? nil : q
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current selection — affiche TOUJOURS l'icône réellement utilisée (custom
            // ou fallback auto), pas un tag.fill générique.
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: effectiveIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedIcon == nil ? "Icône automatique" : "Icône personnalisée")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(effectiveIcon)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if selectedIcon == nil {
                        Text("Calculée depuis le nom « \(categoryName) »")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                }
                Spacer()
                if selectedIcon != nil {
                    Button {
                        selectedIcon = nil
                    } label: {
                        Label("Auto", systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Recherche dans le catalogue + saisie libre d'un nom SF Symbol.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    TextField("Rechercher une icône (ex. « car », « heart »)", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(AppTheme.Colors.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                Text("Tape le nom exact d'un SF Symbol pour utiliser n'importe quelle icône Apple.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
            }

            // Symbole saisi à la main, valide et hors catalogue → utilisable directement.
            if let custom = customSymbolCandidate {
                Button {
                    selectedIcon = custom
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: custom)
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.Colors.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Utiliser « \(custom) »")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text("Symbole SF valide")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .padding(8)
                    .background(AppTheme.Colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // Aucun résultat ET saisie non reconnue → message explicite.
            if filteredGroups.isEmpty && customSymbolCandidate == nil && !searchText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Aucune icône trouvée. « \(searchText) » n'est pas un SF Symbol connu.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            }

            // Icon grid grouped by theme
            ForEach(filteredGroups, id: \.title) { group in
                Text(group.title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(group.icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                            dismiss()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedIcon == icon
                                          ? AppTheme.Colors.accent.opacity(0.25)
                                          : AppTheme.Colors.textPrimary.opacity(0.06))
                                Image(systemName: icon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(selectedIcon == icon ? AppTheme.Colors.accent : AppTheme.Colors.textPrimary)
                            }
                            .frame(height: 38)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedIcon == icon ? AppTheme.Colors.accent : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
