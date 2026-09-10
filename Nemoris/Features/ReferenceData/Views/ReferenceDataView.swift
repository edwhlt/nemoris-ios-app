import SwiftUI
import TipKit
struct ReferenceDataView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    private let repository = TransactionRepository()
    private let metadataRepository = TransactionMetadataRepository()

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
        // (doctrine du projet : on ne supprime qu'une fois certain que plus rien
        // ne la référence), ce qui rend la bascule réversible.
        case metadata       = "Métadonnées"
        case tags           = "Tags"
        var id: String { rawValue }

        /// Libellé affiché — distinct de `rawValue` (identité interne du
        /// `Picker`) pour pouvoir traduire sans toucher à cette identité.
        var label: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }

    @State private var selectedTab: ReferenceTab = .comptes
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    @State private var tiers: [Tiers] = []
    @State private var paymentTypes: [PaymentType] = []
    @State private var tags: [Tag] = []
    @State private var payeeGroups: [PayeeGroup] = []
    @State private var metadataKeys: [TransactionMetadataKey] = []
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

    // Filtre structuré de l'onglet Tiers (groupe / catégorie / ville / pays)
    // — distinct de la recherche texte ci-dessus (nom/regex, via `.searchable`).
    // Cf. `TiersFilterSheet`. `tiersFilterGroupId` double aussi de mécanisme
    // pour "voir les tiers d'un groupe" (déclenché depuis
    // `PayeeGroupManagerView.onSelectGroup`) — pas besoin d'un écran séparé,
    // c'est la même question posée avec un critère déjà rempli.
    @State private var showTiersFilters = false
    @State private var tiersFilterGroupId: Int? = nil
    @State private var tiersFilterCategoryId: Int? = nil
    @State private var tiersFilterCity: String = ""
    @State private var tiersFilterCountry: String = ""

    private var tiersActiveFiltersCount: Int {
        (tiersFilterGroupId == nil ? 0 : 1)
        + (tiersFilterCategoryId == nil ? 0 : 1)
        + (tiersFilterCity.isEmpty ? 0 : 1)
        + (tiersFilterCountry.isEmpty ? 0 : 1)
    }

    // Édition / ajout
    @State private var showEditSheet = false
    /// Valeurs initiales transmises à `ReferenceEditFormPane` à l'ouverture. Le
    /// `@State` VIVANT pendant la saisie appartient à ce view dédié, pas ici —
    /// cf. son commentaire de tête pour la raison (staleness du panneau racine
    /// macOS).
    @State private var editInitialDraft = ReferenceEditDraft()
    @State private var editItemId: Int? = nil   // nil = nouvel élément

    // édition complète d'un payee via PayeeDetailView.
    @State private var editingPayee: Tiers? = nil
    /// Création d'un tiers : passe directement par `PayeeDetailView` (fiche
    /// riche) plutôt que par `ReferenceEditFormPane` — même parcours qu'à
    /// l'édition, pas de form minimal séparé à compléter après coup.
    @State private var creatingPayee = false

    // Gestion des clés de métadonnées (onglet "Métadonnées") : même parcours
    // swipeable/inspecteur que les autres onglets (Comptes/Tiers/Tags) — tap
    // ou swipe "Modifier" → `editingMetadataKey` (détail ⇄ édition via
    // `adaptiveEntityPane`, cf. `metadataRow`) ; "+" de la toolbar →
    // `creatingMetadataKey` (`MetadataKeyFormView(key: nil, …)`). Remplace
    // l'ancien bouton "Gérer les métadonnées" (retour d'usage : "il sert à
    // rien") + `MetadataKeyManagerView`, qui reste néanmoins en service
    // ailleurs — cf. son commentaire de tête dans `TransactionMetadataSection.swift`.
    @State private var editingMetadataKey: TransactionMetadataKey? = nil
    @State private var creatingMetadataKey = false

    // Gestion des groupes de tiers (onglet "Tiers") : ajouter/renommer/
    // supprimer/fusionner — cf. `PayeeGroupManagerView`. Présenté ICI, hors de
    // la `List`, pour la même raison structurelle que les autres panes de cet
    // écran (`showEditSheet`, `creatingPayee`, `detailTarget`…) : un
    // `.sheet`/`.adaptivePane` attaché à une vue qui EST elle-même du contenu
    // de row à l'intérieur d'une `List` (a fortiori une `List` avec
    // `.searchable`, comme ici) peut être annulé par le système au tout
    // premier essai (bug SwiftUI connu, retour d'usage).
    @State private var showGroupManager = false

    // Nombre de transactions associées, par entité (id → count).
    @State private var categoryCounts: [Int: Int] = [:]
    @State private var tierCounts: [Int: Int] = [:]
    @State private var paymentTypeCounts: [Int: Int] = [:]
    @State private var accountCounts: [Int: Int] = [:]
    @State private var tagCounts: [Int: Int] = [:]
    @State private var metadataKeyCounts: [Int: Int] = [:]

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

    /// Catégories PARENTES actuellement REPLIÉES — vide par défaut (tout
    /// déplié, comportement historique du `DisclosureGroup` avant lui).
    @State private var collapsedCategoryIds: Set<Int> = []

    /// Aplatissement préfixe de `categoryForest`, en ne descendant dans les
    /// enfants que si le parent n'est PAS replié — même doctrine que
    /// `SQLConsoleView.visibleRows` (cf. commentaire de tête de
    /// `CategoryTreeRow`). C'est cette liste PLATE, et elle seule, qui donne
    /// à `first`/`last` un sens global cohérent avec le reste de l'app.
    private var visibleCategoryRows: [(node: CategoryNode, depth: Int)] {
        var rows: [(node: CategoryNode, depth: Int)] = []
        func walk(_ nodes: [CategoryNode], depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if !node.isLeaf, !collapsedCategoryIds.contains(node.id) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(categoryForest, depth: 0)
        return rows
    }

    // Sélection / suppression tiers — l'ancre permet le maj+clic (plage),
    // cf. `RangeSelection` (DesignSystem/MultiSelect.swift).
    @State private var isSelectingTiers = false
    @State private var selectedTiersIds: Set<Int> = []
    @State private var tiersSelectionAnchor: Int? = nil

    // Sélection / suppression tags — même mécanique que Tiers, état séparé
    // (changer d'onglet ne doit pas mélanger les deux sélections).
    @State private var isSelectingTags = false
    @State private var selectedTagIds: Set<Int> = []
    @State private var tagsSelectionAnchor: Int? = nil

    @State private var showDeleteConfirm = false

    /// Fusion de tiers DOUBLONS — 2 chemins vers le même résolveur final :
    /// - swipe "Fusionner…" d'UNE row → `mergeTierSearchSourceId` (recherche
    ///   d'un second tier, cf. `PayeeMergeTargetPicker`) → une fois choisi,
    ///   les 2 ids alimentent `mergeTierCandidateIds`.
    /// - bouton "Fusionner (N)" en sélection groupée (2+ déjà cochés) →
    ///   `mergeTierCandidateIds` directement, PAS de recherche : demander de
    ///   choisir une cible parmi une liste n'a pas de sens quand l'utilisateur
    ///   a déjà désigné les tiers en question (retour d'usage).
    @State private var mergeTierSearchSourceId: Int? = nil
    @State private var mergeTierCandidateIds: [Int] = []

    // Import CSV des tiers : retiré lors d'un nettoyage (cluster SmartImport legacy supprimé).

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
    @State private var filteredMetadataKeys: [TransactionMetadataKey] = []

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

        var tiersBase = q.isEmpty ? tiers
            : tiers.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || ($0.regex?.localizedCaseInsensitiveContains(q) == true)
            }
        if let gid = tiersFilterGroupId {
            tiersBase = tiersBase.filter { $0.groupId == gid }
        }
        if let cid = tiersFilterCategoryId {
            tiersBase = tiersBase.filter { $0.categoryId == cid }
        }
        if !tiersFilterCity.isEmpty {
            tiersBase = tiersBase.filter { ($0.city ?? "").localizedCaseInsensitiveContains(tiersFilterCity) }
        }
        if !tiersFilterCountry.isEmpty {
            tiersBase = tiersBase.filter { ($0.country ?? "").localizedCaseInsensitiveContains(tiersFilterCountry) }
        }
        filteredTiers = sorted(tiersBase, name: \.name)

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

        filteredMetadataKeys = sorted(
            q.isEmpty ? metadataKeys
                      : metadataKeys.filter { $0.name.localizedCaseInsensitiveContains(q) },
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
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)

                List {
                    if !hasLoaded {
                        ForEach(0..<8, id: \.self) { _ in
                            SkeletonReferenceListRow()
                                .listRowBackground(AppTheme.Colors.surface)
                        }
                    } else {
                    switch selectedTab {
                    case .comptes:    accountsTabContent
                    case .categories: categoriesTabContent
                    case .tiers:      tiersTabContent
                    case .metadata:   metadataTabContent
                    case .tags:       tagsTabContent
                    }
                    }  // end else (hasLoaded)
                }
                #if os(macOS)
                // Même politique que Transactions/Patrimoine/Tricount : .plain =
                // base neutre pour les cartes custom dessinées par macGroupedRow.
                // iOS garde son insetGrouped natif.
                .listStyle(.plain)
                // Décolle la 1ère carte du Divider() du dessus — même correctif
                // que TransactionsView (macGroupedRow ne pose pas de marge
                // extérieure en haut de la 1ère row, seulement en bas de la
                // dernière). Cf. retour d'usage.
                .macGroupedListTopGap()
                #endif
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Rechercher…")
            }
            // Fond de l'app posé explicitement — sans lui la colonne « content »
            // de la NavigationSplitView macOS montre son matériau vibrant par
            // défaut (translucide, capte la couleur du bureau/fenêtre derrière),
            // pas le fond neutre AppTheme. Même correctif que TricountListView/
            // TricountDetailView/SQLConsoleView ().
            .background(AppTheme.Colors.background.ignoresSafeArea())
            // ⌘A : sélectionne tout ce qui est déjà chargé pour l'onglet
            // affiché. Un seul bouton caché, dispatché par `selectedTab` —
            // les DEUX ne peuvent jamais être dans l'arbre en même temps
            // (switch sur l'onglet actif), donc pas d'ambiguïté de raccourci.
            .background(
                Group {
                    switch selectedTab {
                    case .tiers:
                        SelectAllShortcut(isSelecting: $isSelectingTiers, selected: $selectedTiersIds, allIds: filteredTiers.map(\.id))
                    case .tags:
                        SelectAllShortcut(isSelecting: $isSelectingTags, selected: $selectedTagIds, allIds: filteredTags.map(\.id))
                    default:
                        EmptyView()
                    }
                }
            )
            // ⚠️ Résolution explicite, jamais un littéral nu : `.navigationTitle`
            // ponte vers la chrome native (barre de titre macOS), qui ne respecte
            // pas fiablement `\.locale` forcé par l'app (contrairement à un `Text`
            // de contenu). Cf. CLAUDE.md §5.
            .localizedNavigationTitle("Données")
            .toolbar {
                // Actions secondaires + bouton + groupés dans UNE pilule sur macOS.
                // `ToolbarItemGroup` (et NON `ControlGroup`, qui rendait des boutons
                // isolés) : c'est le groupement natif de la barre d'outils.
                // Icônes seules + tooltip natif `.help`, cohérent avec le reste.
                #if os(macOS)
                // Retour d'usage : réorganisé en 2 groupes séparés par un
                // `Spacer()` — filtre/groupes/tri (ou, en sélection, les
                // actions de groupe) à gauche, bascule de sélection + ajouter
                // collés au bord droit. `Spacer()` dans un `ToolbarItemGroup`
                // est déjà le pattern utilisé par `TransactionsView`.
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !isCurrentlySelecting {
                        // Filtre + groupes : n'ont de sens que sur l'onglet Tiers.
                        if selectedTab == .tiers {
                            PaneToggleButton(
                                label: "Filtrer",
                                systemImage: tiersActiveFiltersCount > 0
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle",
                                isOn: $showTiersFilters
                            )
                            PaneToggleButton(label: "Gérer les groupes", systemImage: "rectangle.3.group", isOn: $showGroupManager)
                        }
                        Button {
                            sortOrder = sortOrder == .alphabetical ? .creation : .alphabetical
                        } label: {
                            Image(systemName: sortOrder == .alphabetical ? "clock" : "textformat.abc")
                        }
                        .localizedHelp(sortOrder == .alphabetical ? "Trier par création" : "Trier par nom")
                    } else if currentSelectionCount > 0 {
                        // En sélection, ce même emplacement porte les actions
                        // de groupe — filtre/groupes/tri n'ont plus de sens ici.
                        Button {
                            selectAllInCurrentTab()
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .localizedHelp("Tout sélectionner")
                        .localizedAccessibilityLabel("Tout sélectionner")
                        // Fusion de doublons — n'a de sens que pour les tiers
                        // (pas les tags), et à partir de 2 sélectionnés.
                        if selectedTab == .tiers && currentSelectionCount >= 2 {
                            Button {
                                mergeTierCandidateIds = Array(selectedTiersIds)
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .localizedHelp("Fusionner (\(currentSelectionCount))")
                            .localizedAccessibilityLabel("Fusionner \(currentSelectionCount) tiers")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer (\(currentSelectionCount))", systemImage: "trash")
                                .foregroundStyle(AppTheme.Colors.danger)
                        }
                    }

                    Spacer()

                    // Bascule de sélection — retour d'usage : c'était un
                    // bouton TEXTE ("Sélectionner"/"Annuler") à gauche de la
                    // barre ; icône, collée au bord droit avec "Ajouter".
                    if selectedTab == .tiers || selectedTab == .tags {
                        Button {
                            toggleCurrentSelectionMode()
                        } label: {
                            Image(systemName: isCurrentlySelecting ? "xmark.circle" : "checkmark.circle")
                        }
                        .localizedHelp(isCurrentlySelecting ? "Annuler la sélection" : "Sélectionner")
                        .localizedAccessibilityLabel(isCurrentlySelecting ? "Annuler la sélection" : "Sélectionner")
                    }
                    // ⚠️ Retrait CONDITIONNEL (`if !isCurrentlySelecting`), pas
                    // `.opacity(0).disabled(...)` (retour d'usage : le système
                    // dessine une pilule/fond autour du GROUPE de boutons de la
                    // toolbar — masquer juste le CONTENU d'un bouton laisse sa
                    // pilule vide visible, une "bulle" fantôme à la place
                    // d'"Ajouter" pendant la sélection). Un `if` retire le
                    // bouton du groupe, pas seulement son contenu.
                    if !isCurrentlySelecting {
                        // Binding custom : `startAdd()` réinitialise plusieurs
                        // champs brouillon — doit rester déclenché à
                        // l'OUVERTURE, pas à chaque bascule (la fermeture n'a
                        // rien à réinitialiser).
                        PaneToggleButton(label: "Ajouter", systemImage: "plus", isOn: Binding(
                            get: { showEditSheet },
                            set: { newValue in
                                if newValue { startAdd() } else { showEditSheet = false }
                            }
                        ))
                    }
                }
                #else
                // Retour d'usage : filtre + tri restent des icônes de premier
                // niveau (accès direct) ; groupes/sélectionner/ajouter — des
                // actions plus rares — vont dans le menu "…", groupes séparé
                // du reste par un `Divider()` (question distincte : organiser
                // les tiers vs. agir sur la liste courante). En sélection,
                // la bascule + les actions de groupe restent au 1er niveau
                // (on ne veut pas enterrer "Annuler la sélection").
                if isCurrentlySelecting {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            toggleCurrentSelectionMode()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .localizedHelp("Annuler la sélection")
                        .localizedAccessibilityLabel("Annuler la sélection")
                    }
                    if currentSelectionCount > 0 {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                selectAllInCurrentTab()
                            } label: {
                                Image(systemName: "checklist")
                            }
                            .localizedHelp("Tout sélectionner")
                            .localizedAccessibilityLabel("Tout sélectionner")
                        }
                        // Fusion de doublons — n'a de sens que pour les tiers
                        // (pas les tags), et à partir de 2 sélectionnés.
                        if selectedTab == .tiers && currentSelectionCount >= 2 {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    mergeTierCandidateIds = Array(selectedTiersIds)
                                } label: {
                                    Image(systemName: "arrow.triangle.merge")
                                }
                                .localizedHelp("Fusionner (\(currentSelectionCount))")
                                .localizedAccessibilityLabel("Fusionner \(currentSelectionCount) tiers")
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Supprimer (\(currentSelectionCount))", systemImage: "trash")
                                    .foregroundStyle(AppTheme.Colors.danger)
                            }
                        }
                    }
                } else {
                    if selectedTab == .tiers {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            PaneToggleButton(
                                label: "Filtrer",
                                systemImage: tiersActiveFiltersCount > 0
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle",
                                isOn: $showTiersFilters
                            )
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            sortOrder = sortOrder == .alphabetical ? .creation : .alphabetical
                        } label: {
                            Image(systemName: sortOrder == .alphabetical ? "clock" : "textformat.abc")
                        }
                        .localizedHelp(sortOrder == .alphabetical ? "Trier par création" : "Trier par nom")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if selectedTab == .tiers {
                                Button {
                                    showGroupManager = true
                                } label: {
                                    Label("Gérer les groupes", systemImage: "rectangle.3.group")
                                }
                                Divider()
                            }
                            if selectedTab == .tiers || selectedTab == .tags {
                                Button {
                                    toggleCurrentSelectionMode()
                                } label: {
                                    Label("Sélectionner", systemImage: "checkmark.circle")
                                }
                            }
                            Button {
                                startAdd()
                            } label: {
                                Label("Ajouter", systemImage: "plus")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                #endif
            }
            .adaptivePane(isPresented: $showEditSheet) {
                editSheet
            }
            .adaptivePane(isPresented: $creatingPayee) {
                PayeeDetailView(
                    payee: nil,
                    allCategories: categories,
                    allAccounts: accounts,
                    onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() }
                )
            }
            .adaptivePane(isPresented: $creatingMetadataKey) {
                MetadataKeyFormView(key: nil, onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() })
            }
            .adaptivePane(isPresented: $showGroupManager) {
                PayeeGroupManagerView(
                    onChange: { loadReferenceData(); appState.dataRefreshToken = UUID() },
                    onSelectGroup: { group in
                        showGroupManager = false
                        tiersFilterGroupId = group.id
                        recomputeFiltered(resetPaging: true)
                    }
                )
            }
            .adaptivePane(isPresented: $showTiersFilters) {
                TiersFilterSheet(
                    allCategories: categories,
                    payeeGroups: payeeGroups,
                    groupId: $tiersFilterGroupId,
                    categoryId: $tiersFilterCategoryId,
                    city: $tiersFilterCity,
                    country: $tiersFilterCountry,
                    onApply: { recomputeFiltered(resetPaging: true) }
                )
            }
            .adaptivePane(isPresented: Binding(
                get: { mergeTierSearchSourceId != nil },
                set: { if !$0 { mergeTierSearchSourceId = nil } }
            )) {
                if let sourceId = mergeTierSearchSourceId, let source = tiers.first(where: { $0.id == sourceId }) {
                    PayeeMergeTargetPicker(
                        sourceName: source.name,
                        candidates: tiers.filter { $0.id != sourceId },
                        onSelect: { target in
                            mergeTierSearchSourceId = nil
                            // ⚠️ Ne PAS ouvrir le résolveur dans le même cycle
                            // que la fermeture de ce picker — présenter un
                            // `.adaptivePane` en fermer un autre exige de
                            // différer le second (cf. CLAUDE.md §N.1).
                            Task { @MainActor in
                                mergeTierCandidateIds = [sourceId, target.id]
                            }
                        }
                    )
                }
            }
            .adaptivePane(isPresented: Binding(
                get: { !mergeTierCandidateIds.isEmpty },
                set: { if !$0 { mergeTierCandidateIds = [] } }
            )) {
                PayeeMergeResolverView(
                    candidates: tiers.filter { mergeTierCandidateIds.contains($0.id) },
                    allCategories: categories,
                    payeeGroups: payeeGroups,
                    transactionCounts: tierCounts,
                    onMerged: {
                        isSelectingTiers = false
                        selectedTiersIds = []
                        tiersSelectionAnchor = nil
                        loadReferenceData()
                        appState.dataRefreshToken = UUID()
                    }
                )
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
                    transactionCount: tierCounts[t.id] ?? 0,
                    onShowTransactions: { showTransactionsFor(t) }
                )
            } edit: { payee in
                PayeeDetailView(
                    payee: payee,
                    allCategories: categories,
                    allAccounts: accounts,
                    onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() }
                )
            }
            .adaptiveEntityPane(
                item: $editingMetadataKey,
                title: "Métadonnée",
                // Lecture fraîche en base, jamais depuis `metadataKeys` (cache
                // local) — même doctrine que le `refresh` des Tiers juste
                // au-dessus.
                refresh: { k in metadataRepository.fetchKeys().first { $0.id == k.id } },
                onDelete: { k in
                    pendingDelete = DeleteTarget(tab: .metadata, entityId: k.id, name: k.name,
                                                 count: metadataKeyCounts[k.id] ?? 0, childIds: [], blocked: false)
                }
            ) { k in
                MetadataKeyDetailPane(key: k, usageCount: metadataKeyCounts[k.id] ?? 0)
            } edit: { k in
                MetadataKeyFormView(key: k, onSave: { loadReferenceData(); appState.dataRefreshToken = UUID() })
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
                bulkDeleteTitle,
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) { performBulkDelete() }
                Button("Annuler", role: .cancel) {}
            } message: {
                bulkDeleteMessage
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
                deleteMessage(target)
            }
            .onChange(of: selectedTab) { _, _ in
                isSelectingTiers = false
                selectedTiersIds = []
                tiersSelectionAnchor = nil
                isSelectingTags = false
                selectedTagIds = []
                tagsSelectionAnchor = nil
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

    // MARK: - Contenus d'onglet (extraits de `navBody` pour le type-check, cf. commentaire ci-dessus)

    @ViewBuilder private var accountsTabContent: some View {
        if filteredAccounts.isEmpty { emptyRow
        } else if sortOrder == .alphabetical && searchText.isEmpty {
            // Groupé par type, trié alphabétiquement.
            let groups = accounts.groupedByType
            ForEach(groups, id: \.type) { group in
                Section {
                    ForEach(group.accounts) { a in
                        accountRow(a)
                            .macGroupedRow(first: a.id == group.accounts.first?.id, last: a.id == group.accounts.last?.id)
                    }
                } header: {
                    Text(LocalizedStringKey(group.type.label))
                        .macGroupedSectionHeader()
                }
                .listSectionSeparator(.hidden)
                .listRowSeparator(.hidden)
            }
        } else {
            // Plat : résultats de recherche ou tri par création
            ForEach(filteredAccounts) { a in
                accountRow(a)
                    .macGroupedRow(first: a.id == filteredAccounts.first?.id, last: a.id == filteredAccounts.last?.id)
            }
        }
    }

    @ViewBuilder private var categoriesTabContent: some View {
        if categories.isEmpty {
            emptyRow
        } else if !searchText.isEmpty {
            // Mode recherche : liste plate avec indicateur visuel
            ForEach(filteredCategories) { c in
                flatCategoryRow(c)
                    .macGroupedRow(first: c.id == filteredCategories.first?.id, last: c.id == filteredCategories.last?.id)
            }
        } else {
            // Mode normal : arbre hiérarchique, aplati en une liste plate des
            // nœuds VISIBLES (cf. `visibleCategoryRows` et le commentaire de
            // tête de `CategoryTreeRow`) — first/last globaux à cette liste,
            // pas par groupe de frères, pour UNE seule carte continue.
            let rows = visibleCategoryRows
            ForEach(Array(rows.enumerated()), id: \.element.node.id) { index, entry in
                CategoryTreeRow(
                    node: entry.node,
                    depth: entry.depth,
                    isExpanded: entry.node.isLeaf ? nil : !collapsedCategoryIds.contains(entry.node.id),
                    onToggleExpand: {
                        withAnimation(.snappy) {
                            if collapsedCategoryIds.contains(entry.node.id) {
                                collapsedCategoryIds.remove(entry.node.id)
                            } else {
                                collapsedCategoryIds.insert(entry.node.id)
                            }
                        }
                    },
                    countFor: { categoryCounts[$0.id] ?? 0 },
                    onEdit: { c in
                        startEdit(id: c.id, name: c.name, parentCategoryId: c.parentId, icon: c.icon)
                    },
                    onDelete: { n in pendingDelete = deleteTargetForNode(n) },
                    onSelect: { c in detailTarget = .category(c) },
                    isFirst: index == 0,
                    isLast: index == rows.count - 1
                )
            }
        }
    }

    @ViewBuilder private var tiersTabContent: some View {
        if filteredTiers.isEmpty { emptyRow } else {
            let allIds = visibleTiers.map(\.id)
            ForEach(Array(visibleTiers.enumerated()), id: \.element.id) { index, t in
                TierRow(tiers: t,
                        allCategories: categories,
                        subtitle: tierSubtitle(t),
                        count: tierCounts[t.id] ?? 0,
                        isSelecting: isSelectingTiers,
                        isSelected: selectedTiersIds.contains(t.id))
                    .selectableRow(
                        id: t.id, index: index, allIds: allIds,
                        isSelecting: $isSelectingTiers, selected: $selectedTiersIds, anchor: $tiersSelectionAnchor
                    ) {
                        editingPayee = t
                    }
                    .rowActions(
                        selection: selectionRowActions(
                            isSelecting: isSelectingTiers,
                            isSelected: selectedTiersIds.contains(t.id),
                            selectionCount: selectedTiersIds.count,
                            toggle: { RangeSelection.toggle(t.id, index: index, selected: &selectedTiersIds, anchor: &tiersSelectionAnchor) },
                            selectAll: selectAllInCurrentTab,
                            clearSelection: { selectedTiersIds = [] },
                            deleteSelection: { showDeleteConfirm = true }
                        ),
                        leading: isSelectingTiers ? [] : [editAction { editingPayee = t }],
                        trailing: isSelectingTiers ? [] : (
                            tiers.count > 1
                                ? [
                                    RowAction("Fusionner…", systemImage: "arrow.triangle.merge", tint: AppTheme.Colors.textSecondary) { mergeTierSearchSourceId = t.id },
                                    deleteAction(DeleteTarget(tab: .tiers, entityId: t.id, name: t.name,
                                                               count: tierCounts[t.id] ?? 0, childIds: [], blocked: false))
                                  ]
                                : [deleteAction(DeleteTarget(tab: .tiers, entityId: t.id, name: t.name,
                                                              count: tierCounts[t.id] ?? 0, childIds: [], blocked: false))]
                        ),
                        leadingFullSwipe: false,
                        trailingFullSwipe: false
                    )
                    .macGroupedRow(first: t.id == visibleTiers.first?.id, last: t.id == visibleTiers.last?.id)
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
    }

    @ViewBuilder private var tagsTabContent: some View {
        if filteredTags.isEmpty { emptyRow } else {
            let allIds = filteredTags.map(\.id)
            ForEach(Array(filteredTags.enumerated()), id: \.element.id) { index, tag in
                HStack(spacing: 10) {
                    if isSelectingTags {
                        Image(systemName: selectedTagIds.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedTagIds.contains(tag.id) ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
                            .imageScale(.large)
                    }
                    Circle()
                        .fill(tag.displayColor)
                        .frame(width: 10, height: 10)
                    Text(tag.name)
                    Spacer()
                    EntityIdCountBadge(id: tag.id, count: tagCounts[tag.id] ?? 0)
                }
                .selectableRow(
                    id: tag.id, index: index, allIds: allIds,
                    isSelecting: $isSelectingTags, selected: $selectedTagIds, anchor: $tagsSelectionAnchor
                ) {
                    detailTarget = .tag(tag)
                }
                .rowActions(
                    selection: selectionRowActions(
                        isSelecting: isSelectingTags,
                        isSelected: selectedTagIds.contains(tag.id),
                        selectionCount: selectedTagIds.count,
                        toggle: { RangeSelection.toggle(tag.id, index: index, selected: &selectedTagIds, anchor: &tagsSelectionAnchor) },
                        selectAll: selectAllInCurrentTab,
                        clearSelection: { selectedTagIds = [] },
                        deleteSelection: { showDeleteConfirm = true }
                    ),
                    trailing: isSelectingTags ? [] : [deleteAction(DeleteTarget(tab: .tags, entityId: tag.id, name: tag.name,
                                                         count: tagCounts[tag.id] ?? 0, childIds: [], blocked: false))],
                    trailingFullSwipe: false
                )
                .macGroupedRow(first: tag.id == filteredTags.first?.id, last: tag.id == filteredTags.last?.id)
            }
        }
    }

    /// Onglet Métadonnées — même parcours que Comptes/Tiers/Tags : tap ou
    /// swipe "Modifier" ouvrent le détail (`editingMetadataKey`, cf.
    /// `adaptiveEntityPane`), swipe "Supprimer" la confirmation générique
    /// (`pendingDelete`). Remplace l'ancien bouton "Gérer les métadonnées"
    /// (retour d'usage : "il sert à rien").
    @ViewBuilder private var metadataTabContent: some View {
        if filteredMetadataKeys.isEmpty { emptyRow } else {
            ForEach(filteredMetadataKeys) { key in
                metadataRow(key)
                    .macGroupedRow(first: key.id == filteredMetadataKeys.first?.id, last: key.id == filteredMetadataKeys.last?.id)
            }
        }
    }

    @ViewBuilder
    private func metadataRow(_ key: TransactionMetadataKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: key.displayIcon)
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name).foregroundStyle(AppTheme.Colors.textPrimary)
                if let role = key.role {
                    Text(LocalizedStringKey(role.displayName))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
            EntityIdCountBadge(id: key.id, count: metadataKeyCounts[key.id] ?? 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingMetadataKey = key }
        .rowActions(
            leading: [editAction { editingMetadataKey = key }],
            trailing: [deleteAction(DeleteTarget(tab: .metadata, entityId: key.id, name: key.name,
                                                 count: metadataKeyCounts[key.id] ?? 0, childIds: [], blocked: false))],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }

    // MARK: Edit sheet

    private var editSheet: some View {
        ReferenceEditFormPane(
            kind: selectedTab,
            editItemId: editItemId,
            initial: editInitialDraft,
            categories: categories,
            onCancel: { showEditSheet = false },
            onSave: { draft in saveEdit(draft) }
        )
    }

    // MARK: Helpers

    // `EmptyStateView` (icône/titre/message) est le mécanisme unique pour les
    // écrans vides — cf. CLAUDE.md §5. C'était jusqu'ici un simple `Text` sans
    // icône, seul écran vide de l'app dans ce cas (retour d'usage). Toujours
    // UNE row dans la `List` (pas un plein écran), donc le fond/séparateur par
    // défaut de la row sont retirés pour laisser l'état vide se centrer
    // proprement, comme les autres modules.
    @ViewBuilder private var emptyRow: some View {
        Group {
            if !searchText.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    verbatimMessage: "Aucun résultat pour « \(searchText) »"
                )
            } else if selectedTab == .tiers && tiersActiveFiltersCount > 0 {
                // Distinct du cas "base vide" ci-dessous : des tiers existent,
                // seuls les filtres structurés (groupe/catégorie/ville/pays)
                // ne renvoient rien.
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "Aucun résultat",
                    message: "Aucun tier ne correspond à ces filtres."
                )
            } else if selectedTab == .metadata {
                // Une base neuve n'a AUCUNE métadonnée par design (§ AXE Y) —
                // pas "importe d'abord", contrairement au cas générique.
                EmptyStateView(
                    icon: "tag",
                    title: "Aucune métadonnée",
                    message: "Définis tes propres étiquettes — « Projet », « Pro / Perso »… — depuis le bouton + en haut."
                )
            } else {
                EmptyStateView(
                    icon: "tray",
                    title: "Aucune donnée",
                    message: "Importe d'abord un fichier sqlite ou commence à les ajouter."
                )
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
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
                if a.excludedFromAggregates {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .localizedAccessibilityLabel("Exclu des calculs agrégés")
                }
                Spacer()
                if a.accountType != .courant {
                    Text(LocalizedStringKey(a.accountType.label))
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
        // Sans ça, macOS applique le chrome de bouton par défaut (teinté par
        // l'accent de l'app) — un surlignement vert par-dessus une carte déjà
        // verte (`macGroupedRow`). iOS n'a pas ce style par défaut au même
        // endroit, d'où l'écart jamais remarqué avant (retour d'usage
        // 2026-08-21).
        .buttonStyle(.plain)
        .rowActions(
            leading: [editAction { startEdit(id: a.id, name: a.name, accountType: a.type, excludedFromAggregates: a.excludedFromAggregates) }],
            trailing: [deleteAction(DeleteTarget(tab: .comptes, entityId: a.id, name: a.name,
                                                 count: accountCounts[a.id] ?? 0, childIds: [],
                                                 blocked: (accountCounts[a.id] ?? 0) > 0))],
            leadingFullSwipe: false,
            trailingFullSwipe: false
        )
    }

    /// "Voir les transactions" d'un tiers (`PayeeDetailPane`) : bascule sur
    /// l'onglet Transactions, filtré par son nom, tous comptes confondus (un
    /// tiers n'est pas rattaché à un compte particulier) — même mécanique
    /// que `accountRow` pour un compte, via `AppState.pendingPayeeFilterName`
    /// (consommé par `TransactionsView.loadInitialData()`).
    private func showTransactionsFor(_ payee: Tiers) {
        appState.pendingPayeeFilterName = payee.name
        appState.dataRefreshToken = UUID()
        appState.selectedTab = MainTabItem.transactions.rawValue
    }

    /// Action "Modifier" adaptative (swipe iOS / clic droit macOS via RowActions).
    private func editAction(_ action: @escaping () -> Void) -> RowAction {
        RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent, action: action)
    }

    private func startEdit(id: Int, name: String, parentCategoryId: Int? = nil, icon: String? = nil, accountType: String = "COURANT", excludedFromAggregates: Bool = false) {
        editItemId = id
        editInitialDraft = ReferenceEditDraft(
            name: name,
            parentCategoryId: parentCategoryId,
            icon: icon,
            accountType: accountType,
            excludedFromAggregates: excludedFromAggregates
        )
        showEditSheet = true
    }

    private func startAdd() {
        switch selectedTab {
        case .tiers:
            // Fiche riche directement (mêmes champs qu'à l'édition), pas le
            // form minimal de `ReferenceEditFormPane`.
            creatingPayee = true
        case .metadata:
            creatingMetadataKey = true
        case .comptes, .categories, .tags:
            editItemId = nil
            editInitialDraft = ReferenceEditDraft()
            showEditSheet = true
        }
    }

    private func saveEdit(_ draft: ReferenceEditDraft) {
        let name  = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch selectedTab {
        case .comptes:
            if let id = editItemId { repository.updateAccount(id: id, name: name, type: draft.accountType, excludedFromAggregates: draft.excludedFromAggregates) }
            else { repository.addAccount(name: name, type: draft.accountType, excludedFromAggregates: draft.excludedFromAggregates) }
        case .categories:
            if let id = editItemId { repository.updateCategory(id: id, name: name, parentId: draft.parentCategoryId, icon: draft.icon) }
            else { repository.addCategory(name: name, parentId: draft.parentCategoryId, icon: draft.icon) }
        case .tiers:
            // Mort en pratique : `startAdd()` route désormais `.tiers` vers
            // `PayeeDetailView` (fiche riche) AVANT de jamais ouvrir ce
            // panneau, et aucun tiers n'est édité via `startEdit` (l'édition
            // passe par `editingPayee`/`PayeeDetailView`). Garder ce cas —
            // requis par l'exhaustivité du switch sur `ReferenceTab`, utilisé
            // pour bien d'autres choses dans cette vue.
            break
        case .metadata:
            // Mort en pratique, comme `.tiers` ci-dessus : `startAdd()` route
            // `.metadata` vers `MetadataKeyFormView` AVANT de jamais ouvrir ce
            // panneau, et l'édition passe par `editingMetadataKey`.
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
        metadataKeys    = metadataRepository.fetchKeys()

        // Compteurs de transactions associées (une passe GROUP BY par table).
        categoryCounts    = repository.countTransactionsByCategory()
        tierCounts        = repository.countTransactionsByPayee()
        paymentTypeCounts = repository.countTransactionsByPaymentType()
        accountCounts     = repository.countTransactionsByAccount()
        tagCounts         = repository.countTransactionsByTag()
        // Pas de comptage groupé côté métadonnées (peu de clés en pratique,
        // contrairement aux ~1000 tiers) : une requête par clé suffit.
        metadataKeyCounts = Dictionary(uniqueKeysWithValues: metadataKeys.map {
            ($0.id, metadataRepository.transactionIds(keyId: $0.id, value: nil).count)
        })

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
        case .metadata:       metadataRepository.deleteKey(id: target.entityId)
        case .tags:           repository.deleteTag(id: target.entityId)
        }
        loadReferenceData()
        appState.dataRefreshToken = UUID()
    }

    private func deleteMessage(_ target: DeleteTarget) -> Text {
        if target.blocked {
            return Text("« \(target.name) » porte \(target.count) transaction\(target.count > 1 ? "s" : ""). Réassigne-les à un autre compte avant de le supprimer.")
        }
        if target.count == 0 && target.childIds.isEmpty {
            return Text("« \(target.name) » n'est associé à aucune transaction.")
        }
        var parts: [Text] = []
        if !target.childIds.isEmpty {
            parts.append(Text("\(target.childIds.count) sous-catégorie\(target.childIds.count > 1 ? "s" : "") supprimée\(target.childIds.count > 1 ? "s" : "")"))
        }
        if target.count > 0 {
            let nounKey: String
            switch target.tab {
            case .tags:     nounKey = "détaguée"
            // ⚠️ Contrairement aux autres tabs, supprimer une métadonnée
            // EFFACE la valeur (CASCADE) — pas "conservée", pour ne pas
            // laisser croire à tort que les transactions gardent la valeur.
            case .metadata: nounKey = target.count > 1 ? "qui perdront cette métadonnée" : "qui perdra cette métadonnée"
            default:        nounKey = "conservée"
            }
            parts.append(Text("\(target.count) transaction\(target.count > 1 ? "s" : "") ") + Text(nounKey))
        }
        return parts.isEmpty ? Text("Supprimer « \(target.name) » ?") : joinedText(parts, separator: " · ") + Text(".")
    }
    
    private func joinedText(_ parts: [Text], separator: String) -> Text {
        parts.dropFirst().reduce(parts.first ?? Text("")) { result, part in
                result + Text(separator) + part
        }
    }

    /// Bouton de suppression (swipe leading = « glisser à droite »).
    private func deleteAction(_ target: DeleteTarget) -> RowAction {
        RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) {
            pendingDelete = target
        }
    }

    // MARK: - Sélection multiple (Tiers / Tags)
    //
    // Deux onglets seulement (les autres — Comptes groupés, Catégories en
    // arbre — n'ont pas la structure plate qu'un maj+clic/⌘A suppose). L'état
    // reste séparé par onglet (`isSelectingTiers`/`isSelectingTags`…) ; ces
    // helpers dispatchent juste sur `selectedTab` pour éviter de dupliquer
    // les mêmes 4 branches dans la toolbar, la barre du bas et le dialogue.

    private var isCurrentlySelecting: Bool {
        switch selectedTab {
        case .tiers: return isSelectingTiers
        case .tags:  return isSelectingTags
        default:     return false
        }
    }

    private var currentSelectionCount: Int {
        switch selectedTab {
        case .tiers: return selectedTiersIds.count
        case .tags:  return selectedTagIds.count
        default:     return 0
        }
    }

    private func toggleCurrentSelectionMode() {
        switch selectedTab {
        case .tiers:
            isSelectingTiers.toggle()
            selectedTiersIds = []
            tiersSelectionAnchor = nil
        case .tags:
            isSelectingTags.toggle()
            selectedTagIds = []
            tagsSelectionAnchor = nil
        default:
            break
        }
    }

    private func selectAllInCurrentTab() {
        switch selectedTab {
        case .tiers:
            isSelectingTiers = true
            selectedTiersIds = Set(filteredTiers.map(\.id))
        case .tags:
            isSelectingTags = true
            selectedTagIds = Set(filteredTags.map(\.id))
        default:
            break
        }
    }

    private var bulkDeleteTitle: String {
        switch selectedTab {
        case .tags: return "Supprimer \(selectedTagIds.count) tag(s) ?"
        default:    return "Supprimer \(selectedTiersIds.count) tiers ?"
        }
    }

    @ViewBuilder private var bulkDeleteMessage: some View {
        switch selectedTab {
        case .tags: Text("Les transactions et dépenses Tricount associées perdront ce tag.")
        default:    Text("Les transactions associées seront conservées mais sans tiers assigné.")
        }
    }

    private func performBulkDelete() {
        switch selectedTab {
        case .tiers:
            repository.deleteTiers(ids: selectedTiersIds)
            isSelectingTiers = false
            selectedTiersIds = []
            tiersSelectionAnchor = nil
        case .tags:
            repository.deleteTags(ids: selectedTagIds)
            isSelectingTags = false
            selectedTagIds = []
            tagsSelectionAnchor = nil
        default:
            break
        }
        loadReferenceData()
        appState.dataRefreshToken = UUID()
    }

    /// Fusionne `sourceIds` dans `target` (cf. `PayeeMergeTargetPicker`) et
    /// nettoie tout état qui pourrait encore pointer vers un tiers qui vient
    /// de disparaître — la sélection groupée notamment.
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
            startEdit(id: a.id, name: a.name, accountType: a.type, excludedFromAggregates: a.excludedFromAggregates)
        case .category(let c):
            startEdit(id: c.id, name: c.name, parentCategoryId: c.parentId, icon: c.icon)
        case .paymentType(let p):
            startEdit(id: p.id, name: p.name)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name)
                    .fontWeight(c.parentId == nil ? .semibold : .regular)
                // Le filtre aplatit l'arbre — un enfant peut apparaître sans
                // son parent. Le nom du parent en sous-titre remplace l'ancien
                // "↳" : la profondeur seule ne disait pas DE QUI c'est la
                // sous-catégorie (retour d'usage).
                if let parentId = c.parentId,
                   let parentName = categories.first(where: { $0.id == parentId })?.name {
                    Text(parentName)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
            EntityIdCountBadge(id: c.id, count: categoryCounts[c.id] ?? 0)
        }
        .contentShape(Rectangle())
        .macDetailTap { detailTarget = .category(c) }
        .rowActions(
            leading: [editAction { startEdit(id: c.id, name: c.name, parentCategoryId: c.parentId, icon: c.icon) }],
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
