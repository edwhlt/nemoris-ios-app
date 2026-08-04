import SwiftUI
import Security
import TipKit

// MARK: - API Codable structs (private)

private struct TCAuthResponse: Decodable {
    let Response: [TCAuthItem]
}
private struct TCAuthItem: Decodable {
    let Token: TCToken?
    let UserPerson: TCUserPerson?
}
private struct TCToken: Decodable { let token: String }
private struct TCUserPerson: Decodable { let id: Int }

private struct TCDataResponse: Decodable {
    let Response: [TCDataItem]
}
private struct TCDataItem: Decodable {
    let Registry: TCRegistry?
}
private struct TCRegistry: Decodable {
    let title: String
    let memberships: [TCMembershipWrapper]
    let all_registry_entry: [TCEntryWrapper]
}
private struct TCMembershipWrapper: Decodable {
    let RegistryMembershipNonUser: TCMemberNonUser
}
private struct TCMemberNonUser: Decodable {
    let alias: TCAlias
}
private struct TCAlias: Decodable {
    let display_name: String
}
private struct TCEntryWrapper: Decodable {
    let RegistryEntry: TCEntry
}
private struct TCEntry: Decodable {
    let uuid: String
    let updated: String
    let type_transaction: String
    let membership_owned: TCMembershipWrapper
    let amount: TCAmount
    let amount_local: TCAmount?
    let description: String?
    let date: String
    let allocations: [TCAllocation]
    let category: String
}
private struct TCAmount: Decodable {
    let value: String
    let currency: String?
}
private struct TCAllocation: Decodable {
    let membership: TCMembershipWrapper
    let amount: TCAmount
}

// MARK: - Fetch result

struct TricountFetchResult {
    let title: String
    let currency: String
    let members: [String]
    let entries: [ParsedTCEntry]
}

// MARK: - Error

enum TricountError: LocalizedError {
    case rsaKeyGeneration
    case authFailed(String)
    case fetchFailed(String)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .rsaKeyGeneration: return "Erreur de génération des clés RSA"
        case .authFailed(let m): return "Authentification échouée : \(m)"
        case .fetchFailed(let m): return "Chargement échoué : \(m)"
        case .invalidData: return "Données Tricount invalides"
        }
    }
}

// MARK: - API Client

private struct TricountAPIClient {
    private let baseURL = "https://api.tricount.bunq.com"
    private let userAgent = "com.bunq.tricount.android:RELEASE:7.0.7:3174:ANDROID:13:C"

    func fetch(key: String) async throws -> TricountFetchResult {
        let (token, userId) = try await authenticate()
        let data = try await fetchData(key: key, token: token, userId: userId)
        return try parse(data)
    }

