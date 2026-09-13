import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Identifiable wrapper to present the pre-filled V3 import via
/// `.sheet(item:)` (a CSV dropped by a Siri shortcut or the share extension).
/// Mirrors `PreloadedInvestmentImport` on the Investments side.
struct PreloadedTransactionImport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// An import-tool opening requested by a module.
struct RequestedImport: Identifiable {
    let id = UUID()
    let destination: ImportDestination
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showCancelImportConfirm = false
    /// Background document analysis: the user stays in control
    /// while it works, the banner serving as the return point.
    private var importCoordinator: DocumentImportCoordinator { .shared }
    @State private var showAnalysisReview = false
    @State private var showInvestmentReview = false
    @State private var showCancelAnalysisConfirm = false
    /// A V3 import pre-filled by a shared/shortcut CSV.
    @State private var preloadedTransactionImport: PreloadedTransactionImport?
    /// iPhone: the import tool requested by a module, presented as a sheet
    /// for lack of a sidebar to send it to.
    @State private var requestedImport: RequestedImport?
    /// Desktop: the destination captured for `sidebarImportTag` (see
    /// `.onChange(of: appState.importToolRequest)`) — `detailView(for:)`
    /// can't re-read `appState.importToolRequest` directly, it's already
    /// reset to `nil` by the same handler before the next render.
    @State private var sidebarImportDestination: ImportDestination = .transactions
    #if os(macOS)
    /// The desktop global inspector's single slot: level-1 `.adaptivePane`s
    /// route their content here (see `AdaptivePane.swift`'s docs).
    @State private var paneCenter = InspectorPaneCenter()
    /// Global search — a button placed next to the sidebar toggle (see
    /// `sidebarList`). On iOS, the equivalent lives in the Dashboard toolbar;
    /// macOS has no "always visible" Dashboard the same way (the user
    /// can be on any module), so the entry lives at the root.
    @State private var showGlobalSearch = false
    #endif
    private let moreTag = "more"
    /// "Tools" entries specific to the sidebar (not MainTabItems).
    /// A single source in AppState (reused by the Dashboard gear on Mac).
    private let sidebarImportTag = AppState.sidebarImportTag
    private let sidebarSettingsTag = AppState.sidebarSettingsTag

    /// Desktop layout: a sidebar on Mac and landscape iPad, where an
    /// iPhone tab bar looks out of place in a large window. iPhone (and compact/
    /// narrow Split View iPad) keeps the TabView.
    private var useSidebar: Bool {
        #if os(macOS)
        return true   // A native Mac = always the sidebar
        #else
        return UIDevice.current.userInterfaceIdiom == .pad && hSizeClass == .regular
        #endif
    }

