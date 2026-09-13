import SwiftUI
import TipKit

struct TricountDetailView: View {
    let group: TricountGroup
    var initialEntryId: Int? = nil
    /// macOS: returns to the Tricount list. The detail occupies the
    /// module's column (internal state-driven navigation — see `TricountListView.body`), so
    /// it provides its own back button. nil when the view is pushed (iOS) or
    /// presented as a sheet from TransactionsView.
    var onBack: (() -> Void)? = nil
    // paneDismiss: closes the presentation when the view is a sheet (level 2,
    // from TransactionsView). A no-op full-page, where `onBack` serves instead.
    @Environment(\.paneDismiss) private var paneDismiss
    // iOS: distinguishes "pushed from TricountListView" (.root, already
    // handled by the parent's ambient NavigationStack) from "presented as a
    // sheet from TransactionsView" (.modal, see `.adaptivePane(item:)` in
    // AdaptivePaneItemModifier). This drives the `if` in `body`
    // below — see its comment for the bug this fixes.
    @Environment(\.paneHostContext) private var hostContext
    @Environment(AppState.self) private var appState
    @State private var entries: [TricountEntry] = []
    @State private var shares: [TricountShare] = []
    @State private var reimbursementGroups: [ReimbursementGroup] = []
    @State private var selectedTab = 0
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true
    @State private var selectedEntry: TricountEntry? = nil
    @State private var quickLinkEntry: TricountEntry? = nil
    @State private var quickReimburseEntry: TricountEntry? = nil
    @State private var tagQuickEntry: TricountEntry? = nil
    @State private var allTags: [Tag] = []
    @State private var entryTagsMap: [Int: [Tag]] = [:]
    @State private var isSelectingEntries = false
    @State private var selectedEntryIds: Set<Int> = []
    @State private var showBulkEntryTagPicker = false
    @State private var showBulkEntryReimburse = false
    @State private var bulkEntryTagInitialStates: [Int: TagSelectionState] = [:]
    @State private var allTiers: [Tiers] = []
    @State private var hasLoaded = false

    // Sort & filters for the expense list — state deliberately NOT
    // persisted (like TransactionsView's text search): a sort/filter
    // left active from one session to the next would be more surprising than useful.
    @State private var showEntryFilters = false
    @State private var entrySort: TricountEntrySort = .dateDesc
    @State private var entryTitleSearch = ""
    @State private var entryLinkFilter: TricountLinkFilter = .all
    // "" = every payer.
    @State private var entryPayerFilter = ""
    @State private var entryMinShareText = ""
    @State private var entryMaxShareText = ""
    @State private var entryDateFilterEnabled = false
    @State private var entryFromDate = Date()
    @State private var entryToDate = Date()

    private let repo = TricountRepository()
    private let txRepo = TransactionRepository()
    private let reimbursementRepo = ReimbursementRepository()
    private let linkTip = TricountLinkTip()
    private let reimbTip = TricountReimbursementTip()
    private let balanceTip = TricountBalanceTip()

    private var myNetShare: Double {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        return entries.reduce(0.0) { sum, e in
            guard let myShare = byEntry[e.id]?.first(where: { $0.memberName == group.myName })?.amount else {
                return sum
            }

            let type = e.typeTransaction.uppercased()
            if type == "TRANSFER" || type == "BALANCE" {
                return sum
            }
            if type == "INCOME" {
                return sum - myShare
            }
            return sum + myShare
        }
    }

    private var mySpentTotal: Double {
        entries
            .filter { $0.whoPaid == group.myName && $0.typeTransaction.uppercased() == "NORMAL" && $0.total > 0 }
            .reduce(0.0) { $0 + $1.total }
    }

