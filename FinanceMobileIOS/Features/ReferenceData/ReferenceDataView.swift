import SwiftUI

struct ReferenceDataView: View {
    @Environment(AppState.self) private var appState
    private let repository = TransactionRepository()

    enum ReferenceTab: String, CaseIterable, Identifiable {
        case comptes        = "Comptes"
        case categories     = "Catégories"
        case tiers          = "Tiers"
        case moyensPaiement = "Paiement"
        var id: String { rawValue }
    }

    @State private var selectedTab: ReferenceTab = .comptes
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    @State private var tiers: [Tiers] = []
    @State private var paymentTypes: [PaymentType] = []

    // Recherche
    @State private var searchText = ""

    // Édition / ajout
    @State private var showEditSheet = false
    @State private var editDraftName  = ""
    @State private var editDraftRegex = ""
    @State private var editItemId: Int? = nil   // nil = nouvel élément

    // Console SQL
    @State private var showSQLConsole = false

    // MARK: Filtrage

    var filteredAccounts: [Account] {
        searchText.isEmpty ? accounts
            : accounts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    var filteredCategories: [Category] {
        searchText.isEmpty ? categories
            : categories.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    var filteredTiers: [Tiers] {
        searchText.isEmpty ? tiers
            : tiers.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.regex?.localizedCaseInsensitiveContains(searchText) == true)
            }
    }
    var filteredPaymentTypes: [PaymentType] {
        searchText.isEmpty ? paymentTypes
            : paymentTypes.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.regex?.localizedCaseInsensitiveContains(searchText) == true)
            }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
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
                    switch selectedTab {
                    case .comptes:
                        if filteredAccounts.isEmpty { emptyRow } else {
                            ForEach(filteredAccounts) { a in
                                Text(a.name)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        editButton { startEdit(id: a.id, name: a.name, regex: "") }
                                    }
                            }
                        }
                    case .categories:
                        if filteredCategories.isEmpty { emptyRow } else {
                            ForEach(filteredCategories) { c in
                                Text(c.name)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        editButton { startEdit(id: c.id, name: c.name, regex: "") }
                                    }
                            }
                        }
                    case .tiers:
                        if filteredTiers.isEmpty { emptyRow } else {
                            ForEach(filteredTiers) { t in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(t.name)
                                    if let r = t.regex, !r.isEmpty {
                                        Text(r).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    editButton { startEdit(id: t.id, name: t.name, regex: t.regex ?? "") }
                                }
                            }
                        }
                    case .moyensPaiement:
                        if filteredPaymentTypes.isEmpty { emptyRow } else {
                            ForEach(filteredPaymentTypes) { p in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.name)
                                    if let r = p.regex, !r.isEmpty {
                                        Text(r).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    editButton { startEdit(id: p.id, name: p.name, regex: p.regex ?? "") }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Rechercher…")
            }
            .navigationTitle("Données")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showSQLConsole = true } label: {
                        Image(systemName: "terminal")
                    }
                    Button { startAdd() } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(isPresented: $showSQLConsole) {
                SQLFilesListView()
            }
            .sheet(isPresented: $showEditSheet) {
                editSheet
            }
            .task(id: appState.dataRefreshToken) { loadReferenceData() }
            .refreshable { loadReferenceData() }
        }
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
             ? "Aucune donnée. Importe d'abord un fichier finance.sqlite."
             : "Aucun résultat pour « \(searchText) »")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func editButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Modifier", systemImage: "pencil") }
            .tint(.blue)
    }

    private func startEdit(id: Int, name: String, regex: String) {
        editItemId = id; editDraftName = name; editDraftRegex = regex
        showEditSheet = true
    }

    private func startAdd() {
        editItemId = nil; editDraftName = ""; editDraftRegex = ""
        showEditSheet = true
    }

    private func saveEdit() {
        let name  = editDraftName.trimmingCharacters(in: .whitespaces)
        let regex = editDraftRegex.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch selectedTab {
        case .comptes:
            if let id = editItemId { repository.updateAccount(id: id, name: name) }
            else { repository.addAccount(name: name) }
        case .categories:
            if let id = editItemId { repository.updateCategory(id: id, name: name) }
            else { repository.addCategory(name: name) }
        case .tiers:
            if let id = editItemId { repository.updateTiers(id: id, name: name, regex: regex) }
            else { repository.addTiers(name: name, regex: regex) }
        case .moyensPaiement:
            if let id = editItemId { repository.updatePaymentType(id: id, name: name, regex: regex) }
            else { repository.addPaymentType(name: name, regex: regex) }
        }
        loadReferenceData()
        showEditSheet = false
    }

    private func loadReferenceData() {
        accounts     = repository.fetchAccounts()
        categories   = repository.fetchCategories()
        tiers        = repository.fetchTiers()
        paymentTypes = repository.fetchPaymentTypes()
    }
}
