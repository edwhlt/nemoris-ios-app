import SwiftUI
import TipKit

struct TricountDetailView: View {
    let group: TricountGroup
    var initialEntryId: Int? = nil
    /// macOS : retour à la liste des tricounts. Le détail occupe la colonne du
    /// module (navigation interne par état — cf. `TricountListView.body`), il
    /// fournit donc lui-même son retour. nil quand la vue est poussée (iOS) ou
    /// présentée en sheet depuis TransactionsView.
    var onBack: (() -> Void)? = nil
    // paneDismiss : ferme la présentation quand la vue est en sheet (niveau 2,
    // depuis TransactionsView). No-op en pleine page, où c'est `onBack` qui sert.
    @Environment(\.paneDismiss) private var paneDismiss
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

    /// Effet net des règlements déjà effectués (entrées TRANSFER/BALANCE — les
    /// "Remboursement" Tricount entre membres). Exclues de `mySpentTotal`/
    /// `myNetShare` (ce ne sont pas des dépenses partagées) mais elles DOIVENT
    /// quand même ajuster le solde final : sans ça, un règlement déjà reçu ou
    /// payé reste compté comme "encore dû", ce qui faisait diverger le solde
    /// affiché de celui de Tricount dès qu'un membre se réglait.
    private var mySettlementsNet: Double {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        return entries.reduce(0.0) { sum, e in
            let type = e.typeTransaction.uppercased()
            guard type == "TRANSFER" || type == "BALANCE" else { return sum }
            let entryShares = byEntry[e.id] ?? []
            if e.whoPaid == group.myName {
                // J'ai réglé une dette : crédité du montant reçu par l'autre partie.
                let othersTotal = entryShares.filter { $0.memberName != group.myName }.reduce(0.0) { $0 + $1.amount }
                return sum + othersTotal
            } else if let myShare = entryShares.first(where: { $0.memberName == group.myName })?.amount, myShare > 0 {
                // On m'a réglé une dette : débité, cette somme n'est plus due.
                return sum - myShare
            }
            return sum
        }
    }

    // positif = on me doit / négatif = je dois
    private var myBalance: Double { mySpentTotal - myNetShare + mySettlementsNet }

    var body: some View {
        #if os(macOS)
        // Contenu de module en pleine page (drill-down depuis TricountListView) :
        // toolbar NATIVE, avec le retour vers la liste. Présentée en sheet
        // (niveau 2, depuis TransactionsView) : même toolbar native, sans retour
        // — c'est « Fermer » qui sort.
        if onBack != nil {
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
        #else
        NavigationStack {
            detailContent
                .navigationTitle(group.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { nativeToolbarContent }
        }
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if !hasLoaded {
                // Skeleton de la liste d'entrées en attendant le chargement local.
                List {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonTransactionRow()
                            .listRowBackground(AppTheme.Colors.surface)
                    }
                }
                .listStyle(.plain)
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
        // Swipe rapide : lier une transaction
        .adaptivePane(item: $quickLinkEntry) { entry in
            TransactionPickerSheet(txRepo: txRepo, currentId: entry.linkedTransactionId) { tx in
                repo.updateLinkedTransaction(entryId: entry.id, transactionId: tx.id)
                entries = repo.fetchEntries(groupId: group.id)
            }
        }
        // Swipe rapide : gérer les tags d'une entrée
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

    // MARK: - Toolbar (retour/fermer + sélection ou actions groupées)

    @ToolbarContentBuilder
    private var nativeToolbarContent: some ToolbarContent {
        #if os(macOS)
        // Pleine page (drill-down) : retour vers la liste, au placement du back
        // système. En sheet (niveau 2) : « Fermer ». Jamais les deux.
        ToolbarItem(placement: .navigation) {
            if isSelectingEntries {
                Button("Annuler") {
                    isSelectingEntries = false
                    selectedEntryIds.removeAll()
                }
            } else if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .help("Tous les tricounts")
                .accessibilityLabel("Tous les tricounts")
            } else {
                Button("Fermer") { paneDismiss() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isSelectingEntries {
                if !selectedEntryIds.isEmpty {
                    if reimbursementsEnabled {
                        Button {
                            showBulkEntryReimburse = true
                        } label: {
                            Image(systemName: "arrow.uturn.left.circle")
                        }
                        .help("Remboursement")
                    }
                    Button {
                        bulkEntryTagInitialStates = computeBulkEntryTagStates()
                        showBulkEntryTagPicker = true
                    } label: {
                        Image(systemName: "tag")
                    }
                    .help("Tags")
                }
            } else {
                Button {
                    isSelectingEntries = true
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Sélectionner")
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
            summaryCell(label: "Mes dépenses", value: mySpentTotal.formatted(.currency(code: group.currency)))
            Divider().frame(height: 40)
            summaryCell(label: "Ma part nette", value: myNetShare.formatted(.currency(code: group.currency)))
            Divider().frame(height: 40)
            summaryCell(
                label: myBalance >= 0 ? "On me doit" : "Je dois",
                value: abs(myBalance).formatted(.currency(code: group.currency)),
                color: myBalance >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
            )
        }
        .padding(.vertical, 12)
        .background(AppTheme.Colors.surfaceSecondary)
    }

    private func summaryCell(label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
        }.frame(maxWidth: .infinity)
    }



    private var entriesTab: some View {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        let reimbursementByEntry = Dictionary(grouping: reimbursementGroups.flatMap(\.items), by: { $0.tricountEntryId ?? -1 })
        return List {
            ForEach(entries) { entry in
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
            }
        }.listStyle(.plain)
    }

    @ViewBuilder
    private var reimbursementsTab: some View {
        if reimbursementGroups.isEmpty {
            List {
                ContentUnavailableView(
                    "Aucun remboursement",
                    systemImage: "arrow.uturn.left.circle",
                    description: Text("Ajoutez des remboursements depuis le détail d'une dépense.")
                )
            }.listStyle(.plain)
        } else {
            // Form (pas List) : liste statique → boxes arrondies natives macOS
            // via nemorisFormStyle(), insetGrouped natif sur iOS.
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
                                    Text(item.originDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Text(item.amount.formatted(.currency(code: item.currency)))
                                    .font(.subheadline)
                                    .foregroundStyle(item.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            }
                        }
                        HStack {
                            Text("Sous-total").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            Spacer()
                            Text(rGroup.total.formatted(.currency(code: group.currency)))
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(rGroup.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                }
            }.nemorisFormStyle()
        }
    }
}
