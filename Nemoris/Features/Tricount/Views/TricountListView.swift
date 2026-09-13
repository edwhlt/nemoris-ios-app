import SwiftUI
import TipKit
struct TricountListView: View {
    @State private var groups: [TricountGroup] = []
    @State private var showLoadSheet = false
    /// macOS ONLY: switches the column's content by state (see
    /// `body`). iOS no longer needs this — see the note on `listContent`.
    @State private var selectedGroup: TricountGroup?
    #if os(macOS)
    /// To close the pane on returning to the list (see `onBack`).
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif
    @State private var refreshingId: Int? = nil
    @State private var refreshError: String? = nil
    /// A skeleton until the 1st `loadGroups()` completes.
    @State private var hasLoaded = false
    private let repo = TricountRepository()
    private let client = TricountAPIClient()
    @Environment(PurchaseManager.self) private var store

    var isEmbedded: Bool = false

    var body: some View {
        Group {
            #if os(macOS)
            // macOS: a tricount's detail replaces the list WITHIN THE COLUMN
            // (internal state-driven navigation, like Investments' account
            // sheet). A tricount is a CONTAINER of entries — each
            // entry has its own detail, which opens in the inspector instead.
            // Rule: a container → full page, a sheet → the inspector.
            if let group = selectedGroup {
                // An explicit pane dismissal on return (see InvestmentsView):
                // it must not outlive the tricount that opened it.
                TricountDetailView(group: group, onBack: {
                    paneCenter?.dismissCurrent()
                    selectedGroup = nil
                })
            } else if isEmbedded {
                listContent
            } else {
                // Not embedded on macOS: an already-covered case since
                // `if let group = selectedGroup` above fires as soon as the
                // selection changes, so `selectedGroup` is never read here
                // — no `.navigationDestination` to attach to it.
                NavigationStack { listContent }
            }
            #else
            // iOS: each row pushes directly via `NavigationLink`
            // (see `listContent`) — no `.navigationDestination` at the
            // container level, whether embedded (the "More" menu) or
            // root (a visible tab). A classic `NavigationLink(destination:)`
            // works at any depth of a NavigationStack
            // as long as it's never MIXED, on the SAME stack, with a
            // value-based `.navigationDestination(for:)/(item:)` — exactly
            // what `MoreView` used to do by nesting this list (itself
            // reached by a classic `NavigationLink` on `MoreView`'s side,
            // see `moreSection`) under a `.navigationDestination(item:)` here:
            // the session's very first push got swallowed and the stack
            // dropped back to "More"'s root. Settings
            // (`SettingsView`, reached the same way from "More") never has this
            // issue because it's classic `NavigationLink` end to end.
            // ⚠️ The SAME anti-pattern existed one level down: each row
            // pushes `TricountDetailView`, which unconditionally wrapped
            // itself in a SECOND `NavigationStack` — see its `body`'s
            // comment for the fix (`\.paneHostContext`).
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
                        // macOS: a state switch (see `body`), never a push.
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
                        // iOS: a real push, a native `List` chevron for free
                        // — the same mechanism as "Settings" in the "More" menu.
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
                // Same policy as Transactions/Patrimoine: .plain = a neutral base
                // for the custom cards drawn by macGroupedRow. iOS keeps its
                // native insetGrouped.
                .listStyle(.plain)
                // Detaches the 1st card from the native macOS separator (toolbar
                // ↔ scrolled content) — the same fix as TransactionsView.
                .macGroupedListTopGap()
                #endif
                .scrollContentBackground(.hidden)
            }
        }
        // The app's background set explicitly — without it, the macOS
        // NavigationSplitView's "content" column shows its vibrant material by
        // default instead of the neutral AppTheme background.
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Tricounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PaneToggleButton(label: "Charger un Tricount", systemImage: "plus", isOn: $showLoadSheet)
            }
        }
        // The detail's presentation (push vs. pane) is decided by `body`,
        // not here: it depends on `isEmbedded`, which `listContent` doesn't
        // need to know for the rest of its content.
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
