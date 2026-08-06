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
        // ⚠️ « Moyens de paiement » a été RETIRÉ (migration v46). Ce n'est plus
        // un concept de premier ordre : il est devenu une métadonnée libre
        // parmi d'autres, gérée depuis la fiche transaction. Le laisser ici
        // aurait donné deux endroits où éditer la même information — la
        // coexistence explicitement écartée.
        //
        // La table `payment_types` reste en base, dépréciée et non lue
        // (doctrine AXE H : on ne supprime qu'une fois certain que plus rien
        // ne la référence), ce qui rend la bascule réversible.
        case metadata       = "Métadonnées"
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
    /// Sélecteur d'icône catégorie : présentation par état (pas un `NavigationLink`
    /// push) — un push depuis un formulaire hébergé dans le panneau macOS n'a pas
    /// de `NavigationStack` ambiante fiable (cf. CLAUDE.md, crashs NavigationLink
    /// macOS). Fonctionne identiquement sur iOS.
    @State private var showIconPicker = false

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

    /// Cible du panneau détail macOS (clic sur une row compte / catégorie /
    /// moyen de paiement / tag). Jamais settée sur iOS (les taps y gardent
    /// leur comportement historique).
    enum ReferenceDetailTarget: Identifiable {
        case account(Account)
        case category(Category)
        case paymentType(PaymentType)
        case tag(Tag)

        var id: String {
            switch self {
            case .account(let a):     return "account_\(a.id)"
            case .category(let c):    return "category_\(c.id)"
            case .paymentType(let p): return "payment_\(p.id)"
            case .tag(let t):         return "tag_\(t.id)"
            }
        }
    }
    @State private var detailTarget: ReferenceDetailTarget? = nil

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
    //
    // ⚠️ Ces listes sont mises en CACHE dans `@State`, elles ne sont PAS des
    // propriétés calculées. En calculé, chaque évaluation du `body` les relisait
    // deux fois (test `.isEmpty`, puis `ForEach`) → deux tris localisés complets
    // sur ~1000 tiers à chaque frappe clavier, chaque bascule d'onglet et chaque
    // toggle de sélection. Recalcul uniquement via `recomputeFiltered()`.
    @State private var filteredAccounts: [Account] = []
    @State private var filteredCategories: [Category] = []
    @State private var filteredTiers: [Tiers] = []
    @State private var filteredPaymentTypes: [PaymentType] = []
    @State private var filteredTags: [Tag] = []

    /// Recherche réellement appliquée aux listes = `searchText` debouncé
    /// (cf. `.task(id: searchText)`), pour ne pas refiltrer à chaque caractère.
    @State private var appliedSearch = ""

    /// Pagination de l'onglet Tiers — la seule table volumineuse (~1000 lignes).
    /// Même principe que `TransactionsView` : on ne matérialise que les premières
    /// lignes, la suite s'ajoute quand la sentinelle de fin de liste apparaît.
    private let tiersPageSize = 100
    @State private var tiersDisplayLimit = 100

    private var visibleTiers: [Tiers] {
        tiersDisplayLimit >= filteredTiers.count
            ? filteredTiers
            : Array(filteredTiers.prefix(tiersDisplayLimit))
    }

    private func sorted<T: Identifiable>(_ items: [T], name: (T) -> String) -> [T] where T.ID == Int {
        sortOrder == .alphabetical
            ? items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            : items.sorted { $0.id < $1.id }
    }

    /// Reconstruit les 5 listes affichées. `resetPaging` remet l'onglet Tiers à sa
    /// première page : vrai quand la recherche ou le tri change (le contenu n'a
    /// plus rien à voir), faux sur un simple rechargement des données (on ne veut
    /// pas ramener l'utilisateur en haut de liste après une suppression).
    private func recomputeFiltered(resetPaging: Bool) {
        let q = appliedSearch

        filteredAccounts = sorted(
            q.isEmpty ? accounts
                      : accounts.filter { $0.name.localizedCaseInsensitiveContains(q) },
            name: \.name)

        filteredCategories = sorted(
            q.isEmpty ? categories
                      : categories.filter { $0.name.localizedCaseInsensitiveContains(q) },
            name: \.name)

        filteredTiers = sorted(
            q.isEmpty ? tiers
                      : tiers.filter {
                            $0.name.localizedCaseInsensitiveContains(q)
                            || ($0.regex?.localizedCaseInsensitiveContains(q) == true)
                        },
            name: \.name)

        filteredPaymentTypes = sorted(
            q.isEmpty ? paymentTypes
                      : paymentTypes.filter {
                            $0.name.localizedCaseInsensitiveContains(q)
                            || ($0.regex?.localizedCaseInsensitiveContains(q) == true)
                        },
            name: \.name)

        filteredTags = sorted(
            q.isEmpty ? tags
                      : tags.filter { $0.name.localizedCaseInsensitiveContains(q) },
            name: \.name)

        if resetPaging {
            tiersDisplayLimit = tiersPageSize
        } else {
            // On garde la page atteinte, sans dépasser le nouveau total.
            tiersDisplayLimit = max(tiersPageSize, min(tiersDisplayLimit, filteredTiers.count))
        }
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
                                    onDelete: { n in pendingDelete = deleteTargetForNode(n) },
                                    onSelect: { c in detailTarget = .category(c) }
                                )
                            }
                        }
                    case .tiers:
                        if filteredTiers.isEmpty { emptyRow } else {
                            ForEach(visibleTiers) { t in
                                TierRow(tiers: t,
                                        allCategories: categories,
                                        subtitle: tierSubtitle(t),
                                        count: tierCounts[t.id] ?? 0,
                                        isSelecting: isSelectingTiers,
                                        isSelected: selectedTiersIds.contains(t.id))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isSelectingTiers {
                                            if selectedTiersIds.contains(t.id) { selectedTiersIds.remove(t.id) }
                                            else { selectedTiersIds.insert(t.id) }
                                        } else {
                                            editingPayee = t
                                        }
                                    }
                                    .rowActions(
                                        leading: isSelectingTiers ? [] : [editAction { editingPayee = t }],
                                        trailing: isSelectingTiers ? [] : [deleteAction(DeleteTarget(tab: .tiers, entityId: t.id, name: t.name,
                                                                                                     count: tierCounts[t.id] ?? 0, childIds: [], blocked: false))],
                                        leadingFullSwipe: false,
                                        trailingFullSwipe: false
                                    )
                            }
                            // Sentinelle de pagination : son apparition à l'écran
                            // déclenche le chargement de la page suivante.
                            if filteredTiers.count > visibleTiers.count {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .listRowBackground(AppTheme.Colors.surface)
                                .onAppear { tiersDisplayLimit += tiersPageSize }
                            }
                        }
                    case .metadata:
                        // ⚠️ Contenu extrait dans sa propre vue : ce `switch`
                        // atteignait la limite de type-check du compilateur.
                        MetadataKeysTabContent(searchText: searchText)
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
                                .contentShape(Rectangle())
                                .macDetailTap { detailTarget = .tag(tag) }
                                .rowActions(
                                    trailing: [deleteAction(DeleteTarget(tab: .tags, entityId: tag.id, name: tag.name,
                                                                         count: tagCounts[tag.id] ?? 0, childIds: [], blocked: false))],
                                    trailingFullSwipe: false
                                )
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
                // Actions secondaires + bouton + groupés dans UNE pilule sur macOS.
                // `ToolbarItemGroup` (et NON `ControlGroup`, qui rendait des boutons
                // isolés) : c'est le groupement natif de la barre d'outils.
                // Icônes seules + tooltip natif `.help`, cohérent avec le reste.
                #if os(macOS)
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Binding custom : `startAdd()` réinitialise plusieurs champs
                    // brouillon — doit rester déclenché à l'OUVERTURE, pas à
                    // chaque bascule (la fermeture n'a rien à réinitialiser).
                    PaneToggleButton(label: "Ajouter", systemImage: "plus", isOn: Binding(
                        get: { showEditSheet },
                        set: { newValue in
                            if newValue { startAdd() } else { showEditSheet = false }
                        }
                    ))
                        .opacity(isSelectingTiers ? 0 : 1)
                        .disabled(isSelectingTiers)
                    Button {
                        sortOrder = sortOrder == .alphabetical ? .creation : .alphabetical
                    } label: {
                        Image(systemName: sortOrder == .alphabetical ? "clock" : "textformat.abc")
                    }
                    .help(sortOrder == .alphabetical ? "Trier par création" : "Trier par nom")
                    .opacity(isSelectingTiers ? 0 : 1)
                    .disabled(isSelectingTiers)
                }
                #else
                ToolbarItem(placement: .navigationBarTrailing) {
                    PaneToggleButton(label: "Ajouter", systemImage: "plus", isOn: Binding(
                        get: { showEditSheet },
                        set: { newValue in
                            if newValue { startAdd() } else { showEditSheet = false }
                        }
                    ))
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
                #endif
            }
            .adaptivePane(isPresented: $showEditSheet) {
                editSheet
            }
            .adaptiveEntityPane(
                item: $editingPayee,
                title: "Tiers",
                refresh: { t in repository.fetchTiers().first { $0.id == t.id } },
                onDelete: { t in
                    pendingDelete = DeleteTarget(tab: .tiers, entityId: t.id, name: t.name,
                                                 count: tierCounts[t.id] ?? 0, childIds: [], blocked: false)
                }
            ) { t in
                PayeeDetailPane(
                    tiers: t,
                    allCategories: categories,
                    payeeGroups: payeeGroups,
                    accounts: accounts,
                    transactionCount: tierCounts[t.id] ?? 0
                )
            } edit: { payee in
                PayeeDetailView(
                    payee: payee,
                    allCategories: categories,
                    allAccounts: accounts,
                    onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() }
                )
            }
            .adaptivePane(item: $detailTarget) { target in
                ReferenceDetailPane(
                    target: target,
                    categories: categories,
                    counts: countsFor(target),
                    onEdit: { startEditFor(target) },
                    onDelete: { pendingDelete = deleteTargetFor(target) },
                    onShowTransactions: { accountId, accountName in
                        appState.selectedAccountId = accountId
                        appState.selectedAccountName = accountName
                        appState.selectedTab = MainTabItem.transactions.rawValue
                    }
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
                tiersDisplayLimit = tiersPageSize
            }
            .onChange(of: sortOrder) { _, _ in
                recomputeFiltered(resetPaging: true)
            }
            .task(id: searchText) {
                // Debounce : sans ça, chaque caractère saisi refiltre et retrie
                // les ~1000 tiers (comparaison localisée = la plus coûteuse).
                if !(searchText.isEmpty && appliedSearch.isEmpty) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
                guard appliedSearch != searchText else { return }
                appliedSearch = searchText
                recomputeFiltered(resetPaging: true)
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
            Form {
                Section {
                    TextField("Nom", text: $editDraftName)
                        .autocorrectionDisabled()
                    if selectedTab == .tiers {
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
                        Button {
                            showIconPicker = true
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
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } header: { Text("Icône") }
                    footer: {
                        if editDraftIcon == nil {
                            Text("Si tu ne choisis rien, l'icône est calculée automatiquement depuis le nom. Toute icône choisie est mémorisée et a la priorité.")
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .adaptivePane(isPresented: $showIconPicker) {
                ScrollView {
                    CategoryIconPicker(
                        selectedIcon: $editDraftIcon,
                        categoryName: editDraftName,
                        isParent: editDraftParentCategoryId == nil
                    )
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .paneChrome("Choisir une icône",
                            cancelLabel: "Fermer", onCancel: { showIconPicker = false })
            }
            .paneChrome(editItemId == nil ? "Ajouter" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { showEditSheet = false },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: editDraftName.trimmingCharacters(in: .whitespaces).isEmpty,
                        onConfirm: { saveEdit() })
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
            #if os(macOS)
            // macOS : clic = panneau détail (la navigation vers les transactions
            // reste accessible via le bouton dédié du panneau).
            detailTarget = .account(a)
            #else
            appState.selectedAccountId = a.id
            appState.selectedAccountName = a.name
            appState.selectedTab = MainTabItem.transactions.rawValue
            #endif
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
        .rowActions(
            leading: [editAction { startEdit(id: a.id, name: a.name, regex: "", accountType: a.type) }],
            trailing: [deleteAction(DeleteTarget(tab: .comptes, entityId: a.id, name: a.name,
                                                 count: accountCounts[a.id] ?? 0, childIds: [],
                                                 blocked: (accountCounts[a.id] ?? 0) > 0))],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }

    /// Action "Modifier" adaptative (swipe iOS / clic droit macOS via RowActions).
    private func editAction(_ action: @escaping () -> Void) -> RowAction {
        RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent, action: action)
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
        case .metadata:
            // Création et suppression se font dans `MetadataKeyManagerView`,
            // atteignable depuis la fiche transaction ET depuis cet onglet :
            // une clé se crée au moment où on en a besoin, pas dans un
            // référentiel qu'on visite exprès.
            break
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

        recomputeFiltered(resetPaging: false)
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
        case .metadata:       TransactionMetadataRepository().deleteKey(id: target.entityId)
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
    private func deleteAction(_ target: DeleteTarget) -> RowAction {
        RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) {
            pendingDelete = target
        }
    }

    // MARK: - Panneau détail macOS (helpers)

    private func countsFor(_ target: ReferenceDetailTarget) -> Int {
        switch target {
        case .account(let a):     return accountCounts[a.id] ?? 0
        case .category(let c):
            let childIds = categories.filter { $0.parentId == c.id }.map(\.id)
            return categoryTransactionCount([c.id] + childIds)
        case .paymentType(let p): return paymentTypeCounts[p.id] ?? 0
        case .tag(let t):         return tagCounts[t.id] ?? 0
        }
    }

    /// « Modifier » du panneau détail : remplit les drafts et ouvre la fiche
    /// d'édition partagée — qui REMPLACE le panneau détail (slot unique).
    private func startEditFor(_ target: ReferenceDetailTarget) {
        switch target {
        case .account(let a):
            startEdit(id: a.id, name: a.name, regex: "", accountType: a.type)
        case .category(let c):
            startEdit(id: c.id, name: c.name, regex: "", parentCategoryId: c.parentId, icon: c.icon)
        case .paymentType(let p):
            startEdit(id: p.id, name: p.name, regex: p.regex ?? "")
        case .tag:
            break   // Les tags n'ont pas d'édition (pas de rename en base).
        }
    }

    private func deleteTargetFor(_ target: ReferenceDetailTarget) -> DeleteTarget {
        switch target {
        case .account(let a):
            return DeleteTarget(tab: .comptes, entityId: a.id, name: a.name,
                                count: accountCounts[a.id] ?? 0, childIds: [],
                                blocked: (accountCounts[a.id] ?? 0) > 0)
        case .category(let c):
            return deleteTargetForCategory(c)
        case .paymentType(let p):
            return DeleteTarget(tab: .metadata, entityId: p.id, name: p.name,
                                count: paymentTypeCounts[p.id] ?? 0, childIds: [], blocked: false)
        case .tag(let t):
            return DeleteTarget(tab: .tags, entityId: t.id, name: t.name,
                                count: tagCounts[t.id] ?? 0, childIds: [], blocked: false)
        }
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
        .contentShape(Rectangle())
        .macDetailTap { detailTarget = .category(c) }
        .rowActions(
            leading: [editAction { startEdit(id: c.id, name: c.name, regex: "", parentCategoryId: c.parentId, icon: c.icon) }],
            trailing: [deleteAction(deleteTargetForCategory(c))],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
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
