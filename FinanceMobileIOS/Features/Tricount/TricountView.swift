import SwiftUI
import Security

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
    let type_transaction: String
    let membership_owned: TCMembershipWrapper
    let amount: TCAmount
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
                typeTransaction: e.type_transaction,
                whoPaid: e.membership_owned.RegistryMembershipNonUser.alias.display_name,
                total: (Double(e.amount.value) ?? 0) * -1,
                currency: e.amount.currency ?? currency,
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
    @State private var selectedGroup: TricountGroup?
    @State private var showDetail = false
    private let repo = TricountRepository()

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
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
                                showDetail = true
                            } label: {
                                TricountGroupRow(group: group)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { deleteGroup(group) } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
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
            .navigationDestination(isPresented: $showDetail) {
                if let g = selectedGroup { TricountDetailView(group: g) }
            }
            .sheet(isPresented: $showLoadSheet) {
                TricountLoadSheet { repo.setupTables(); loadGroups() }
            }
            .onAppear { repo.setupTables(); loadGroups() }
        }
    }

    private func loadGroups() { groups = repo.fetchGroups() }
    private func deleteGroup(_ g: TricountGroup) { repo.deleteGroup(id: g.id); loadGroups() }
}

// MARK: - Group Row

private struct TricountGroupRow: View {
    let group: TricountGroup
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline)
                Text("\(group.entryCount) dépenses · \(group.myName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(group.fetchedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(group.currency).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Load Sheet

struct TricountLoadSheet: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum LoadState { case input, loading, selectMember(TricountFetchResult), error(String) }

    @State private var state: LoadState = .input
    @State private var urlInput = ""
    @State private var selectedMember = ""
    private let repo = TricountRepository()
    private let client = TricountAPIClient()

    var body: some View {
        NavigationStack {
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

                case .loading:
                    VStack(spacing: 16) {
                        ProgressView("Chargement…")
                        Text("Authentification RSA en cours").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)

                case .selectMember(let result):
                    Form {
                        Section("Tricount chargé") {
                            LabeledContent("Titre", value: result.title)
                            LabeledContent("Dépenses", value: "\(result.entries.count)")
                            LabeledContent("Devise", value: result.currency)
                        }
                        Section {
                            ForEach(result.members, id: \.self) { member in
                                HStack {
                                    Text(member)
                                    Spacer()
                                    if selectedMember == member {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
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

                case .error(let msg):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(.red)
                        Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Réessayer") { state = .input }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Charger un Tricount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
            }
        }
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
        repo.saveGroup(key: key, title: result.title, currency: result.currency,
                       myName: selectedMember, entries: result.entries)
        onSaved()
        dismiss()
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
    @State private var entries: [TricountEntry] = []
    @State private var shares: [TricountShare] = []
    @State private var selectedTab = 0
    private let repo = TricountRepository()

    private var balances: [TricountMemberBalance] {
        repo.computeBalances(entries: entries, shares: shares, myName: group.myName)
    }

    private var myTotalShare: Double {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        return entries.reduce(0.0) { sum, e in
            sum + (byEntry[e.id]?.first(where: { $0.memberName == group.myName })?.amount ?? 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Picker("", selection: $selectedTab) {
                Text("Balances").tag(0)
                Text("Dépenses").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            if selectedTab == 0 { balancesTab } else { entriesTab }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = repo.fetchEntries(groupId: group.id); shares = repo.fetchShares(groupId: group.id) }
    }

    private var summaryHeader: some View {
        let net = balances.reduce(0) { $0 + $1.net }
        return HStack(spacing: 0) {
            summaryCell(label: "Dépenses", value: "\(entries.count)")
            Divider().frame(height: 40)
            summaryCell(label: "Ma part", value: myTotalShare.formatted(.currency(code: group.currency)))
            Divider().frame(height: 40)
            summaryCell(label: net >= 0 ? "On me doit" : "Je dois",
                        value: abs(net).formatted(.currency(code: group.currency)),
                        color: net >= 0 ? .green : .orange)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    private func summaryCell(label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var balancesTab: some View {
        List {
            if balances.isEmpty {
                ContentUnavailableView("Aucune balance", systemImage: "equal.circle")
            } else {
                ForEach(balances) { b in
                    HStack {
                        Text(b.memberName)
                        Spacer()
                        if b.net > 0.005 {
                            Text("me doit \(b.net.formatted(.currency(code: group.currency)))")
                                .font(.subheadline).foregroundStyle(.green)
                        } else if b.net < -0.005 {
                            Text("je dois \(abs(b.net).formatted(.currency(code: group.currency)))")
                                .font(.subheadline).foregroundStyle(.orange)
                        } else {
                            Text("équilibré").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }.listStyle(.plain)
    }

    private var entriesTab: some View {
        let byEntry = Dictionary(grouping: shares, by: { $0.entryId })
        return List {
            ForEach(entries) { entry in
                TricountEntryRow(
                    entry: entry,
                    myShare: byEntry[entry.id]?.first(where: { $0.memberName == group.myName })?.amount,
                    myName: group.myName,
                    currency: group.currency
                )
            }
        }.listStyle(.plain)
    }
}

// MARK: - Entry Row

private struct TricountEntryRow: View {
    let entry: TricountEntry
    let myShare: Double?
    let myName: String
    let currency: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: categoryIcon(entry.category))
                .font(.title3).foregroundStyle(.secondary).frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description.isEmpty
                     ? entry.category.lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                     : entry.description)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(entry.whoPaid == myName ? "Moi" : entry.whoPaid)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.total.formatted(.currency(code: currency)))
                    .font(.subheadline).bold()
                if let share = myShare, share > 0.005 {
                    Text("Ma part : \(share.formatted(.currency(code: currency)))")
                        .font(.caption2).foregroundStyle(.blue)
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
        default: return "creditcard"
        }
    }
}