    var body: some View {
        @Bindable var state = appState
        // Banner position: AT THE TOP on iOS (an "ongoing call" style, below
        // the notch and away from the tab bar), AT THE BOTTOM on macOS — a
        // persistent status bar is a desktop convention there (a window status
        // bar), whereas at the top it competes with the title bar and
        // the module's toolbar.
        return VStack(spacing: 0) {
            #if !os(macOS)
            importBanner(edge: .top)
            #endif

            if useSidebar {
                sidebarLayout
            } else {
                tabLayout
            }

            #if os(macOS)
            importBanner(edge: .bottom)
            #endif
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState.activeImportSession?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: importCoordinator.phase)
        .appToast($state.currentToast)
        .adaptivePane(isPresented: $state.showImportSessionSheet) {
            if let summary = appState.activeImportSession {
                // ⚠️ The review depends on the DESTINATION: a transactions
                // session opens row-by-row resolution (payees,
                // categories), an investments session opens
                // attaching orders to a brokerage account. The two answer
                // different questions and stay distinct.
                switch summary.destination {
                case .transactions:
                    NavigationStack {
                        ImportSessionView(sessionId: summary.id)
                    }
                case .investments:
                    InvestmentPDFImportView(
                        preparsedBatch: importCoordinator.batch,
                        accountId: summary.accountId ?? importCoordinator.accountId,
                        onFinished: {
                            state.showImportSessionSheet = false
                            appState.activeImportSession = nil
                            importCoordinator.clear()
                        }
                    )
                    // Reloading from the database, when the app has restarted,
                    // is done by `AppState.reloadActiveImportSession` — so
                    // BEFORE this construction, otherwise the review's `@State`
                    // would already be frozen on an empty result.
                    .id(summary.id)
                }
            }
        }
        // A CSV dropped by the "Import transactions (CSV)" shortcut
        // or the Transactions share extension: a pre-filled V3 import. If a
        // session is already active, ImportEntryView shows the resume alert.
        .adaptivePane(item: $preloadedTransactionImport) { item in
            ImportEntryView(preloadedFileURLs: item.urls)
        }
        // Reviewing the result of a background analysis.
        .adaptivePane(isPresented: $showAnalysisReview) {
            TransactionDocumentReviewView(
                coordinator: importCoordinator,
                onConfirm: { summary in
                    importCoordinator.clear()
                    appState.activeImportSession = summary
                    // Handing off to the full review with no flicker
                    // (see `ImportEntryView.handOver`).
                    ImportEntryView.handOver(to: appState,
                                               dismissSelf: { showAnalysisReview = false })
                },
                onCancel: {
                    showAnalysisReview = false
                    importCoordinator.clear()
                }
            )
        }
        .adaptivePane(isPresented: $showInvestmentReview) {
            InvestmentPDFImportView(
                preparsedBatch: importCoordinator.batch,
                accountId: importCoordinator.accountId,
                onFinished: {
                    showInvestmentReview = false
                    importCoordinator.clear()
                }
            )
        }
        .onChange(of: appState.pendingTransactionImportURLs) { _, urls in
            consumePendingTransactionImport(urls)
        }
        // A module requested the import tool: it's the ROOT
        // navigation that decides where to show it, not the module.
        .onChange(of: appState.importToolRequest) { _, request in
            guard let request else { return }
            if useSidebar {
                // Desktop: a full destination, not a side pane
                // stuck to the module just left. The
                // destination is captured in a DEDICATED `@State` (not re-read
                // from `appState.importToolRequest` by `detailView(for:)`)
                // — this handler's two mutations are coalesced in the
                // SAME render cycle by SwiftUI, so `detailView` would
                // never see the value before it's reset to `nil`
                // three lines below.
                sidebarImportDestination = request
                state.selectedTab = sidebarImportTag
            } else {
                requestedImport = RequestedImport(destination: request)
            }
            // The request is consumed: it served to pick the destination,
            // leaving it would reopen import on the next tab change.
            appState.importToolRequest = nil
        }
        .adaptivePane(item: $requestedImport) { item in
            ImportEntryView(initialDestination: item.destination)
        }
        .confirmationDialog(
            "Annuler la session d'import ?",
            isPresented: $showCancelImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Annuler la session", role: .destructive) {
                if let id = appState.activeImportSession?.id {
                    ImportSessionRepository().deleteSession(id: id)
                    ImportNotificationService.cancelReminder(forSessionId: id)
                    appState.activeImportSession = nil
                    // ⚠️ ALSO close the pane: without this the macOS inspector
                    // stayed open on a deleted session — the user
                    // saw an import "still in progress" that no longer existed.
                    appState.showImportSessionSheet = false
                }
            }
            Button("Continuer l'import", role: .cancel) {}
        } message: {
            Text("Les lignes non encore importées seront perdues.")
        }
        .confirmationDialog(
            importCoordinator.isReady ? "Abandonner ce résultat d'analyse ?"
                                      : "Interrompre l'analyse en cours ?",
            isPresented: $showCancelAnalysisConfirm,
            titleVisibility: .visible
        ) {
            Button(importCoordinator.isReady ? "Abandonner le résultat" : "Interrompre l'analyse",
                   role: .destructive) {
                importCoordinator.cancel()
                // ⚠️ ALSO close any open review: otherwise
                // the macOS inspector stayed showing a result that
                // no longer exists (the same bug class as the canceled session).
                showAnalysisReview = false
                showInvestmentReview = false
            }
            Button("Poursuivre", role: .cancel) {}
        } message: {
            // ⚠️ The message claimed "the analyzed document isn't
            // kept: it'll need to be re-selected" — become FALSE for
            // investments since the analysis is persisted in a session
            // (migration v45). It stays true during the analysis, where nothing
            // is written to the database yet.
            Text(importCoordinator.isReady
                 ? "Les opérations reconnues seront perdues : il faudra relancer l'analyse du document."
                 : "Le document en cours d'analyse ne sera pas conservé : il faudra le re-sélectionner.")
        }
        .onAppear {
            ensureValidSelection()
            appState.reloadActiveImportSession()
            consumePendingTransactionImport(appState.pendingTransactionImportURLs)
        }
        .onChange(of: appState.mainTabOrder)    { _, _ in ensureValidSelection() }
        .onChange(of: appState.showTricount)    { _, _ in ensureValidSelection() }
        .onChange(of: appState.showInvestments) { _, _ in ensureValidSelection() }
        .onChange(of: appState.showBudget)      { _, _ in ensureValidSelection() }
        .onChange(of: appState.showPatrimoine)  { _, _ in ensureValidSelection() }
        .onChange(of: appState.showSQLConsole)  { _, _ in ensureValidSelection() }
        // Switches tab bar ↔ sidebar (iPad rotation, Mac window resize) + catches
        // navigateToTab(...) → "more" when the sidebar has no More tab.
        .onChange(of: hSizeClass) { _, _ in ensureValidSelection() }
        .onChange(of: appState.selectedTab) { _, _ in
            if useSidebar { ensureValidSelection() }
            #if os(macOS)
            // The inspector is contextual to the displayed module → a module
            // change means closing it (resetting the call site's binding included).
            paneCenter.dismissCurrent()
            #endif
        }
        #if os(macOS)
        .environment(paneCenter)
        .adaptivePane(isPresented: $showGlobalSearch) {
            SearchView()
        }
        #endif
    }

    /// An "import in progress" banner, sliding in from the edge it's anchored to.
    ///
    /// Two possible states, never both at once: an ongoing document analysis
    /// (or one ready to be reviewed), otherwise an open import session.
    @ViewBuilder
    private func importBanner(edge: Edge) -> some View {
        if importCoordinator.isActive {
            ImportAnalysisBanner(
                coordinator: importCoordinator,
                onOpen: { openAnalysisReview() },
                // A confirmation like an import session's: the analysis
                // result is NOT persisted, abandoning it loses it for good.
                onCancel: { showCancelAnalysisConfirm = true }
            )
            .transition(.move(edge: edge).combined(with: .opacity))
        } else if let summary = appState.activeImportSession {
            ImportSessionBanner(
                summary: summary,
                onTap: { appState.showImportSessionSheet = true },
                onCancel: { showCancelImportConfirm = true }
            )
            .transition(.move(edge: edge).combined(with: .opacity))
        }
    }

    /// Opens the analysis result's review, based on the chosen destination.
    private func openAnalysisReview() {
        switch importCoordinator.destination {
        case .transactions:
            showAnalysisReview = true
        case .investments:
            showInvestmentReview = true
        }
    }

    /// Presents the pre-filled V3 import and releases the pending URLs
    /// (one-shot). A no-op if empty or if a preloaded sheet is already in progress.
    /// Mirrors `consumePendingInvestmentImport` in InvestmentsView.
    private func consumePendingTransactionImport(_ urls: [URL]) {
        guard !urls.isEmpty, preloadedTransactionImport == nil else { return }
        preloadedTransactionImport = PreloadedTransactionImport(urls: urls)
        appState.pendingTransactionImportURLs = []
    }

    // MARK: - Layouts

    /// Layout iPhone : TabView 4 onglets + Plus (comportement historique).
    private var tabLayout: some View {
        @Bindable var state = appState
        return TabView(selection: $state.selectedTab) {
            ForEach(visibleTabs) { tab in
                tabView(for: tab)
                    .tabItem {
                        // If total slots (visible + More) > 4 → icon only,
                        // otherwise a label + icon as before. The iOS tab bar
                        // automatically handles centering icon-only tabs.
                        if iconOnlyMode {
                            Image(systemName: tab.systemImage)
                        } else {
                            Label(LocalizedStringKey(tab.title), systemImage: tab.systemImage)
                        }
                    }
                    .tag(tab.rawValue)
            }

            MoreView(orderedHiddenTabs: hiddenTabs)
                .tabItem {
                    if iconOnlyMode {
                        Image(systemName: "ellipsis.circle")
                    } else {
                        Label("Plus", systemImage: "ellipsis.circle")
                    }
                }
                .tag(moreTag)
        }
        // Without this .id, UIKit reuses the UITabBarItems of tabs whose
        // position hasn't changed when iconOnlyMode toggles (e.g. 4→5 active
        // modules) → some keep their text label, others don't (an
        // inconsistent render). Forcing a full TabView remount avoids this partial diff.
        .id(iconOnlyMode)
        .tint(AppTheme.Colors.accent)
    }

    /// Desktop layout: a sidebar with EVERY module (no cap
    /// at 4, no More tab) + a Tools section. Each module keeps its own
    /// NavigationStack in its column.
    ///
    /// ⚠️ The split view must stay the ROOT view. A V1 wrapped it in an
    /// HStack (`HStack { NavigationSplitView; pane }`) → the split view, which
    /// wants to be the root, negotiated its width in a LOOP with the HStack → the
    /// window bar (and pushed views' back button, e.g. Tricount) vibrated
    /// constantly. The pane is therefore a COLUMN of the split view, never a
    /// sibling placed next to it.
    private var sidebarLayout: some View {
        sidebarSplitView
    }

    /// ⚠️ `.id(selection)` on the module's column is REQUIRED: without it,
    /// `NavigationSplitView` on macOS does NOT destroy the previous module's
    /// internal navigation state (a push) when the selection changes — the
    /// pushed content (a Tricount detail, an Investments account/position
    /// detail…) stays on screen, and only a pop (back button) finally forces
    /// a re-render toward the new module. `.id()` forces a view identity tied
    /// to the tab: on change, SwiftUI unmounts the whole old sub-tree
    /// (so its internal `NavigationStack`/push) instead of trying to reuse it.
    ///
    /// ⚠️ This identity does NOT depend on the language, and must not become
    /// one. An intermediate version added `preferredLanguage` to it to force
    /// `.navigationTitle` refreshes on a language change —
    /// a bad fix: it destroyed the whole module's state (internal navigation,
    /// scroll, current tab) on every switch, when the real cause was
    /// elsewhere. `.localizedNavigationTitle` (see `AppLocalization`) resolves
    /// the language against the right bundle AND refreshes itself via
    /// `@Environment(\.locale)`, with nothing to rebuild.
    #if os(macOS)
    /// macOS — **three columns**: sidebar · module · pane.
    ///
    /// The pane is a REAL `NavigationSplitView` column, not an
    /// `.inspector` nor a custom `HStack`, because it's the only construction
    /// that reproduces system apps' behavior (Mail, Notes):
    ///
    /// 1. **A draggable separator** — the user picks the pane's width,
    ///    AppKit remembers it. The old `HStack` fixed it at 440pt.
    /// 2. **A split toolbar** — each column declares its own
    ///    `.toolbar`, and macOS inserts a tracking separator between them
    ///    (`NSTrackingSeparatorToolbarItem`) aligned with the column
    ///    separator. The module's actions therefore stop at the separator, the
    ///    pane's start after it: each group's ownership reads
    ///    without a label.
    ///
    /// > Measured: neither the custom `HStack` nor `.inspector` achieve point 2.
    /// > With them, every button piles up at the window's right edge,
    /// > so above the pane — the module's included. A
    /// > `ToolbarSpacer(.flexible)` changes nothing there (tested at both placements):
    /// > the separator comes from the column STRUCTURE, not the bar.
    ///
    /// ⚠️ Width distribution — the module's `ideal` is a COMPROMISE, not
    /// an aesthetic preference. In a 3-column split view, it's the
    /// `detail` column that absorbs the free space, and the pane is resized
    /// by dragging the MODULE column's edge. Both extremes are
    /// therefore bad, and were measured:
    ///
    /// - A very wide module `ideal` (tried at 1,200): the module wants all the
    ///   room, the module|pane separator becomes **impossible to drag** (the
    ///   sidebar|module separator, on the other hand, still responds — that's what
    ///   made isolating the cause possible) and the pane stays stuck at its `min`.
    /// - No constraint on the module: the pane goes to its `max` and
    ///   widens with the window, when it's the module's list that needs
    ///   the room.
    ///
    /// Values kept: the module has a moderate `ideal` (enough to stay
    /// dominant, flexible enough for the separator to move) and the pane a
    /// `max` that keeps it from eating the window.
    private var sidebarSplitView: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            sidebarList
                .localizedNavigationTitle("Nemoris")
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } content: {
            detailView(for: state.selectedTab)
                .id(state.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760, max: 1_400)
        } detail: {
            inspectorColumn
        }
        .tint(AppTheme.Colors.accent)
    }

    /// The pane's column. With no pane open it COLLAPSES to zero (verified: the
    /// module column then reclaims the whole width) — a module like the
    /// Dashboard therefore loses no room, unlike a mail client's permanent
    /// third pane.
    ///
    /// ⚠️ Only this column's BRANCH changes when a pane opens; the
    /// module's column keeps the same view identity. This is what
    /// preserves its `@State` (an earlier version switched between
    /// `detailView` alone and `HStack { detailView; pane }`: SwiftUI saw
    /// two different structures there, DESTROYING the module's view when the
    /// pane opened and recreating it — the "Data" module's current tab fell
    /// back to Accounts, filters emptied out…).
    ///
    /// The pane receives NO chrome from here: its content declares its own
    /// `.toolbar` (see `publishesInspectorChrome`), so the actions are always
    /// the current render's — never stale closures.
    @ViewBuilder
    private var inspectorColumn: some View {
        if let pane = paneCenter.pane {
            // `.id(pane.id)`: a re-presented pane starts with a fresh @State
            // → clicking another piece of data changes the detail without going
            // through "Close".
            pane.content
                .id(pane.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Colors.background)
                .navigationSplitViewColumnWidth(
                    min: InspectorPaneMetrics.minWidth,
                    ideal: InspectorPaneMetrics.idealWidth,
                    max: InspectorPaneMetrics.maxWidth
                )
        } else {
            Color.clear
                .frame(width: 0)
                .navigationSplitViewColumnWidth(0)
        }
    }
    #else
    /// iOS / iPadOS — two columns, the historical behavior: panes there are
    /// `.sheet`s (see `adaptivePane`), so there's no third column
    /// to plan for.
    private var sidebarSplitView: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            sidebarList
                .localizedNavigationTitle("Nemoris")
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailView(for: state.selectedTab)
                .id(state.selectedTab)
        }
        .tint(AppTheme.Colors.accent)
    }
    #endif

    @ViewBuilder
    private var sidebarList: some View {
        @Bindable var state = appState
        #if os(macOS)
        // Selection driven MANUALLY: macOS's `.sidebar` List draws its
        // selection highlight with the SYSTEM accent color (blue),
        // not recolorable via `.tint` (the same limitation as icons). The
        // `selection:` binding is therefore dropped and a custom ADN dot is painted
        // via `.listRowBackground` (see sidebarRow). An accepted tradeoff: no more
        // ↑/↓ keyboard navigation between modules (sidebar = click).
        List {
            Section("Modules") {
                ForEach(availableTabs) { tab in
                    sidebarRow(title: LocalizedStringKey(tab.title), systemImage: tab.systemImage, tag: tab.rawValue)
                }
            }
            // ⚠️ Settings is NOT a tool: it's the app's configuration,
            // not an action performed on its data. Filing it with
            // import put "I'm processing a statement" and
            // "I'm changing my preferences" on the same footing.
            Section("Outils") {
                sidebarRow(title: "Importation", systemImage: "square.and.arrow.down", tag: sidebarImportTag)
            }
            Section {
                sidebarRow(title: "Réglages", systemImage: "gearshape", tag: sidebarSettingsTag)
            }
        }
        .listStyle(.sidebar)
        // `.navigation` placement = the toolbar segment where macOS already paints
        // the sidebar toggle button (auto-generated by `NavigationSplitView`) —
        // this is what places the magnifying glass right next to it rather than lost in
        // the displayed module's toolbar.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PaneToggleButton(label: "Rechercher", systemImage: "magnifyingglass", isOn: $showGlobalSearch)
            }
        }
        #else
        // iOS / iPad: native selection (the highlight follows `.tint` here).
        List(selection: Binding<String?>(
            get: { state.selectedTab },
            set: { if let value = $0 { state.selectedTab = value } }
        )) {
            Section("Modules") {
                ForEach(availableTabs) { tab in
                    sidebarLabel(LocalizedStringKey(tab.title), systemImage: tab.systemImage)
                        .tag(tab.rawValue)
                }
            }
            Section("Outils") {
                sidebarLabel("Importation", systemImage: "square.and.arrow.down")
                    .tag(sidebarImportTag)
            }
            // Its own section: see the macOS branch's comment.
            Section {
                sidebarLabel("Réglages", systemImage: "gearshape")
                    .tag(sidebarSettingsTag)
            }
        }
        .listStyle(.sidebar)
        #endif
    }

    #if os(macOS)
    /// A macOS sidebar row with custom selection. Reproduces macOS's NEUTRAL
    /// highlight (Mail-style: translucent gray) rather than the system's blue
    /// accent highlight — not recolorable via `.tint`. The icon stays green (ADN),
    /// the label goes semibold when selected (Mail-style emphasis).
    ///
    /// Selection on a `Button` (not `onTapGesture`): immediate hit-testing and
    /// click feedback — `onTapGesture` on a List row felt
    /// "mushy". Stays custom (no ↑/↓ keyboard nav, the price of the non-blue color).
    ///
    /// ⚠️ The background dot is a `.background` set ON the button's content,
    /// not a `.listRowBackground` — `.listRowBackground` fills the row's whole
    /// width (up to the sidebar's edges), which gave a full-width highlight
    /// instead of the Mail-style margined pill. `.listRowInsets`
    /// shrinks the row itself (horizontal margin + a small vertical gap between
    /// rows) so the dot never touches the sidebar's edges.
    @ViewBuilder
    private func sidebarRow(title: LocalizedStringKey, systemImage: String, tag: String) -> some View {
        let isSelected = appState.selectedTab == tag
        Button {
            appState.selectedTab = tag
        } label: {
            Label {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }
    #endif

    /// On macOS, a `Label` in a `.listStyle(.sidebar)` `List` tints its
    /// icon with `controlAccentColor` (the system's "Accent color" setting),
    /// not with SwiftUI's `.tint()`/`accentColor` environment — hence the blue
    /// icons despite the `.tint(AppTheme.Colors.accent)` set above. Only an
    /// explicit `.foregroundStyle` on the icon (native, no AppKit hack) can
    /// force the ADN color here.
    private func sidebarLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.Colors.accent)
        }
    }

    @ViewBuilder
    private func detailView(for selection: String) -> some View {
        if selection == sidebarSettingsTag {
            NavigationStack { SettingsView(isEmbedded: true) }
        } else if selection == sidebarImportTag {
            NavigationStack {
                ImportEntryView(initialDestination: sidebarImportDestination,
                                  isEmbedded: true)
            }
        } else if let tab = MainTabItem(rawValue: selection) {
            tabView(for: tab)
        } else {
            // A transient invalid selection ("more" during the switch) —
            // ensureValidSelection fixes it right after.
            tabView(for: .dashboard)
        }
    }

    // ⚠️ Delegates to `AppState.availableTabsResolved` — do NOT duplicate the
    // switch here. A local copy existed before and was never updated
    // when `.transactions`/`.referenceData` joined the filter
    // (it fell back to `return true`, so the Transactions toggle in
    // Settings had strictly no effect). One filter, one place —
    // the same doctrine as the budget envelope calculations.
    private var availableTabs: [MainTabItem] { appState.availableTabsResolved }

    /// Max 4 visible tabs before the "More" button (the iOS tab bar tolerates 5 slots
    /// total = 4 visible + More). Icon-only mode kicks in as soon as there are more than
    /// 4 slots, so from 4 visible + More (= 5) onward.
    private var visibleTabs: [MainTabItem] { Array(availableTabs.prefix(4)) }
    private var hiddenTabs: [MainTabItem]  { Array(availableTabs.dropFirst(4)) }

    /// True if total slots in the tab bar > 4 → hide labels (icon only)
    /// to avoid crowding. visibleTabs.count + 1 (the More slot is always present).
    private var iconOnlyMode: Bool {
        visibleTabs.count + 1 > 4
    }

    private func ensureValidSelection() {
        if useSidebar {
            // No "More" tab in the sidebar: a cross-tab navigation that
            // targeted a hidden tab there (navigateToTab → "more" + pending) is
            // redirected straight to the target tab.
            if appState.selectedTab == moreTag {
                appState.selectedTab = appState.pendingMoreDestination?.rawValue
                    ?? availableTabs.first?.rawValue
                    ?? MainTabItem.dashboard.rawValue
                appState.pendingMoreDestination = nil
                return
            }
            let allowed = Set(availableTabs.map(\.rawValue) + [sidebarImportTag, sidebarSettingsTag])
            if !allowed.contains(appState.selectedTab) {
                appState.selectedTab = availableTabs.first?.rawValue ?? MainTabItem.dashboard.rawValue
            }
        } else {
            let allowed = Set(visibleTabs.map(\.rawValue) + [moreTag])
            if !allowed.contains(appState.selectedTab) {
                appState.selectedTab = visibleTabs.first?.rawValue ?? moreTag
            }
        }
    }

    @ViewBuilder
    private func tabView(for tab: MainTabItem) -> some View {
        switch tab {
        case .dashboard:    DashboardView()
        case .transactions: TransactionsView()
        case .investments:  InvestmentsView()
        case .patrimoine:   PatrimoineView()
        case .tricount:     TricountListView()
        case .budget:       BudgetView()
        case .referenceData: ReferenceDataView()
        case .sqlConsole:   NavigationStack { SQLFilesListView() }
        }
    }
}

