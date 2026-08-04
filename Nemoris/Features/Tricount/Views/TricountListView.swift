import SwiftUI
import TipKit
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
