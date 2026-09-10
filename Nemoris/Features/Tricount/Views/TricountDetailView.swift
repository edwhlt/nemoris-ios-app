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
    // iOS : distingue "poussée depuis TricountListView" (.root, ambiante déjà
    // gérée par la NavigationStack du parent) de "présentée en sheet depuis
    // TransactionsView" (.modal, cf. `.adaptivePane(item:)` dans
    // AdaptivePaneItemModifier). C'est ce qui pilote le `if` de `body`
    // ci-dessous — cf. son commentaire pour le bug que ça corrige.
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

    // Tri & filtres de la liste des dépenses — état volontairement NON
    // persisté (comme la recherche texte de TransactionsView) : un tri/filtre
    // laissé actif d'une session à l'autre serait plus surprenant qu'utile.
    @State private var showEntryFilters = false
    @State private var entrySort: TricountEntrySort = .dateDesc
    @State private var entryTitleSearch = ""
    @State private var entryLinkFilter: TricountLinkFilter = .all
    /// "" = tous les payeurs.
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

    // MARK: - Tri & filtres des dépenses

    /// "Moi" pour le nom du membre courant, le nom brut sinon — même
    /// convention que `TricountEntryRow.isPaidByMe`.
    private func payerDisplayName(_ name: String) -> String {
        name == group.myName ? "Moi" : name
    }

    /// Noms bruts des payeurs présents dans le groupe, dédupliqués et triés
    /// sur leur libellé affiché (donc "Moi" trié à sa place alphabétique réelle).
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

    /// Bornes réelles des dates de dépenses du groupe — cadre le `DatePicker`
    /// du filtre et sert de défaut à son activation (période complète plutôt
    /// que "aujourd'hui" des deux côtés, qui masquerait tout).
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

    /// Dépenses filtrées + triées pour l'affichage. `entries` (brut, ordre SQL)
    /// reste la source des totaux du header — filtrer ne doit jamais changer
    /// le solde affiché, seulement la liste visible.
    private var filteredSortedEntries: [TricountEntry] {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        let minShare = entryMinShareValue
        let maxShare = entryMaxShareValue
        let cal = Calendar.current
        // Bornes inclusives par JOUR calendaire — `entry.date` peut porter une
        // heure (import bancaire) alors que le `DatePicker` ne choisit qu'un
        // jour ; sans normaliser "Au" à la fin de journée, une dépense datée
        // en fin d'après-midi du jour sélectionné serait exclue à tort.
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
                // Pas de part connue pour cette dépense (ex. TRANSFER/BALANCE) :
                // ne peut pas satisfaire une borne demandée.
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
        // Contenu de module en pleine page (drill-down depuis TricountListView) :
        // toolbar NATIVE, avec le retour vers la liste (fenêtre principale, jamais
        // affectée par le bug ci-dessous). Présentée en sheet (niveau 2, depuis
        // TransactionsView) : la barre d'outils native d'une `.sheet` macOS a son
        // propre matériau translucide qui laisse le bureau de l'utilisateur
        // transparaître, quel que soit son contenu — chrome dessinée à la main à
        // la place (retour d'usage 2026-08-21, cf. `macSheetChrome` dans
        // AdaptivePane.swift). Le contenu du menu (mode sélection, actions groupées)
        // est mirroré plutôt que routé via `.paneChrome` : trop dynamique pour son
        // modèle à 3 boutons cancel/destructive/confirm.
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
        // ⚠️ iOS — ne JAMAIS envelopper `detailContent` dans une `NavigationStack`
        // propre quand cette vue est POUSSÉE (retour d'usage : ouvrir un tricount
        // pour la première fois éjecte vers "Plus", uniquement quand Tricount vit
        // dans le menu "Plus"). Cause : `TricountListView` pousse cette vue via un
        // `NavigationLink(destination:)` classique sur SA propre pile ambiante
        // (celle de l'onglet Tricount, ou celle de `MoreView` s'il est caché) —
        // exactement le même mécanisme, une fois de plus, que le bug déjà
        // documenté et corrigé dans `TricountListView.body` (mélange de styles de
        // navigation sur une même pile). Y ajouter ICI une SECONDE
        // `NavigationStack`, imbriquée dans le contenu qui vient d'être poussé,
        // reproduit le même anti-pattern un niveau plus bas : UIKit peut alors
        // avaler le tout premier push de la session et faire retomber la pile
        // ambiante jusqu'à sa racine. `\.paneHostContext` distingue les deux
        // usages réels de cette vue : `.root` = poussée depuis `TricountListView`
        // (la pile ambiante gère déjà titre/back/toolbar, rien à envelopper) ;
        // `.modal` = présentée en sheet depuis `TransactionsView` via
        // `.adaptivePane(item:)`, qui N'INJECTE aucune `NavigationStack` pour son
        // contenu — celle-ci reste nécessaire pour que titre/toolbar s'affichent.
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
                // Skeleton de la liste d'entrées en attendant le chargement local.
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
        // Fond de l'app posé explicitement — sans lui la colonne « content » de
        // la NavigationSplitView macOS montre son matériau vibrant par défaut
        // au lieu du fond neutre AppTheme (). C'est l'écran
        // exact du retour d'usage (détail Tricount, ex. « Vietnam »).
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

    #if os(macOS)
    /// Mirroir de `nativeToolbarContent`, en vues ordinaires plutôt qu'en
    /// `ToolbarContent`, pour le SEUL cas `.sheet` niveau 2 (`onBack == nil`).
    /// Même logique de mode (sélection / normal), mêmes actions — mais
    /// dessiné à la main, cf. le commentaire de `body` ci-dessus.
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
        // Pleine page (drill-down) : retour vers la liste, au placement du back
        // système. En sheet (niveau 2) : « Fermer ». Jamais les deux.
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
                    // Binding custom : le calcul des états initiaux doit rester
                    // déclenché à l'OUVERTURE (comme avant), pas à chaque
                    // bascule — un simple `$showBulkEntryTagPicker` le perdrait.
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
        // Décolle la 1ère carte du Divider() du dessus (chemin sans
        // remboursements) ou du picker (chemin avec) — même correctif que
        // TransactionsView. Appliqué ici, dans la List elle-même, pour couvrir
        // les deux points d'appel de `entriesTab` uniformément.
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