    /// The net effect of settlements already made (TRANSFER/BALANCE entries — Tricount's
    /// "Reimbursement" between members). Excluded from `mySpentTotal`/
    /// `myNetShare` (they aren't shared expenses) but they DO
    /// still need to adjust the final balance: without this, a settlement already received or
    /// paid stays counted as "still owed", which made the displayed
    /// balance diverge from Tricount's own as soon as a member settled up.
    private var mySettlementsNet: Double {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        return entries.reduce(0.0) { sum, e in
            let type = e.typeTransaction.uppercased()
            guard type == "TRANSFER" || type == "BALANCE" else { return sum }
            let entryShares = byEntry[e.id] ?? []
            if e.whoPaid == group.myName {
                // I settled a debt: credited with the amount the other party received.
                let othersTotal = entryShares.filter { $0.memberName != group.myName }.reduce(0.0) { $0 + $1.amount }
                return sum + othersTotal
            } else if let myShare = entryShares.first(where: { $0.memberName == group.myName })?.amount, myShare > 0 {
                // Someone settled a debt with me: debited, that amount is no longer owed.
                return sum - myShare
            }
            return sum
        }
    }

    // positive = I'm owed / negative = I owe
    private var myBalance: Double { mySpentTotal - myNetShare + mySettlementsNet }

    // MARK: - Expense sort & filters

    /// "Me" for the current member's name, the raw name otherwise — the same
    /// convention as `TricountEntryRow.isPaidByMe`.
    private func payerDisplayName(_ name: String) -> String {
        name == group.myName ? "Moi" : name
    }

    /// Raw names of payers present in the group, deduplicated and sorted
    /// on their displayed label (so "Me" sorts to its real alphabetical position).
    private var entryPayerOptions: [String] {
        Array(Set(entries.map(\.whoPaid))).sorted {
            payerDisplayName($0).localizedCaseInsensitiveCompare(payerDisplayName($1)) == .orderedAscending
        }
    }

    private var entryMinShareValue: Double? {
        Double(entryMinShareText.replacingOccurrences(of: ",", with: "."))
    }

    private var entryMaxShareValue: Double? {
        Double(entryMaxShareText.replacingOccurrences(of: ",", with: "."))
    }

    /// The group's expenses' real date bounds — frames the filter's
    /// `DatePicker` and serves as the default when it's activated (the full
    /// period rather than "today" on both ends, which would hide everything).
    private var entryDateBounds: (min: Date, max: Date) {
        let dates = entries.map(\.date)
        return (dates.min() ?? Date(), dates.max() ?? Date())
    }

    private var activeEntryFiltersCount: Int {
        (entryTitleSearch.isEmpty ? 0 : 1)
        + (entryLinkFilter == .all ? 0 : 1)
        + (entryPayerFilter.isEmpty ? 0 : 1)
        + (entryMinShareText.isEmpty && entryMaxShareText.isEmpty ? 0 : 1)
        + (entryDateFilterEnabled ? 1 : 0)
    }

    private func sortableTitle(_ entry: TricountEntry) -> String {
        entry.description.isEmpty ? entry.category : entry.description
    }