    private func authenticate() async throws -> (token: String, userId: Int) {
        guard let pem = generatePublicKeyPEM() else { throw TricountError.rsaKeyGeneration }
        let installId = UUID().uuidString
        var req = URLRequest(url: URL(string: "\(baseURL)/v1/session-registry-installation")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(installId, forHTTPHeaderField: "app-id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Bunq-Client-Request-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_installation_uuid": installId,
            "client_public_key": pem,
            "device_description": "Android"
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw TricountError.authFailed(String(data: data, encoding: .utf8) ?? "HTTP \(code)")
        }
        let decoded = try JSONDecoder().decode(TCAuthResponse.self, from: data)
        guard let token = decoded.Response.first(where: { $0.Token != nil })?.Token?.token,
              let userId = decoded.Response.first(where: { $0.UserPerson != nil })?.UserPerson?.id
        else { throw TricountError.authFailed("Token ou userId manquant") }
        return (token, userId)
    }

    private func fetchData(key: String, token: String, userId: Int) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(baseURL)/v1/user/\(userId)/registry?public_identifier_token=\(key)")!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(token, forHTTPHeaderField: "X-Bunq-Client-Authentication")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Bunq-Client-Request-Id")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw TricountError.fetchFailed("HTTP \(code)") }
        return data
    }

    private func parse(_ data: Data) throws -> TricountFetchResult {
        let decoded = try JSONDecoder().decode(TCDataResponse.self, from: data)
        guard let registry = decoded.Response.first?.Registry else { throw TricountError.invalidData }
        let members = registry.memberships.map { $0.RegistryMembershipNonUser.alias.display_name }
        let currency = registry.all_registry_entry.first?.RegistryEntry.amount.currency ?? "EUR"
        let entries: [ParsedTCEntry] = registry.all_registry_entry.map { wrapper in
            let e = wrapper.RegistryEntry
            return ParsedTCEntry(
                sourceUUID: e.uuid,
                sourceUpdatedAt: e.updated,
                typeTransaction: e.type_transaction,
                whoPaid: e.membership_owned.RegistryMembershipNonUser.alias.display_name,
                total: (Double(e.amount.value) ?? 0) * -1,
                currency: e.amount.currency ?? currency,
                localTotal: e.amount_local.map { (Double($0.value) ?? 0) * -1 },
                localCurrency: e.amount_local?.currency ?? e.amount.currency ?? currency,
                description: e.description ?? "",
                date: String(e.date.prefix(10)),
                shares: e.allocations.map {
                    (memberName: $0.membership.RegistryMembershipNonUser.alias.display_name,
                     amount: abs(Double($0.amount.value) ?? 0))
                },
                category: e.category
            )
        }
        return TricountFetchResult(title: registry.title, currency: currency, members: members, entries: entries)
    }

    private func generatePublicKeyPEM() -> String? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]
        var err: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pubKey = SecKeyCopyPublicKey(privKey),
              let keyData = SecKeyCopyExternalRepresentation(pubKey, &err) as Data?
        else { return nil }

        // iOS returns SubjectPublicKeyInfo (SPKI/PKCS#8); strip 24-byte header for PKCS#1
        let pkcs1: Data = (keyData.count > 26 && keyData[0] == 0x30 && keyData[4] == 0x30)
            ? keyData.dropFirst(24) : keyData

        let b64 = pkcs1.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN RSA PUBLIC KEY-----\n\(b64)\n-----END RSA PUBLIC KEY-----\n"
    }
}

// MARK: - Tricount List View

struct TricountListView: View {
    @State private var groups: [TricountGroup] = []
    @State private var showLoadSheet = false
    /// Ouvre le détail dans le panneau (adaptivePane), plus un push — cohérent
    /// avec le reste de l'app (transactions, tiers, comptes Investissements…) :
    /// un seul mental model de drill-down partout, et ça évite le "bouton
    /// retour" du push qui désynchronisait l'affichage lors d'un changement
    /// de module (`NavigationSplitView` gardait l'ancien contenu poussé).
    @State private var selectedGroup: TricountGroup?
    #if os(macOS)
    /// Pour fermer le panneau au retour vers la liste (cf. `onBack`).
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif
    @State private var refreshingId: Int? = nil
    @State private var refreshError: String? = nil
    /// Skeleton tant que le 1er `loadGroups()` n'est pas terminé.
    @State private var hasLoaded = false
    private let repo = TricountRepository()
    private let client = TricountAPIClient()
    @Environment(PurchaseManager.self) private var store

    var isEmbedded: Bool = false

    var body: some View {
        Group {
            #if os(macOS)
            // macOS : le détail d'un tricount remplace la liste DANS LA COLONNE
            // (navigation interne par état, comme la fiche compte des
            // Investissements). Un tricount est un CONTENEUR d'entrées — chaque
            // entrée a son propre détail, qui lui s'ouvre dans l'inspecteur.
            // Règle : conteneur → pleine page, feuille → inspecteur.
            if let group = selectedGroup {
                // Fermeture explicite du panneau au retour (cf. InvestmentsView) :
                // il ne doit pas survivre au tricount qui l'a ouvert.
                TricountDetailView(group: group, onBack: {
                    paneCenter?.dismissCurrent()
                    selectedGroup = nil
                })
            } else if isEmbedded {
                listContent
            } else {
                NavigationStack { listContent }
            }
            #else
            if isEmbedded { listContent } else { NavigationStack { listContent } }
            #endif
        }
        //.paywallOverlay(for: .tricount)
    }

