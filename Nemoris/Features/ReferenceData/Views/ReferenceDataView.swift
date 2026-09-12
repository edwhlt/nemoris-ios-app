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
        // ⚠️ "Payment methods" was REMOVED (migration v46). It's no longer a
        // first-class concept: it became one free-form metadata entry among
        // others, managed from the transaction detail screen. Keeping it here
        // too would give two places to edit the same information — the
        // coexistence was explicitly ruled out.
        //
        // The `payment_types` table stays in the database, deprecated and unread
        // (project doctrine: only remove a table once certain nothing still
        // references it), which keeps the switch reversible.
        case metadata       = "Métadonnées"
        case tags           = "Tags"
        var id: String { rawValue }

        /// Displayed label — distinct from `rawValue` (the `Picker`'s internal
        /// identity) so it can be translated without touching that identity.
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
    /// Skeleton until the first `loadReferenceData()` completes.
    @State private var hasLoaded = false

    // Tri
    enum SortOrder { case alphabetical, creation }
    @State private var sortOrder: SortOrder = .alphabetical

    /// Target of a swipe-triggered deletion (before confirmation).
    struct DeleteTarget: Identifiable {
        let id = UUID()
        let tab: ReferenceTab
        let entityId: Int
        let name: String
        let count: Int          // associated transactions
        let childIds: [Int]     // sub-categories carried along (parent categories)
        let blocked: Bool       // true = deletion impossible (account still in use)
    }

    // Recherche
    @State private var searchText = ""

    // Structured filter for the Payees tab (group / category / city / country)
    // — distinct from the text search above (name/regex, via `.searchable`).
    // See `TiersFilterSheet`. `tiersFilterGroupId` also doubles as the
    // mechanism for "see the payees of a group" (triggered from
    // `PayeeGroupManagerView.onSelectGroup`) — no need for a separate screen,
    // it's the same question asked with a criterion already filled in.
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

    // Edit / add
    @State private var showEditSheet = false
    /// Initial values passed to `ReferenceEditFormPane` when it opens. The
    /// `@State` that's LIVE during entry belongs to that dedicated view, not
    /// here — see its header comment for why (staleness of the macOS root pane).
    @State private var editInitialDraft = ReferenceEditDraft()
    @State private var editItemId: Int? = nil   // nil = a new item

    // full payee editing via PayeeDetailView.
    @State private var editingPayee: Tiers? = nil
    /// Creating a payee: goes straight through `PayeeDetailView` (the rich
    /// form) rather than `ReferenceEditFormPane` — the same flow as editing,
    /// no separate minimal form to fill out afterward.
    @State private var creatingPayee = false

    // Managing metadata keys (the "Metadata" tab): the same swipeable/inspector
    // flow as the other tabs (Accounts/Payees/Tags) — tap or swipe "Edit" →
    // `editingMetadataKey` (detail ⇄ edit via `adaptiveEntityPane`, see
    // `metadataRow`); the toolbar "+" → `creatingMetadataKey`
    // (`MetadataKeyFormView(key: nil, …)`). Replaces the old "Manage metadata"
    // button, which stayed around unused elsewhere too — see its header
    // comment in `TransactionMetadataSection.swift`.
    @State private var editingMetadataKey: TransactionMetadataKey? = nil
    @State private var creatingMetadataKey = false

    // Managing payee groups (the "Payees" tab): add/rename/delete/merge — see
    // `PayeeGroupManagerView`. Presented HERE, outside the `List`, for the
    // same structural reason as this screen's other panes (`showEditSheet`,
    // `creatingPayee`, `detailTarget`…): a `.sheet`/`.adaptivePane` attached to
    // a view that IS itself row content inside a `List` (all the more so a
    // `List` with `.searchable`, as here) can be dismissed by the system on the
    // very first attempt (a known SwiftUI bug).
    @State private var showGroupManager = false

    // Count of associated transactions, per entity (id → count).
    @State private var categoryCounts: [Int: Int] = [:]
    @State private var tierCounts: [Int: Int] = [:]
    @State private var paymentTypeCounts: [Int: Int] = [:]
    @State private var accountCounts: [Int: Int] = [:]
    @State private var tagCounts: [Int: Int] = [:]
    @State private var metadataKeyCounts: [Int: Int] = [:]

    // One-off deletion via swipe (every table).
    @State private var pendingDelete: DeleteTarget? = nil

    /// Target of the macOS detail pane (tap on an account / category /
    /// payment-method / tag row). Never set on iOS (taps there keep their
    /// historical behavior).
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

    // Category tree — recomputed on the fly to react to sorting.
    private var categoryForest: [CategoryNode] {
        CategoryNode.buildForest(from: categories,
                                 sort: sortOrder == .creation ? .creation : .alphabetical)
    }

    /// Parent categories currently COLLAPSED — empty by default (everything
    /// expanded, the historical behavior of the `DisclosureGroup` that
    /// preceded it).
    @State private var collapsedCategoryIds: Set<Int> = []

    /// Prefix flattening of `categoryForest`, descending into children only if
    /// the parent is NOT collapsed — same doctrine as
    /// `SQLConsoleView.visibleRows` (see `CategoryTreeRow`'s header comment).
    /// This FLAT list, and only this one, gives `first`/`last` a meaning
    /// consistent with the rest of the app.
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

    // Payee selection/deletion — the anchor enables shift+click (a range),
    // see `RangeSelection` (DesignSystem/MultiSelect.swift).
    @State private var isSelectingTiers = false
    @State private var selectedTiersIds: Set<Int> = []
    @State private var tiersSelectionAnchor: Int? = nil

    // Tag selection/deletion — same mechanics as Payees, separate state
    // (switching tabs must not mix up the two selections).
    @State private var isSelectingTags = false
    @State private var selectedTagIds: Set<Int> = []
    @State private var tagsSelectionAnchor: Int? = nil

    @State private var showDeleteConfirm = false

    /// Merging DUPLICATE payees — 2 paths to the same final resolver:
    /// - swipe "Merge…" on ONE row → `mergeTierSearchSourceId` (search for
    ///   a second payee, see `PayeeMergeTargetPicker`) → once chosen,
    ///   the 2 ids feed `mergeTierCandidateIds`.
    /// - the "Merge (N)" button in group selection (2+ already checked) →
    ///   `mergeTierCandidateIds` directly, NO search: asking the user to
    ///   pick a target from a list makes no sense when they've already
    ///   designated the payees in question.
    @State private var mergeTierSearchSourceId: Int? = nil
    @State private var mergeTierCandidateIds: [Int] = []

    // CSV import of payees: removed during a cleanup (the legacy SmartImport cluster was deleted).

    // MARK: Filtering + sorting
    //
    // ⚠️ These lists are CACHED in `@State`, they are NOT computed
    // properties. As computed properties, every `body` evaluation re-read them
    // twice (an `.isEmpty` check, then `ForEach`) → two full localized sorts
    // over ~1000 payees on every keystroke, every tab switch and every
    // selection toggle. Recomputed only via `recomputeFiltered()`.
    @State private var filteredAccounts: [Account] = []
    @State private var filteredCategories: [Category] = []
    @State private var filteredTiers: [Tiers] = []
    @State private var filteredPaymentTypes: [PaymentType] = []
    @State private var filteredTags: [Tag] = []
    @State private var filteredMetadataKeys: [TransactionMetadataKey] = []

    /// The search actually applied to the lists = `searchText` debounced
    /// (see `.task(id: searchText)`), so as not to refilter on every character.
    @State private var appliedSearch = ""

    /// Pagination of the Payees tab — the only large table (~1000 rows).
    /// Same principle as `TransactionsView`: only the first rows are
    /// materialized, the rest is appended when the end-of-list sentinel appears.
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

    /// Rebuilds the 5 displayed lists. `resetPaging` resets the Payees tab to
    /// its first page: true when the search or sort changes (the content has
    /// nothing to do with before), false on a plain data reload (we don't want
    /// to jump the user back to the top of the list after a deletion).
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
            // Keep the page reached, without exceeding the new total.
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
                // Same policy as Transactions/Patrimoine/Tricount: .plain =
                // a neutral base for the custom cards drawn by macGroupedRow.
                // iOS keeps its native insetGrouped.
                .listStyle(.plain)
                // Detaches the 1st card from the Divider() above it — same fix
                // as TransactionsView (macGroupedRow doesn't add an outer
                // margin at the top of the 1st row, only at the bottom of the
                // last one).
                .macGroupedListTopGap()
                #endif
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Rechercher…")
            }
            // The app's background is set explicitly — without it, the "content"
            // column of the macOS NavigationSplitView shows its vibrant material by
            // default (translucent, picks up the color of the desktop/window behind
            // it), not the neutral AppTheme background. Same fix as TricountListView/
            // TricountDetailView/SQLConsoleView.
            .background(AppTheme.Colors.background.ignoresSafeArea())
            // ⌘A: selects everything already loaded for the displayed
            // tab. A single hidden button, dispatched by `selectedTab` —
            // the TWO can never be in the tree at the same time
            // (a switch on the active tab), so no shortcut ambiguity.
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
            // ⚠️ Explicit resolution, never a bare literal: `.navigationTitle`
            // bridges to native chrome (the macOS title bar), which doesn't
            // reliably respect the app-forced `\.locale` (unlike a content
            // `Text`). See CLAUDE.md §5.
            .localizedNavigationTitle("Données")
            .toolbar {
                // Secondary actions + the "+" button grouped in ONE pill on macOS.
                // `ToolbarItemGroup` (NOT `ControlGroup`, which rendered isolated
                // buttons): it's the toolbar's native grouping.
                // Icon-only + native `.help` tooltip, consistent with the rest.
                #if os(macOS)
                // Reorganized into 2 groups separated by a `Spacer()` —
                // filter/groups/sort (or, in selection mode, the group
                // actions) on the left, the selection toggle + add
                // glued to the right edge. A `Spacer()` inside a `ToolbarItemGroup`
                // is already the pattern used by `TransactionsView`.
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !isCurrentlySelecting {
                        // Filter + groups: only make sense on the Payees tab.
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
                        // In selection mode, this same slot carries the group
                        // actions — filter/groups/sort no longer make sense here.
                        Button {
                            selectAllInCurrentTab()
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .localizedHelp("Tout sélectionner")
                        .localizedAccessibilityLabel("Tout sélectionner")
                        // Merging duplicates — only makes sense for payees
                        // (not tags), and from 2 selected onward.
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

                    // Selection toggle — this used to be a TEXT
                    // button ("Select"/"Cancel") on the left of the
                    // bar; now an icon, glued to the right edge next to "Add".
                    if selectedTab == .tiers || selectedTab == .tags {
                        Button {
                            toggleCurrentSelectionMode()
                        } label: {
                            Image(systemName: isCurrentlySelecting ? "xmark.circle" : "checkmark.circle")
                        }
                        .localizedHelp(isCurrentlySelecting ? "Annuler la sélection" : "Sélectionner")
                        .localizedAccessibilityLabel(isCurrentlySelecting ? "Annuler la sélection" : "Sélectionner")
                    }
                    // ⚠️ CONDITIONAL removal (`if !isCurrentlySelecting`), not
                    // `.opacity(0).disabled(...)`: the system draws a
                    // pill/background around the toolbar button GROUP — hiding just a
                    // button's CONTENT leaves its empty pill visible, a phantom
                    // "bubble" where "Add" should be during selection. An `if`
                    // removes the button from the group, not just its content.
                    if !isCurrentlySelecting {
                        // Custom binding: `startAdd()` resets several
                        // draft fields — it must stay triggered on
                        // OPEN, not on every toggle (closing has
                        // nothing to reset).
                        PaneToggleButton(label: "Ajouter", systemImage: "plus", isOn: Binding(
                            get: { showEditSheet },
                            set: { newValue in
                                if newValue { startAdd() } else { showEditSheet = false }
                            }
                        ))
                    }
                }
                #else
                // Filter + sort stay top-level icons (direct access);
                // groups/select/add — rarer actions — go into the "…"
                // menu, in a group separated from the rest by a `Divider()`
                // (a distinct question: organizing payees vs. acting on
                // the current list). In selection mode, the toggle
                // + group actions stay top-level (we don't want to
                // bury "Cancel selection").
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
                        // Merging duplicates — only makes sense for payees
                        // (not tags), and from 2 selected onward.
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
                            // ⚠️ Do NOT open the resolver in the same cycle
                            // as this picker's dismissal — presenting one
                            // `.adaptivePane` while dismissing another requires
                            // deferring the second (see CLAUDE.md §N.1).
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
                // Fresh read from the database, never from `metadataKeys` (the
                // local cache) — same doctrine as the Payees `refresh` just
                // above.
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
                // Debounce: without it, every character typed refilters and re-sorts
                // the ~1000 payees (a localized comparison — the costliest kind).
                if !(searchText.isEmpty && appliedSearch.isEmpty) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
                guard appliedSearch != searchText else { return }
                appliedSearch = searchText
                recomputeFiltered(resetPaging: true)
            }
            .task(id: appState.dataRefreshToken) {
                // A 1-frame guard so the skeleton shows before the SQLite read.
                await Task.yield()
                loadReferenceData()
                hasLoaded = true
            }
            .refreshable { loadReferenceData() }
    }

    // MARK: - Tab content (extracted from `navBody` for type-checking, see the comment above)

    @ViewBuilder private var accountsTabContent: some View {
        if filteredAccounts.isEmpty { emptyRow
        } else if sortOrder == .alphabetical && searchText.isEmpty {
            // Grouped by type, sorted alphabetically.
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
            // Flat: search results or sorted by creation date
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
            // Search mode: a flat list with a visual indicator
            ForEach(filteredCategories) { c in
                flatCategoryRow(c)
                    .macGroupedRow(first: c.id == filteredCategories.first?.id, last: c.id == filteredCategories.last?.id)
            }
        } else {
            // Normal mode: a hierarchical tree, flattened into a flat list of
            // VISIBLE nodes (see `visibleCategoryRows` and `CategoryTreeRow`'s
            // header comment) — global first/last on this list,
            // not per group of siblings, for ONE continuous card.
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
            // Pagination sentinel: its appearing on screen
            // triggers loading the next page.
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

    /// Metadata tab — same flow as Accounts/Payees/Tags: tap or
    /// swipe "Edit" open the detail (`editingMetadataKey`, see
    /// `adaptiveEntityPane`), swipe "Delete" the generic confirmation
    /// (`pendingDelete`). Replaces the old "Manage metadata" button.
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

    // `EmptyStateView` (icon/title/message) is the single mechanism for
    // empty screens — see CLAUDE.md §5. This used to be a plain `Text` with no
    // icon, the only empty screen in the app in that state. Always
    // ONE row in the `List` (not a full screen), so the row's default
    // background/separator are removed to let the empty state center
    // properly, like the other modules.
    @ViewBuilder private var emptyRow: some View {
        Group {
            if !searchText.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    verbatimMessage: "Aucun résultat pour « \(searchText) »"
                )
            } else if selectedTab == .tiers && tiersActiveFiltersCount > 0 {
                // Distinct from the "empty database" case below: payees do
                // exist, only the structured filters (group/category/city/country)
                // return nothing.
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "Aucun résultat",
                    message: "Aucun tier ne correspond à ces filtres."
                )
            } else if selectedTab == .metadata {
                // A fresh database has NO metadata at all by design (§ AXE Y) —
                // not "import first", unlike the generic case.
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
            // macOS: a click opens the detail pane (navigation to the transactions
            // stays reachable via the pane's dedicated button).
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
        // Without this, macOS applies the default button chrome (tinted with
        // the app's accent) — a green highlight on top of an already-green
        // card (`macGroupedRow`). iOS doesn't have this default style at the
        // same spot, hence the gap that went unnoticed for a while.
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

    /// "View transactions" for a payee (`PayeeDetailPane`): switches to
    /// the Transactions tab, filtered by its name, across all accounts (a
    /// payee isn't tied to a particular account) — the same mechanism
    /// as `accountRow` for an account, via `AppState.pendingPayeeFilterName`
    /// (consumed by `TransactionsView.loadInitialData()`).
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
            // The rich form directly (the same fields as when editing), not the
            // minimal form of `ReferenceEditFormPane`.
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
            // Dead in practice: `startAdd()` now routes `.tiers` to
            // `PayeeDetailView` (the rich form) BEFORE ever opening this
            // pane, and no payee is edited via `startEdit` (editing
            // goes through `editingPayee`/`PayeeDetailView`). This case is kept —
            // required by the exhaustiveness of the switch on `ReferenceTab`, used
            // for plenty of other things in this view.
            break
        case .metadata:
            // Dead in practice, like `.tiers` above: `startAdd()` routes
            // `.metadata` to `MetadataKeyFormView` BEFORE ever opening this
            // pane, and editing goes through `editingMetadataKey`.
            break
        case .tags:
            break  // Tags aren't editable here
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

        // Counts of associated transactions (one GROUP BY pass per table).
        categoryCounts    = repository.countTransactionsByCategory()
        tierCounts        = repository.countTransactionsByPayee()
        paymentTypeCounts = repository.countTransactionsByPaymentType()
        accountCounts     = repository.countTransactionsByAccount()
        tagCounts         = repository.countTransactionsByTag()
        // No grouped count on the metadata side (few keys in practice,
        // unlike the ~1000 payees): one query per key is enough.
        metadataKeyCounts = Dictionary(uniqueKeysWithValues: metadataKeys.map {
            ($0.id, metadataRepository.transactionIds(keyId: $0.id, value: nil).count)
        })

        recomputeFiltered(resetPaging: false)
    }

    // MARK: Deletion

    /// Number of transactions in a category, sub-categories included.
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
            // ⚠️ Unlike the other tabs, deleting a metadata key
            // ERASES the value (CASCADE) — not "kept", so as not to
            // wrongly suggest transactions keep the value.
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

    /// Delete button (leading swipe = "swipe right").
    private func deleteAction(_ target: DeleteTarget) -> RowAction {
        RowAction("Supprimer", systemImage: "trash", role: .destructive, tint: AppTheme.Colors.danger) {
            pendingDelete = target
        }
    }

    // MARK: - Multi-select (Payees / Tags)
    //
    // Only two tabs (the others — Accounts grouped, Categories as a
    // tree — don't have the flat structure shift+click/⌘A assumes). State
    // stays separate per tab (`isSelectingTiers`/`isSelectingTags`…); these
    // helpers just dispatch on `selectedTab` to avoid duplicating
    // the same 4 branches across the toolbar, the bottom bar and the dialog.

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

    /// Merges `sourceIds` into `target` (see `PayeeMergeTargetPicker`) and
    /// clears any leftover state that might still point at a payee that just
    /// disappeared — the group selection in particular.
    // MARK: - macOS detail pane (helpers)

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

    /// "Edit" from the detail pane: fills the drafts and opens the shared
    /// edit form — which REPLACES the detail pane (a single slot).
    private func startEditFor(_ target: ReferenceDetailTarget) {
        switch target {
        case .account(let a):
            startEdit(id: a.id, name: a.name, accountType: a.type, excludedFromAggregates: a.excludedFromAggregates)
        case .category(let c):
            startEdit(id: c.id, name: c.name, parentCategoryId: c.parentId, icon: c.icon)
        case .paymentType(let p):
            startEdit(id: p.id, name: p.name)
        case .tag:
            break   // Tags have no editing (no rename in the database).
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


    /// Icon to show in the edit sheet's preview: reflects the ACTUAL icon
    /// used for display (custom if set, otherwise the automatic fallback on the name).
    /// A payee's subtitle in the list: city · country · group (empty fields are skipped).
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

    /// Flat row for search mode
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
                // The filter flattens the tree — a child can show up without
                // its parent. The parent's name as a subtitle replaces the old
                // "↳": depth alone didn't say WHOSE sub-category it was.
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

    /// Builds a category's deletion target, carrying along its sub-categories.
    private func deleteTargetForCategory(_ c: Category) -> DeleteTarget {
        let childIds = categories.filter { $0.parentId == c.id }.map(\.id)
        let allIds = [c.id] + childIds
        return DeleteTarget(tab: .categories, entityId: c.id, name: c.name,
                            count: categoryTransactionCount(allIds), childIds: childIds, blocked: false)
    }

    /// Same, from a tree node (carries along the whole sub-tree).
    private func deleteTargetForNode(_ node: CategoryNode) -> DeleteTarget {
        let allIds = node.allIds()
        let childIds = Array(allIds.dropFirst())
        return DeleteTarget(tab: .categories, entityId: node.category.id, name: node.category.name,
                            count: categoryTransactionCount(allIds), childIds: childIds, blocked: false)
    }

}