    /// Filtered + sorted expenses for display. `entries` (raw, SQL order)
    /// stays the source for the header's totals — filtering must never change
    /// the displayed balance, only the visible list.
    private var filteredSortedEntries: [TricountEntry] {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        let minShare = entryMinShareValue
        let maxShare = entryMaxShareValue
        let cal = Calendar.current
        // Inclusive bounds by calendar DAY — `entry.date` can carry an
        // hour (a bank import) while the `DatePicker` only picks a
        // day; without normalizing "To" to the end of the day, an expense dated
        // late afternoon on the selected day would be wrongly excluded.
        let dayStart = cal.startOfDay(for: entryFromDate)
        let dayEnd = cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: entryToDate)) ?? entryToDate
        let filtered = entries.filter { entry in
            let titleMatch = entryTitleSearch.isEmpty
                || entry.description.localizedCaseInsensitiveContains(entryTitleSearch)
            let dateMatch = !entryDateFilterEnabled
                || (entry.date >= dayStart && entry.date <= dayEnd)
            let linkMatch: Bool
            switch entryLinkFilter {
            case .all:       linkMatch = true
            case .linked:    linkMatch = entry.linkedTransactionId != nil
            case .notLinked: linkMatch = entry.linkedTransactionId == nil
            }
            let payerMatch = entryPayerFilter.isEmpty || entry.whoPaid == entryPayerFilter
            let shareMatch: Bool
            if minShare == nil && maxShare == nil {
                shareMatch = true
            } else if let myShare = byEntry[entry.id]?.first(where: { $0.memberName == group.myName })?.amount {
                let absShare = abs(myShare)
                shareMatch = (minShare.map { absShare >= $0 } ?? true) && (maxShare.map { absShare <= $0 } ?? true)
            } else {
                // No known share for this expense (e.g. TRANSFER/BALANCE):
                // can't satisfy a requested bound.
                shareMatch = false
            }
            return titleMatch && dateMatch && linkMatch && payerMatch && shareMatch
        }
        switch entrySort {
        case .dateDesc:
            return filtered.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
        case .dateAsc:
            return filtered.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
        case .titleAsc:
            return filtered.sorted { sortableTitle($0).localizedCaseInsensitiveCompare(sortableTitle($1)) == .orderedAscending }
        case .titleDesc:
            return filtered.sorted { sortableTitle($0).localizedCaseInsensitiveCompare(sortableTitle($1)) == .orderedDescending }
        }
    }

    var body: some View {
        #if os(macOS)
        // Full-page module content (a drill-down from TricountListView): a
        // NATIVE toolbar, with the back button to the list (the main window, never
        // affected by the bug below). Presented as a sheet (level 2, from
        // TransactionsView): a macOS `.sheet`'s native toolbar has its
        // own translucent material that lets the user's desktop show
        // through, whatever its content — hand-drawn chrome is used instead
        // (see `macSheetChrome` in AdaptivePane.swift). The menu's content (selection
        // mode, group actions) is mirrored rather than routed via `.paneChrome`:
        // too dynamic for its 3-button cancel/destructive/confirm model.
        if onBack != nil {
            detailContent
                .navigationTitle(group.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { nativeToolbarContent }
        } else {
            VStack(spacing: 0) {
                sheetTopBar
                Divider()
                detailContent
            }
            .background(AppTheme.Colors.background)
        }
        #else
        // ⚠️ iOS — NEVER wrap `detailContent` in its own `NavigationStack`
        // when this view is PUSHED (opening a tricount for the
        // first time used to eject to "More", only when Tricount lives
        // in the "More" menu). Cause: `TricountListView` pushes this view via a
        // classic `NavigationLink(destination:)` on ITS OWN ambient stack
        // (the Tricount tab's, or `MoreView`'s if it's hidden) —
        // exactly the same mechanism, once again, as the bug already
        // documented and fixed in `TricountListView.body` (mixing
        // navigation styles on the same stack). Adding a SECOND
        // `NavigationStack` HERE, nested inside the content just pushed,
        // reproduces the same anti-pattern one level down: UIKit can then
        // swallow the session's very first push and drop the ambient
        // stack back to its root. `\.paneHostContext` distinguishes this
        // view's two real uses: `.root` = pushed from `TricountListView`
        // (the ambient stack already provides title/back/toolbar, nothing to wrap);
        // `.modal` = presented as a sheet from `TransactionsView` via
        // `.adaptivePane(item:)`, which does NOT inject a `NavigationStack` for its
        // content — this one is still needed for the title/toolbar to show up.
        if hostContext == .root {
            detailContent
                .navigationTitle(group.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { nativeToolbarContent }
        } else {
            NavigationStack {
                detailContent
                    .navigationTitle(group.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { nativeToolbarContent }
            }
        }
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if !hasLoaded {
                // A skeleton for the entry list while local data loads.
                List {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonTricountEntryRow()
                            .listRowBackground(AppTheme.Colors.surface)
                    }
                }
                .listStyle(.plain)
                .macGroupedListTopGap()
                .scrollContentBackground(.hidden)
            } else {
                summaryHeader
                Divider()
                TipView(balanceTip, arrowEdge: .none)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                if reimbursementsEnabled {
                    Picker("", selection: $selectedTab) {
                        Text("Dépenses").tag(0)
                        Text("Remboursements").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.vertical, 8)
                    Divider()
                    if selectedTab == 0 { entriesTab } else { reimbursementsTab }
                } else {
                    entriesTab
                }
            }
        }
        // The app's background set explicitly — without it, the macOS
        // NavigationSplitView's "content" column shows its vibrant material by
        // default instead of the neutral AppTheme background. This is the exact
        // screen involved in the earlier report (a Tricount detail, e.g. "Vietnam").
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .adaptivePane(isPresented: $showEntryFilters) {
            TricountEntryFiltersSheet(
                payerOptions: entryPayerOptions,
                payerDisplayName: payerDisplayName,
                currency: group.currency,
                minDate: entryDateBounds.min,
                maxDate: entryDateBounds.max,
                titleSearchText: $entryTitleSearch,
                linkFilter: $entryLinkFilter,
                payerFilter: $entryPayerFilter,
                minShareText: $entryMinShareText,
                maxShareText: $entryMaxShareText,
                dateFilterEnabled: $entryDateFilterEnabled,
                fromDate: $entryFromDate,
                toDate: $entryToDate,
                onApply: {}
            )
        }
        .adaptivePane(isPresented: $showBulkEntryTagPicker) {
            BulkTagSheet(
                allTags: allTags,
                initialStates: bulkEntryTagInitialStates,
                repository: txRepo,
                onSave: { finalStates in
                    for entryId in selectedEntryIds {
                        var existing = Set(txRepo.fetchTags(forTricountEntry: entryId).map(\.id))
                        for (tagId, state) in finalStates {
                            switch state {
                            case .all:  existing.insert(tagId)
                            case .none: existing.remove(tagId)
                            case .some: break
                            }
                        }
                        txRepo.setTags(Array(existing), forTricountEntry: entryId)
                    }
                    loadEntryTags()
                    isSelectingEntries = false
                    selectedEntryIds.removeAll()
                },
                onNewTag: { newTag in
                    if !allTags.contains(where: { $0.id == newTag.id }) {
                        allTags.append(newTag)
                        allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                }
            )
        }
        .adaptivePane(isPresented: $showBulkEntryReimburse) {
            RemboursementQuickPickSheet(allTiers: allTiers) { tiersId, _ in
                guard tiersId != nil, let tiersId else { return }
                let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
                for entryId in selectedEntryIds {
                    let amount = byEntry[entryId]?.first(where: { $0.memberName == group.myName })?.amount ?? 0
                    if amount > 0 {
                        reimbursementRepo.addOrUpdateReimbursement(tricountEntryId: entryId, payeeId: tiersId, amount: amount, currency: group.currency)
                    }
                }
                reimbursementGroups = reimbursementRepo.fetchReimbursements(forTricountGroup: group.id)
                isSelectingEntries = false
                selectedEntryIds.removeAll()
            }
        }
        .task {
            await Task.yield()
            entries = repo.fetchEntries(groupId: group.id)
            shares = repo.fetchShares(groupId: group.id)
            reimbursementGroups = reimbursementRepo.fetchReimbursements(forTricountGroup: group.id)
            allTags = txRepo.fetchAllTags()
            allTiers = txRepo.fetchTiers()
            loadEntryTags()
            hasLoaded = true
            if let entryId = initialEntryId,
               let entry = entries.first(where: { $0.id == entryId }) {
                selectedTab = 1
                selectedEntry = entry
            }
        }
        .adaptivePane(item: $selectedEntry) { entry in
            let myShare = Dictionary(grouping: shares, by: { $0.entryId })[entry.id]?
                .first(where: { $0.memberName == group.myName })?.amount
            TricountEntryDetailSheet(
                entry: entry,
                myShare: myShare,
                myName: group.myName,
                groupCurrency: group.currency,
                repo: repo,
                txRepo: txRepo,
                reimbursementRepo: reimbursementRepo,
                allTags: allTags
            ) {
                entries = repo.fetchEntries(groupId: group.id)
                reimbursementGroups = reimbursementRepo.fetchReimbursements(forTricountGroup: group.id)
                selectedEntry = nil
            }
        }
        // A quick swipe: link a transaction
        .adaptivePane(item: $quickLinkEntry) { entry in
            TransactionPickerSheet(txRepo: txRepo, currentId: entry.linkedTransactionId) { tx in
                repo.updateLinkedTransaction(entryId: entry.id, transactionId: tx.id)
                entries = repo.fetchEntries(groupId: group.id)
            }
        }
        // A quick swipe: manage an entry's tags
        .adaptivePane(item: $tagQuickEntry) { entry in
            TagManagementSheet(
                initialTagIds: Set(txRepo.fetchTags(forTricountEntry: entry.id).map(\.id)),
                allTags: allTags,
                repository: txRepo,
                onSave: { tagIds in
                    txRepo.setTags(Array(tagIds), forTricountEntry: entry.id)
                    loadEntryTags()
                },
                onNewTag: { newTag in
                    if !allTags.contains(where: { $0.id == newTag.id }) {
                        allTags.append(newTag)
                        allTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                }
            )
        }
        // Swipe rapide : ajouter un remboursement
        .adaptivePane(item: $quickReimburseEntry) { entry in
            let rawShare = shares.first(where: { $0.entryId == entry.id && $0.memberName == group.myName })?.amount ?? 0
            AddTricountReimbursementSheet(
                defaultAmount: abs(rawShare),
                currency: group.currency
            ) { tiersId, amount, currency in
                reimbursementRepo.addOrUpdateReimbursement(tricountEntryId: entry.id, payeeId: tiersId, amount: amount, currency: currency)
                reimbursementGroups = reimbursementRepo.fetchReimbursements(forTricountGroup: group.id)
            }
        }
    }

    // MARK: - Toolbar (back/close + selection or group actions)

    #if os(macOS)
    /// A mirror of `nativeToolbarContent`, in plain views rather than
    /// `ToolbarContent`, for the ONE `.sheet` level-2 case (`onBack == nil`).
    /// The same mode logic (selection / normal), the same actions — but
    /// hand-drawn, see `body`'s comment above.
    @ViewBuilder
    private var sheetTopBar: some View {
        HStack {
            Button { paneDismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .localizedHelp("Fermer")

            Spacer()
            Text(group.title)
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()

            if isSelectingEntries {
                if !selectedEntryIds.isEmpty {
                    if reimbursementsEnabled {
                        PaneToggleButton(label: "Remboursement", systemImage: "arrow.uturn.left.circle", isOn: $showBulkEntryReimburse)
                    }
                    PaneToggleButton(label: "Tags", systemImage: "tag", isOn: Binding(
                        get: { showBulkEntryTagPicker },
                        set: { newValue in
                            if newValue { bulkEntryTagInitialStates = computeBulkEntryTagStates() }
                            showBulkEntryTagPicker = newValue
                        }
                    ))
                }
                Button {
                    isSelectingEntries = false
                    selectedEntryIds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .localizedHelp("Annuler la sélection")
                .localizedAccessibilityLabel("Annuler la sélection")
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            } else {
                if selectedTab == 0 {
                    Menu {
                        ForEach(TricountEntrySort.allCases) { s in
                            Button {
                                entrySort = s
                            } label: {
                                if entrySort == s {
                                    Label(s.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(s.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .localizedHelp("Trier")

                    PaneToggleButton(
                        label: "Filtrer",
                        systemImage: activeEntryFiltersCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        isOn: $showEntryFilters
                    )
                }
                Button {
                    isSelectingEntries = true
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .localizedHelp("Sélectionner")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.background)
    }
    #endif

    @ToolbarContentBuilder
    private var nativeToolbarContent: some ToolbarContent {
        #if os(macOS)
        // Full page (a drill-down): a back button to the list, at the native
        // system placement. As a sheet (level 2): "Close". Never both.
        ToolbarItem(placement: .navigation) {
            if isSelectingEntries {
                Button {
                    isSelectingEntries = false
                    selectedEntryIds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .localizedHelp("Annuler la sélection")
                .localizedAccessibilityLabel("Annuler la sélection")
            } else if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Tous les tricounts")
                .localizedAccessibilityLabel("Tous les tricounts")
            } else {
                Button("Fermer") { paneDismiss() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isSelectingEntries {
                if !selectedEntryIds.isEmpty {
                    if reimbursementsEnabled {
                        PaneToggleButton(label: "Remboursement", systemImage: "arrow.uturn.left.circle", isOn: $showBulkEntryReimburse)
                    }
                    // A custom binding: computing the initial states must stay
                    // triggered on OPEN (as before), not on every
                    // toggle — a plain `$showBulkEntryTagPicker` would lose that.
                    PaneToggleButton(label: "Tags", systemImage: "tag", isOn: Binding(
                        get: { showBulkEntryTagPicker },
                        set: { newValue in
                            if newValue { bulkEntryTagInitialStates = computeBulkEntryTagStates() }
                            showBulkEntryTagPicker = newValue
                        }
                    ))
                }
            } else {
                if selectedTab == 0 {
                    Menu {
                        ForEach(TricountEntrySort.allCases) { s in
                            Button {
                                entrySort = s
                            } label: {
                                if entrySort == s {
                                    Label(s.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(s.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .localizedHelp("Trier")

                    PaneToggleButton(
                        label: "Filtrer",
                        systemImage: activeEntryFiltersCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        isOn: $showEntryFilters
                    )
                }
                Button {
                    isSelectingEntries = true
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .localizedHelp("Sélectionner")
            }
        }
        #else
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelectingEntries {
                Button("Annuler") {
                    isSelectingEntries = false
                    selectedEntryIds.removeAll()
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelectingEntries {
                if !selectedEntryIds.isEmpty {
                    if reimbursementsEnabled {
                        Button {
                            showBulkEntryReimburse = true
                        } label: {
                            Label("Remboursement", systemImage: "arrow.uturn.left.circle")
                        }
                    }
                    Button {
                        bulkEntryTagInitialStates = computeBulkEntryTagStates()
                        showBulkEntryTagPicker = true
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                }
            } else {
                if selectedTab == 0 {
                    Menu {
                        ForEach(TricountEntrySort.allCases) { s in
                            Button {
                                entrySort = s
                            } label: {
                                if entrySort == s {
                                    Label(s.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(s.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .localizedHelp("Trier")

                    PaneToggleButton(
                        label: "Filtrer",
                        systemImage: activeEntryFiltersCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        isOn: $showEntryFilters
                    )
                }
                Button {
                    isSelectingEntries = true
                } label: {
                    Image(systemName: "checkmark.circle")
                }
            }
        }
        #endif
    }

    private func loadEntryTags() {
        entryTagsMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, txRepo.fetchTags(forTricountEntry: $0.id)) })
    }

    private func toggleEntrySelection(_ id: Int) {
        if selectedEntryIds.contains(id) { selectedEntryIds.remove(id) }
        else { selectedEntryIds.insert(id) }
    }

    private func computeBulkEntryTagStates() -> [Int: TagSelectionState] {
        var result: [Int: TagSelectionState] = [:]
        for tag in allTags {
            let count = selectedEntryIds.filter { entryTagsMap[$0]?.contains(where: { $0.id == tag.id }) ?? false }.count
            if count == 0 { result[tag.id] = TagSelectionState.none }
            else if count == selectedEntryIds.count { result[tag.id] = .all }
            else { result[tag.id] = .some }
        }
        return result
    }

    private var summaryHeader: some View {
        HStack(spacing: 0) {
            summaryCell(label: "Mes dépenses", value: mySpentTotal.formatted(.currency(code: group.currency).locale(appState.locale)))
            Divider().frame(height: 40)
            summaryCell(label: "Ma part nette", value: myNetShare.formatted(.currency(code: group.currency).locale(appState.locale)))
            Divider().frame(height: 40)
            summaryCell(
                label: myBalance >= 0 ? "On me doit" : "Je dois",
                value: abs(myBalance).formatted(.currency(code: group.currency).locale(appState.locale)),
                color: myBalance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
            )
        }
        .padding(.vertical, 12)
        .background(AppTheme.Colors.surfaceSecondary)
    }

    private func summaryCell(label: LocalizedStringKey, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
        }.frame(maxWidth: .infinity)
    }



    private var entriesTab: some View {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        let reimbursementByEntry = Dictionary(grouping: reimbursementGroups.flatMap(\.items), by: { $0.tricountEntryId ?? -1 })
        let displayedEntries = filteredSortedEntries
        return List {
            if displayedEntries.isEmpty {
                EmptyStateView(
                    icon: entries.isEmpty ? "creditcard" : "line.3.horizontal.decrease.circle",
                    title: entries.isEmpty ? "Aucune dépense" : "Aucun résultat",
                    message: entries.isEmpty
                        ? "Les dépenses de ce Tricount apparaîtront ici."
                        : "Aucune dépense ne correspond aux filtres actifs."
                )
            }
            ForEach(displayedEntries) { entry in
                let reimbursementNames = Array(
                    Set((reimbursementByEntry[entry.id] ?? []).map(\.payeeName))
                ).sorted()
                let reimbursementLabel = reimbursementNames.isEmpty
                    ? nil
                    : "↩ \(reimbursementNames.joined(separator: ", "))"
                HStack(spacing: 10) {
                    if isSelectingEntries {
                        Image(systemName: selectedEntryIds.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedEntryIds.contains(entry.id) ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                    }
                    TricountEntryRow(
                        entry: entry,
                        myShare: byEntry[entry.id]?.first(where: { $0.memberName == group.myName })?.amount,
                        myName: group.myName,
                        shareCurrency: group.currency,
                        tags: entryTagsMap[entry.id] ?? [],
                        reimbursementLabel: reimbursementLabel
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectingEntries { toggleEntrySelection(entry.id) }
                    else { selectedEntry = entry }
                }
                .rowActions(
                    leading: isSelectingEntries ? [] : [
                        RowAction("Tags", systemImage: "tag", tint: AppTheme.Colors.accentSecondary) { tagQuickEntry = entry }
                    ],
                    trailing: isSelectingEntries ? [] :
                        (reimbursementsEnabled
                         ? [RowAction("Rembourser", systemImage: "arrow.uturn.left.circle.fill", tint: AppTheme.Colors.warning) { quickReimburseEntry = entry }]
                         : [])
                        + [RowAction("Lier", systemImage: "link", tint: AppTheme.Colors.accent) { quickLinkEntry = entry }],
                    leadingFullSwipe: false,
                    trailingFullSwipe: false
                )
                .macGroupedRow(first: entry.id == displayedEntries.first?.id, last: entry.id == displayedEntries.last?.id)
            }
        }
        #if os(macOS)
        .listStyle(.plain)
        // Detaches the 1st card from the Divider() above it (the path with no
        // reimbursements) or from the picker (the path with them) — the same fix as
        // TransactionsView. Applied here, in the List itself, to cover
        // `entriesTab`'s two call sites uniformly.
        .macGroupedListTopGap()
        #endif
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var reimbursementsTab: some View {
        if reimbursementGroups.isEmpty {
            List {
                EmptyStateView(
                    icon: "arrow.uturn.left.circle",
                    title: "Aucun remboursement",
                    message: "Ajoutez des remboursements depuis le détail d'une dépense."
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            // A Form (not a List): static content → native rounded macOS boxes
            // via nemorisFormStyle(), native insetGrouped on iOS.
            Form {
                let groupTotal = reimbursementGroups.reduce(0) { $0 + $1.total }
                Section {
                    HStack {
                        Text(groupTotal >= 0 ? "Total à recevoir" : "Total à payer").fontWeight(.semibold)
                        Spacer()
                        Text(groupTotal, format: .currency(code: group.currency))
                            .fontWeight(.bold)
                            .foregroundStyle(groupTotal >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                    }
                }
                ForEach(reimbursementGroups) { rGroup in
                    Section(rGroup.payeeName) {
                        ForEach(rGroup.items) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.originDescription.isEmpty ? "Dépense Tricount" : item.originDescription)
                                        .font(.subheadline)
                                    Text(item.originDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Text(item.amount, format: .currency(code: item.currency))
                                    .font(.subheadline)
                                    .foregroundStyle(item.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            }
                        }
                        HStack {
                            Text("Sous-total").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            Spacer()
                            Text(rGroup.total, format: .currency(code: group.currency))
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(rGroup.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                }
            }.nemorisFormStyle()
        }
    }
}
