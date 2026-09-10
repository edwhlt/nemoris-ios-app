import SwiftUI
import TipKit
struct TricountListView: View {
    @State private var groups: [TricountGroup] = []
    @State private var showLoadSheet = false
    /// macOS UNIQUEMENT : bascule le contenu de la colonne par état (cf.
    /// `body`). iOS n'en a plus besoin — cf. note sur `listContent`.
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
                // Non-embarqué sur macOS : cas déjà couvert par
                // `if let group = selectedGroup` ci-dessus dès que la
                // sélection change, `selectedGroup` n'est donc jamais lu ici
                // — pas de `.navigationDestination` à y attacher.
                NavigationStack { listContent }
            }
            #else
            // iOS : chaque row pousse directement via `NavigationLink`
            // (cf. `listContent`) — aucun `.navigationDestination` au niveau
            // du conteneur, qu'il soit embarqué (menu "Plus") ou racine
            // (onglet visible). Un `NavigationLink(destination:)` classique
            // fonctionne à n'importe quelle profondeur d'une NavigationStack
            // tant qu'il n'est jamais MÉLANGÉ, sur la MÊME pile, avec un
            // `.navigationDestination(for:)/(item:)` value-based — exactement
            // ce que faisait `MoreView` en emboîtant cette liste (elle-même
            // atteinte par un `NavigationLink` classique côté `MoreView`,
            // cf. `moreSection`) sous un `.navigationDestination(item:)` ici :
            // le tout premier push de la session était avalé et la pile
            // retombait jusqu'à la racine de "Plus" (retour d'usage). Réglages
            // (`SettingsView`, atteint pareil depuis "Plus") n'a jamais ce
            // souci car il est du `NavigationLink` classique de bout en bout.
            // ⚠️ Le MÊME anti-pattern existait un niveau plus bas : chaque row
            // pousse `TricountDetailView`, qui s'enveloppait elle-même
            // inconditionnellement dans une SECONDE `NavigationStack` — cf. son
            // commentaire de `body` pour le correctif (`\.paneHostContext`).
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
                .scrollContentBackground(.hidden)
            } else if groups.isEmpty {
                EmptyStateView(
                    icon: "person.2",
                    title: "Aucun Tricount",
                    message: "Appuyez sur + pour charger un Tricount"
                )
            } else {
                List {
                    ForEach(groups) { group in
                        #if os(macOS)
                        // macOS : bascule d'état (cf. `body`), jamais de push.
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
                        .macGroupedRow(first: group.id == groups.first?.id, last: group.id == groups.last?.id)
                        #else
                        // iOS : vrai push, chevron natif de la `List` gratuit
                        // — même mécanisme que "Réglages" dans le menu "Plus".
                        NavigationLink {
                            TricountDetailView(group: group)
                        } label: {
                            TricountGroupRow(group: group, isRefreshing: refreshingId == group.id)
                        }
                        .rowActions(
                            leading: [RowAction("Mettre à jour", systemImage: "arrow.clockwise", tint: AppTheme.Colors.accent) { refreshGroup(group) }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { deleteGroup(group) }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                        .macGroupedRow(first: group.id == groups.first?.id, last: group.id == groups.last?.id)
                        #endif
                    }
                }
                #if os(macOS)
                // Même politique que Transactions/Patrimoine : .plain = base neutre
                // pour les cartes custom dessinées par macGroupedRow. iOS garde son
                // insetGrouped natif.
                .listStyle(.plain)
                // Décolle la 1ère carte du délimiteur natif macOS (barre d'outils
                // ↔ contenu scrollé) — même correctif que TransactionsView.
                .macGroupedListTopGap()
                #endif
                .scrollContentBackground(.hidden)
            }
        }
        // Fond de l'app posé explicitement — sans lui la colonne « content » de
        // la NavigationSplitView macOS montre son matériau vibrant par défaut
        // au lieu du fond neutre AppTheme ().
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Tricounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PaneToggleButton(label: "Charger un Tricount", systemImage: "plus", isOn: $showLoadSheet)
            }
        }
        // La présentation du détail (push vs pane) est décidée par `body`,
        // pas ici : elle dépend de `isEmbedded`, que `listContent` n'a pas
        // besoin de connaître pour le reste de son contenu.
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