    @ViewBuilder private var listContent: some View {
        Group {
            if !hasLoaded {
                List {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonAccountRow()
                            .listRowBackground(AppTheme.Colors.surface)
                    }
                }
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "Aucun Tricount",
                    systemImage: "person.2",
                    description: Text("Appuyez sur + pour charger un Tricount")
                )
            } else {
                List {
                    ForEach(groups) { group in
                        Button {
                            selectedGroup = group
                        } label: {
                            TricountGroupRow(group: group, isRefreshing: refreshingId == group.id)
                        }
                        .buttonStyle(.plain)
                        .rowActions(
                            leading: [RowAction("Mettre à jour", systemImage: "arrow.clockwise", tint: AppTheme.Colors.accent) { refreshGroup(group) }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { deleteGroup(group) }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                    }
                }
            }
        }
        .navigationTitle("Tricounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLoadSheet = true } label: { Image(systemName: "plus") }
            }
        }
        // macOS : `selectedGroup` bascule le CONTENU du module (cf. `body`) —
        // pas de présentation ici. iOS : push piloté par item. Un `Binding(get:set:)`
        // synthétique (nécessaire tant que `TricountGroup` n'était pas Hashable)
        // provoquait un pop immédiat au tout premier push de la session — bug
        // connu de `.navigationDestination(isPresented:)` avec un binding calculé
        // au lieu d'un stockage `@State` direct. `item:` est piloté directement
        // par `$selectedGroup`, sans binding intermédiaire.
        #if !os(macOS)
        .navigationDestination(item: $selectedGroup) { group in
            TricountDetailView(group: group)
        }
        #endif
        .adaptivePane(isPresented: $showLoadSheet) {
            TricountLoadSheet { repo.setupTables(); loadGroups() }
        }
        .task {
            await Task.yield()
            repo.setupTables()
            loadGroups()
            hasLoaded = true
        }
        .alert("Erreur de rafraîchissement", isPresented: Binding(
            get: { refreshError != nil },
            set: { if !$0 { refreshError = nil } }
        )) {
            Button("OK") { refreshError = nil }
        } message: {
            Text(refreshError ?? "")
        }
    }

    private func loadGroups() { groups = repo.fetchGroups() }
    private func deleteGroup(_ g: TricountGroup) { repo.deleteGroup(id: g.id); loadGroups() }

    private func refreshGroup(_ group: TricountGroup) {
        guard refreshingId == nil else { return }
        refreshingId = group.id
        Task {
            do {
                let result = try await client.fetch(key: group.tricountKey)
                await MainActor.run {
                    let myEntries = result.entries.filter { entry in
                        entry.whoPaid == group.myName ||
                        entry.shares.contains { $0.memberName == group.myName }
                    }
                    if let gid = repo.saveGroup(key: group.tricountKey, title: result.title,
                                                currency: result.currency, myName: group.myName,
                                                entries: myEntries) {
                        Task { await CurrencyRateService.syncRates(groupId: gid) }
                    } else {
                        refreshError = """
                        saveGroup a échoué.
                        Entrées API : \(result.entries.count)
                        Après filtre '\(group.myName)' : \(myEntries.count)
                        Exemples payeurs : \(Set(result.entries.prefix(5).map(\.whoPaid)).joined(separator: ", "))
                        SQLite : \(TricountRepository.lastSaveError ?? "inconnu")
                        """
                    }
                    refreshingId = nil
                    loadGroups()
                }
            } catch {
                await MainActor.run {
                    refreshingId = nil
                    refreshError = "Erreur réseau / API : \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Group Row

private struct TricountGroupRow: View {
    let group: TricountGroup
    var isRefreshing: Bool = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline)
                Text("\(group.entryCount) entrées · \(group.myName)")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            if isRefreshing {
                ProgressView().padding(.trailing, 4)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(group.fetchedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text(group.currency).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Load Sheet

struct TricountLoadSheet: View {
    let onSaved: () -> Void
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    private enum LoadState { case input, loading, selectMember(TricountFetchResult), error(String) }

    @State private var state: LoadState = .input
    @State private var urlInput = ""
    @State private var selectedMember = ""
    private let repo = TricountRepository()
    private let client = TricountAPIClient()

    var body: some View {
            Group {
                switch state {
                case .input:
                    Form {
                        Section {
                            TextField("https://tricount.com/fr/XXXXXX", text: $urlInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        } header: { Text("Lien ou code Tricount") } footer: {
                            Text("Collez le lien de partage du Tricount.")
                        }
                        Section {
                            Button("Charger") { load() }
                                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .nemorisFormStyle()

                case .loading:
                    VStack(spacing: 16) {
                        ProgressView("Chargement…")
                        Text("Authentification RSA en cours").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)

                case .selectMember(let result):
                    Form {
                        Section("Tricount chargé") {
                            LabeledContent("Titre", value: result.title)
                            LabeledContent("Entrées", value: "\(result.entries.count)")
                            LabeledContent(
                                "Dépenses",
                                value: result.entries
                                    .filter { $0.typeTransaction.uppercased() == "NORMAL" && $0.total > 0 }
                                    .reduce(0.0) { $0 + $1.total }
                                    .formatted(.currency(code: result.currency))
                            )
                            LabeledContent("Devise", value: result.currency)
                        }
                        Section {
                            ForEach(result.members, id: \.self) { member in
                                HStack {
                                    Text(member)
                                    Spacer()
                                    if selectedMember == member {
                                        Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedMember = member }
                            }
                        } header: { Text("Je suis…") } footer: {
                            Text("Sélectionnez votre nom pour calculer vos parts.")
                        }
                        Section {
                            Button("Enregistrer") { save(result: result) }
                                .disabled(selectedMember.isEmpty)
                        }
                    }
                    .nemorisFormStyle()

                case .error(let msg):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(AppTheme.Colors.danger)
                        Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Réessayer") { state = .input }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .paneChrome("Charger un Tricount", cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    private func load() {
        let key = extractKey(urlInput.trimmingCharacters(in: .whitespaces))
        state = .loading
        Task {
            do {
                let result = try await client.fetch(key: key)
                await MainActor.run {
                    selectedMember = result.members.first ?? ""
                    state = .selectMember(result)
                }
            } catch {
                await MainActor.run { state = .error(error.localizedDescription) }
            }
        }
    }

    private func save(result: TricountFetchResult) {
        let key = extractKey(urlInput.trimmingCharacters(in: .whitespaces))
        guard DatabaseManager.shared.hasDatabase() else {
            state = .error("Aucune base de données configurée. Importez d'abord un fichier SQLite.")
            return
        }
        DatabaseManager.shared.migrateIfNeeded()
        let myEntries = result.entries.filter { entry in
            entry.whoPaid == selectedMember ||
            entry.shares.contains { $0.memberName == selectedMember }
        }
        let savedId = repo.saveGroup(key: key, title: result.title, currency: result.currency,
                                     myName: selectedMember, entries: myEntries)
        if let gid = savedId {
            Task { await CurrencyRateService.syncRates(groupId: gid) }
            onSaved()
            dismiss()
        } else {
            state = .error("Impossible d'enregistrer le Tricount. Vérifiez que la base de données est accessible en écriture.")
        }
    }

    private func extractKey(_ input: String) -> String {
        if let range = input.range(of: #"tricount\.com/(?:[a-z]{1,3}/)?([^/?#\s]+)"#, options: .regularExpression) {
            return String(input[range]).components(separatedBy: "/").last ?? input
        }
        return input.components(separatedBy: "/").last?.components(separatedBy: "?").first ?? input
    }
}

// MARK: - Detail View

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

// MARK: - Entry Row

private struct TricountEntryRow: View {
    let entry: TricountEntry
    let myShare: Double?
    let myName: String
    let shareCurrency: String
    var tags: [Tag] = []
    var reimbursementLabel: String? = nil

    private var displayShare: Double? {
        guard let myShare else { return nil }
        let type = entry.typeTransaction.uppercased()
        if type == "TRANSFER" || type == "BALANCE" { return nil }
        // INCOME : revenu → ma part est positive (je reçois de l'argent)
        if type == "INCOME" { return myShare }
        // NORMAL : dépense → ma part est toujours négative (argent dépensé)
        return -myShare
    }

    /// Total affiché avec le bon signe selon la convention comptable :
    /// dépense = négatif, revenu = positif, transfert = positif
    private var displayTotal: Double {
        let type = entry.typeTransaction.uppercased()
        if type == "NORMAL" { return -entry.total }
        return entry.total
    }

    private var entryTypeLabel: String {
        switch entry.typeTransaction.uppercased() {
        case "NORMAL":   return "Dépense"
        case "INCOME":   return "Revenu"
        case "BALANCE", "TRANSFER": return "Transfert"
        default:         return entry.typeTransaction
        }
    }

    /// Icône neutre — la couleur du montant porte déjà l'information dépense/revenu.
    private var iconColor: Color { .secondary }

    private var shouldShowLocalAmount: Bool {
        guard let localTotal = entry.localTotal,
              let localCurrency = entry.localCurrency,
              !localCurrency.isEmpty else {
            return false
        }
        return localCurrency.uppercased() != entry.currency.uppercased() || abs(localTotal - entry.total) > 0.005
    }

    private var isPaidByMe: Bool { entry.whoPaid == myName }
    private var isLinked: Bool { entry.linkedTransactionId != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: categoryIcon(entry.category))
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description.isEmpty
                     ? entry.category.lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                     : entry.description)
                    .font(.body)
                    .lineLimit(1)
                // Ligne info : payeur · date · liée
                HStack(spacing: 4) {
                    Text(isPaidByMe ? "Moi" : entry.whoPaid)
                        .font(.caption)
                        .fontWeight(isPaidByMe ? .semibold : .regular)
                        .foregroundStyle(isPaidByMe ? .primary : .secondary)
                        .lineLimit(1)
                    Text("·").font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        .lineLimit(1)
                    if isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.success)
                    }
                }
                if let reimbursementLabel, !reimbursementLabel.isEmpty {
                    Text(reimbursementLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.warning.opacity(0.13), in: Capsule())
                        .foregroundStyle(AppTheme.Colors.warning)
                        .lineLimit(1)
                }
                // Tags chips
                if !tags.isEmpty {
                    let chips = HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Text(tag.name)
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tag.displayColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(tag.displayColor)
                        }
                    }
                    // ⚠️ macOS : JAMAIS de ScrollView dans une row de List. Un scroll
                    // (ici horizontal, pour les chips) mesuré dans une cellule
                    // NSTableView provoque une « reentrant operation in NSTableView
                    // delegate » → boucle de layout → la barre de fenêtre et le
                    // bouton retour des vues poussées vibrent EN PERMANENCE. Sur Mac
                    // on rend les chips dans un HStack clippé (largeur de row large
                    // en desktop, la plupart tiennent). iOS garde le scroll tactile.
                    #if os(macOS)
                    chips
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    #else
                    ScrollView(.horizontal, showsIndicators: false) { chips }
                    #endif
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(displayTotal.formatted(.currency(code: entry.currency)))
                    .font(.subheadline).bold()
                    .foregroundStyle(displayTotal < 0 ? AppTheme.Colors.danger : (displayTotal > 0 ? AppTheme.Colors.success : AppTheme.Colors.textPrimary))
                if shouldShowLocalAmount,
                   let localTotal = entry.localTotal,
                   let localCurrency = entry.localCurrency {
                    let displayLocalTotal = entry.typeTransaction.uppercased() == "NORMAL" ? -localTotal : localTotal
                    Text(displayLocalTotal.formatted(.currency(code: localCurrency)))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                }
                if let share = displayShare, abs(share) > 0.005 {
                    Text("Part : \(share.formatted(.currency(code: shareCurrency)))")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func categoryIcon(_ cat: String) -> String {
        switch cat.uppercased() {
        case "FOOD_AND_DRINK": return "fork.knife"
        case "GROCERIES": return "cart"
        case "TRANSPORTATION": return "car"
        case "ACCOMMODATION": return "house"
        case "ENTERTAINMENT": return "ticket"
        case "HEALTH": return "heart"
        case "SHOPPING": return "bag"
        case "BALANCE": return "arrow.left.arrow.right"
        case "INCOME": return "plus.circle"
        default: return "creditcard"
        }
    }
}

// MARK: - Entry Detail Sheet

struct TricountEntryDetailSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let entry: TricountEntry
    let myShare: Double?
    let myName: String
    let groupCurrency: String
    let repo: TricountRepository
    let txRepo: TransactionRepository
    let reimbursementRepo: ReimbursementRepository
    let allTags: [Tag]
    let onChanged: () -> Void

    @State private var reimbursements: [Reimbursement] = []
    /// Ligne en cours d'édition via "Modifier…" — nil pour un nouvel assignement.
    /// Distingue une vraie mise à jour (par id) d'un nouvel upsert, pour ne
    /// jamais dupliquer silencieusement si le payee change (fix bug v44 AXE R).
    @State private var editingReimbursement: Reimbursement? = nil
    @State private var linkedTransaction: FinanceTransaction? = nil
    @State private var entryTags: [Tag] = []
    @State private var localAllTags: [Tag]
    @State private var showTransactionPicker = false
    @State private var showAddReimbursement = false
    @State private var showTagPicker = false
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    init(entry: TricountEntry, myShare: Double?, myName: String, groupCurrency: String,
         repo: TricountRepository, txRepo: TransactionRepository, reimbursementRepo: ReimbursementRepository,
         allTags: [Tag], onChanged: @escaping () -> Void) {
        self.entry = entry
        self.myShare = myShare
        self.myName = myName
        self.groupCurrency = groupCurrency
        self.repo = repo
        self.txRepo = txRepo
        self.reimbursementRepo = reimbursementRepo
        self.allTags = allTags
        self.onChanged = onChanged
        _localAllTags = State(initialValue: allTags)
    }

    private var isPaidByMe: Bool { entry.whoPaid == myName }

    private var displayShare: Double? {
        guard let s = myShare else { return nil }
        let type = entry.typeTransaction.uppercased()
        if type == "TRANSFER" || type == "BALANCE" { return nil }
        if type == "INCOME" { return s }   // revenu → positif
        return -s                           // dépense → toujours négatif
    }

    private var displayTotal: Double {
        entry.typeTransaction.uppercased() == "NORMAL" ? -entry.total : entry.total
    }

    private var entryTypeLabel: String {
        switch entry.typeTransaction.uppercased() {
        case "NORMAL":   return "Dépense"
        case "INCOME":   return "Revenu"
        case "BALANCE", "TRANSFER": return "Transfert"
        default:         return entry.typeTransaction
        }
    }

    var body: some View {
            Form {
                // Infos de la dépense
                Section("Dépense") {
                    LabeledContent("Type") {
                        Text(entryTypeLabel).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    LabeledContent("Description") {
                        Text(entry.description.isEmpty
                             ? entry.category.lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                             : entry.description)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    LabeledContent("Payé par") { Text(entry.whoPaid == myName ? "Moi" : entry.whoPaid).foregroundStyle(AppTheme.Colors.textSecondary) }
                    LabeledContent("Total") {
                        Text(displayTotal.formatted(.currency(code: entry.currency)))
                            .foregroundStyle(displayTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    if let share = displayShare {
                        LabeledContent("Ma part") {
                            Text(share.formatted(.currency(code: groupCurrency)))
                                // positif = je reçois / négatif = je dois
                                .foregroundStyle(share >= 0 ? AppTheme.Colors.accent : AppTheme.Colors.danger)
                        }
                    }
                    LabeledContent("Date") {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                // Transaction liée
                Section("Transaction liée") {
                    if let tx = linkedTransaction {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                    .font(.subheadline)
                                Spacer()
                                Text(tx.amount.formatted(.currency(code: "EUR")))
                                    .font(.subheadline).bold()
                                    .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            }
                            Text(tx.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Button("Modifier le lien") { showTransactionPicker = true }
                        Button("Supprimer le lien", role: .destructive) {
                            repo.updateLinkedTransaction(entryId: entry.id, transactionId: nil)
                            linkedTransaction = nil
                            onChanged()
                        }
                    } else {
                        Text("Aucune transaction liée")
                            .foregroundStyle(AppTheme.Colors.textSecondary).font(.caption)
                        Button("Lier une transaction…") { showTransactionPicker = true }
                    }
                }

                // Tags
                Section("Tags") {
                    Button {
                        showTagPicker = true
                    } label: {
                        HStack {
                            Label("Tags", systemImage: "tag").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if entryTags.isEmpty {
                                Text("Aucun").foregroundStyle(AppTheme.Colors.textSecondary)
                            } else {
                                Text(entryTags.map(\.name).joined(separator: ", "))
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }

                // Remboursements Tricount (1 seul max par entrée)
                if reimbursementsEnabled {
                    Section {
                        if let r = reimbursements.first {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.payeeName).font(.subheadline)
                                }
                                Spacer()
                                Text(abs(r.amount).formatted(.currency(code: r.currency)))
                                    .font(.subheadline).foregroundStyle(AppTheme.Colors.success)
                            }
                            Button("Modifier…") {
                                editingReimbursement = r
                                showAddReimbursement = true
                            }
                            Button("Supprimer", role: .destructive) {
                                reimbursementRepo.deleteReimbursement(id: r.id)
                                reimbursements = []
                                onChanged()
                            }
                        } else {
                            Text("Aucun remboursement").foregroundStyle(AppTheme.Colors.textSecondary).font(.caption)
                            Button("Assigner un remboursement…") {
                                editingReimbursement = nil
                                showAddReimbursement = true
                            }
                        }
                    } header: {
                        Text("Remboursement")
                    } footer: {
                        if displayShare != nil {
                            Text("Le montant par défaut est votre part sur cette dépense.")
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear { loadData() }
            .adaptivePane(isPresented: $showTagPicker) {
                TagManagementSheet(
                    initialTagIds: Set(entryTags.map(\.id)),
                    allTags: localAllTags,
                    repository: txRepo,
                    onSave: { tagIds in
                        txRepo.setTags(Array(tagIds), forTricountEntry: entry.id)
                        entryTags = txRepo.fetchTags(forTricountEntry: entry.id)
                    },
                    onNewTag: { newTag in
                        if !localAllTags.contains(where: { $0.id == newTag.id }) {
                            localAllTags.append(newTag)
                            localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        }
                    }
                )
            }
            .adaptivePane(isPresented: $showTransactionPicker) {
                TransactionPickerSheet(txRepo: txRepo, currentId: entry.linkedTransactionId) { tx in
                    repo.updateLinkedTransaction(entryId: entry.id, transactionId: tx.id)
                    linkedTransaction = tx
                    onChanged()
                }
            }
            .adaptivePane(isPresented: $showAddReimbursement) {
                AddTricountReimbursementSheet(
                    // On passe la valeur absolue : un remboursement est toujours un montant > 0
                    // (ce qu'on attend de recevoir, peu importe le signe de la part)
                    defaultAmount: abs(displayShare ?? 0),
                    currency: groupCurrency,
                    existingReimbursement: editingReimbursement
                ) { tiersId, amount, currency in
                    if let existing = editingReimbursement {
                        // Édition par id : met à jour la ligne existante même si
                        // le payee change, ne duplique jamais (fix bug v44 AXE R).
                        reimbursementRepo.updateReimbursement(id: existing.id, payeeId: tiersId, amount: amount, currency: currency)
                    } else {
                        reimbursementRepo.addOrUpdateReimbursement(tricountEntryId: entry.id, payeeId: tiersId, amount: amount, currency: currency)
                    }
                    reimbursements = reimbursementRepo.fetchReimbursements(forTricountEntry: entry.id)
                    onChanged()
                }
            }
            .paneChrome("Détail dépense", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    private func loadData() {
        reimbursements = reimbursementRepo.fetchReimbursements(forTricountEntry: entry.id)
        entryTags = txRepo.fetchTags(forTricountEntry: entry.id)
        if let txId = entry.linkedTransactionId {
            linkedTransaction = txRepo.fetchAllTransactions(limit: 2000).first(where: { $0.id == txId })
        }
    }
}

// MARK: - Transaction Picker Sheet

struct TransactionPickerSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let txRepo: TransactionRepository
    let currentId: Int?
    let onSelect: (FinanceTransaction) -> Void

    @State private var transactions: [FinanceTransaction] = []
    @State private var search = ""

    private var filtered: [FinanceTransaction] {
        guard !search.isEmpty else { return transactions }
        return transactions.filter {
            $0.tiersName.localizedCaseInsensitiveContains(search) ||
            $0.information.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
            List(filtered) { tx in
                Button {
                    onSelect(tx)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                .font(.subheadline).foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(tx.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            if !tx.information.isEmpty && !tx.tiersName.isEmpty {
                                Text(tx.information).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5)).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(tx.amount.formatted(.currency(code: "EUR")))
                                .font(.subheadline).bold()
                                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            if tx.id == currentId {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent).font(.caption)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher une transaction…")
            .onAppear { transactions = txRepo.fetchAllTransactions() }
            .paneChrome("Choisir une transaction", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}

// MARK: - Add Tricount Reimbursement Sheet

struct AddTricountReimbursementSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let defaultAmount: Double
    let currency: String
    /// Non-nil = édition d'une ligne existante — préchargée au lieu de repartir
    /// du calcul théorique de part (fix bug v44 AXE R : "Modifier…" dupliquait
    /// silencieusement si l'utilisateur changeait de payee).
    var existingReimbursement: Reimbursement? = nil
    let onAdd: (Int, Double, String) -> Void

    private let txRepo = TransactionRepository()
    @State private var allTiers: [Tiers] = []
    @State private var selectedTiersId: Int = -1
    @State private var amountText: String = ""
    @State private var showTiersPicker = false

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    private var selectedTiersName: String {
        guard selectedTiersId != -1 else { return "Aucun" }
        return allTiers.first(where: { $0.id == selectedTiersId })?.name ?? "Inconnu"
    }

    var body: some View {
            Form {
                Section("Personne qui me doit") {
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(selectedTiersName)
                                .foregroundStyle(selectedTiersId == -1 ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }

                Section("Montant dû") {
                    HStack {
                        Text("Montant (\(currency))")
                        Spacer()
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear {
                if let existing = existingReimbursement {
                    amountText = String(format: "%.2f", abs(existing.amount))
                    selectedTiersId = existing.payeeId
                } else {
                    amountText = String(format: "%.2f", defaultAmount)
                }
                allTiers = txRepo.fetchTiers()
            }
            .sheet(isPresented: $showTiersPicker) {
                TiersSearchSheet(allTiers: allTiers, selectedId: $selectedTiersId)
            }
            .paneChrome(existingReimbursement == nil ? "Nouveau remboursement" : "Modifier le remboursement",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: existingReimbursement == nil ? "Ajouter" : "Enregistrer",
                        confirmDisabled: parsedAmount == nil || selectedTiersId == -1) {
                guard let amount = parsedAmount, selectedTiersId != -1 else { return }
                onAdd(selectedTiersId, amount, currency)
                dismiss()
            }
    }
}