// MARK: - MoreView

private struct MoreView: View {
    @Environment(AppState.self) private var appState
    let orderedHiddenTabs: [MainTabItem]
    @State private var searchText = ""
    /// A controlled navigation path. Used to programmatically push when the user
    /// arrives here via `appState.pendingMoreDestination` (e.g. the Patrimoine
    /// banner on the Dashboard).
    @State private var navPath: [MainTabItem] = []

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.lg) {
                        if searchText.isEmpty {
                            if !orderedHiddenTabs.isEmpty {
                                moreSection(
                                    title: "Onglets",
                                    items: orderedHiddenTabs.map { tab in
                                        MoreItem(
                                            label: LocalizedStringKey(tab.title),
                                            icon: tab.systemImage,
                                            color: AppTheme.Colors.accent,
                                            destination: { AnyView(destinationView(for: tab)) }
                                        )
                                    }
                                )
                            }
                            moreSection(
                                title: "Outils",
                                items: toolItems
                            )
                        } else {
                            featureSearchResults
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.sm)
                    .padding(.bottom, AppTheme.Spacing.xxxl)
                }
            }
            .localizedNavigationTitle("Plus")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Rechercher une fonctionnalité…")
            // A programmatic destination: consumed by MoreView when another
            // View pushes `appState.pendingMoreDestination` (e.g. tapping
            // the Dashboard's Patrimoine banner while Patrimoine is among
            // the hidden tabs).
            .navigationDestination(for: MainTabItem.self) { tab in
                destinationView(for: tab)
            }
            .onChange(of: appState.pendingMoreDestination) { _, newValue in
                guard let tab = newValue else { return }
                // The path is reset before pushing, so it doesn't stack if the
                // destination was already open (the user navigates there twice).
                navPath = [tab]
                // Consumed → cleared so it isn't re-pushed on every rebuild.
                appState.pendingMoreDestination = nil
            }
            .onAppear {
                // The case where the user reaches MoreView with a destination already
                // pending (a helper called before MoreView is instantiated).
                if let pending = appState.pendingMoreDestination {
                    navPath = [pending]
                    appState.pendingMoreDestination = nil
                }
            }
        }
    }

    // MARK: - Tool items

    private var toolItems: [MoreItem] {
        var items = [
            MoreItem(
                label: "Importation",
                icon: "square.and.arrow.down",
                color: AppTheme.Colors.success,
                destination: { AnyView(ImportEntryView(isEmbedded: true)) }
            ),
            MoreItem(
                label: "Paramètres",
                icon: "gearshape",
                color: AppTheme.Colors.textSecondary,
                destination: { AnyView(SettingsView(isEmbedded: true)) }
            )
        ]
        #if DEBUG
        items.insert(
            MoreItem(
                label: "Rapport fiscal Binance",
                icon: "doc.text.magnifyingglass",
                color: AppTheme.Colors.warning,
                destination: { AnyView(BinanceTaxView()) }
            ),
            at: 1
        )
        #endif
        return items
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func moreSection(title: LocalizedStringKey, items: [MoreItem]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .textCase(.uppercase)
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    NavigationLink(destination: item.destination()) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(item.color.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: item.icon)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(item.color)
                            }
                            Text(item.label)
                                .font(AppTheme.Typography.bodyMedium)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .background(AppTheme.Colors.surface)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Colors.surfaceSecondary)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .softShadow()
        }
    }

    @ViewBuilder
    private func destinationView(for tab: MainTabItem) -> some View {
        switch tab {
        case .dashboard:    DashboardView(isEmbedded: true)
        case .transactions: TransactionsView(isEmbedded: true)
        case .investments:  InvestmentsView(isEmbedded: true)
        case .patrimoine:   PatrimoineView(isEmbedded: true)
        case .tricount:     TricountListView(isEmbedded: true)
        case .budget:       BudgetView(isEmbedded: true)
        case .referenceData: ReferenceDataView(isEmbedded: true)
        case .sqlConsole:   SQLFilesListView()  // already pushed via NavigationLink (the parent NavigationStack)
        }
    }

    // MARK: - Feature Search
    //
    // A catalog shared with `SearchView` — see `FeatureCatalog.swift`.

    private func filteredFeatures() -> [FeatureEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return FeatureCatalog.entries(for: appState) }
        return FeatureCatalog.matching(q, in: appState)
    }

    @ViewBuilder private var featureSearchResults: some View {
        let results = filteredFeatures()
        if results.isEmpty {
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Aucun résultat")
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Essayez un autre mot-clé.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                    featureResultRow(entry)
                    if index < results.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Colors.surfaceSecondary)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .softShadow()
        }
    }

    @ViewBuilder private func featureResultRow(_ entry: FeatureEntry) -> some View {
        switch entry.target {
        case .tab(let tab):
            Button {
                appState.selectedTab = tab.rawValue
                searchText = ""
            } label: {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        case .importCSV:
            NavigationLink(destination: ImportEntryView(isEmbedded: true)) {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        case .settings:
            NavigationLink(destination: SettingsView(isEmbedded: true)) {
                featureRowLabel(entry)
            }
            .buttonStyle(.plain)
        }
    }

    private func featureRowLabel(_ entry: FeatureEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(entry.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: entry.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(entry.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(entry.title))
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(LocalizedStringKey(entry.description))
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface)
    }
}

// MARK: - MoreItem model

private struct MoreItem {
    let label: LocalizedStringKey
    let icon: String
    let color: Color
    let destination: () -> AnyView
}

// `FeatureTarget` / `FeatureEntry`: see `Features/Search/Service/FeatureCatalog.swift`
// (shared with `SearchView`).
