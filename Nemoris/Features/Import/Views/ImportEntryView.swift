import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Entry point of the transaction import flow.
///
/// Flow:
///   1. Pick the target account + pick ONE OR SEVERAL files.
///   2. Each file is routed by its ACTUAL type (sniffed from bytes):
///      • CSV / tabular text → column mapping, reused without a screen
///        when the header signature is already known;
///      • PDF / screenshot / non-tabular text → extraction via
///        `TransactionDocumentParser` (deterministic + AI).
///   3. The rows from ALL files are aggregated into ONE import session.
///
/// ⚠️ The type is NEVER inferred from the extension: a shared file arrives
/// named `<uuid>.dat`, and a Latin-1 decode of a PNG always "succeeds",
/// producing hundreds of thousands of binary characters (a bug class
/// documented in `InvestmentPDFParser.detectKind`).
struct ImportEntryView: View {
    // View presented in MIXED contexts: pushed (macOS sidebar, MoreView,
    // Settings) OR as an adaptive pane (Dashboard, preloaded import). Closing
    // calls BOTH mechanisms — each is a no-op outside its own context
    // (paneDismiss defaults to {}, DismissAction with nothing presented does nothing).
    @Environment(\.dismiss) private var navDismiss
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    @Environment(\.paneHostContext) private var paneHostContext

    /// Closing: EXACTLY one mechanism, never both.
    ///
    /// ⚠️ Calling `paneDismiss()` THEN `navDismiss()` — what the "universal"
    /// version used to do — closes the pane first, after which `DismissAction`
    /// has nothing left to close. On macOS it then bubbles up to the window and
    /// **closes it**: the app vanished into the Dock while the process (and the
    /// in-flight analysis) kept running. The original comment assumed a no-op
    /// "outside its context"; that's true of `paneDismiss` (default `{}`), not
    /// of `DismissAction`.
    private func dismiss() {
        if !isEmbedded, paneHostContext != .root {
            paneDismiss()   // hosted by `.adaptivePane` (iOS sheet / macOS inspector)
            return
        }
        #if os(macOS)
        // Embedded in the sidebar or Settings: on Mac both hosts display
        // content via a state switch, without pushing anything — so there is
        // NO presentation to close, and a `DismissAction` that finds none
        // closes the window instead (the app used to jump back to the Dock).
        if isEmbedded { return }
        #endif
        navDismiss()        // pushed onto a parent `NavigationStack`
    }

    /// files already dropped into `PendingImportInbox` (Siri shortcut
    /// or share extension). Shown as "File(s) received": the user
    /// confirms the target account then continues — no picker to reopen.
    var preloadedFileURLs: [URL] = []

    /// Destination PRE-FILLED by the entry point (Dashboard/Settings →
    /// transactions, Investments module → investments). Editable on
    /// screen: this is a single funnel for both use cases.
    var initialDestination: ImportDestination = .transactions

    /// `true` when the view is PUSHED onto a parent `NavigationStack` (MoreView,
    /// Settings, search, macOS sidebar) → do NOT wrap it in another stack again.
    /// `false` (default) = presented as a sheet (Dashboard / preloaded import) → it
    /// provides its own `NavigationStack`. A nested stack made the view "skip" on
    /// first display (it dismissed itself, then worked on the 2nd tap).
    var isEmbedded: Bool = false

    @State private var destination: ImportDestination?
    @State private var accounts: [Account] = []
    @State private var investmentAccounts: [InvestmentAccount] = []
    @State private var selectedAccountId: Int? = nil
    @State private var selectedInvestmentAccountId: Int? = nil
    @State private var showAccountPicker = false
    @State private var showInvestmentAccountPicker = false
    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var parseError: String?
    /// Documents picked but NOT yet processed: the selection accumulates
    /// (files and screenshots, over several picks) and nothing starts until
    /// the user confirms.
    @State private var stagedFiles: [(data: Data, name: String)] = []

    @State private var existingActiveSession: ImportSessionSummary?
    @State private var showResumeAlert = false
    @State private var isParsing = false

    /// ⚠️ Accumulated rows no longer live HERE: they belong to
    /// `DocumentImportCoordinator`. This screen goes through several steps (one
    /// mapping per table, then document analysis) and closes before the job
    /// finishes — a local `@State` made merging depend on the screen surviving,
    /// and not every source ended up in the final import.
    private var coordinator: DocumentImportCoordinator { .shared }
    /// Tables awaiting mapping, produced by the pipeline's READ phase.
    /// CSV and spreadsheet sheets arrive here interchangeably: both ask the
    /// same question (which column is what).
    @State private var pendingMappings: [ImportPipeline.PendingGrid] = []
    /// Index of the mapping being shown. We ADVANCE a cursor, never remove
    /// an element from `pendingMappings` mid-flow:
    ///
    /// ⚠️ Removing the current element from the pushed screen's callback (what
    /// `removeFirst()` used to do) empties the `navigationDestination`'s content
    /// WHILE it is still on screen — the destination then evaluates to
    /// `EmptyView` in the same render cycle as the pop, the sheet dismiss, and
    /// the session sheet presentation. That's the cause of the crash seen on
    /// a CSV import.
    @State private var mappingIndex: Int = 0
    /// Non-tabular units (PDF pages, screenshots, structured statements): they
    /// go straight to background analysis, no interaction needed.
    @State private var pendingReadout = ImportPipeline.Readout()
    /// Names of all the retained files, for the session label.
    @State private var handledFileNames: [String] = []
    /// Current pushed step. ONE `navigationDestination` driven by
    /// this value: two concurrent destinations toggled in the same render
    /// cycle produce inconsistent transitions. The mapping index is carried
    /// BY the step, so the pushed content always stays valid (see
    /// `mappingIndex`).
    @State private var step: Step? = nil

    /// The only step still PUSHED: column mapping, which needs the
    /// user. Document analysis, meanwhile, runs in the background — which
    /// removes one more pushed screen on macOS as a side effect.
    private enum Step: Hashable {
        case mapping(index: Int)
    }

    private let repository = TransactionRepository()
    private let sessionRepo = ImportSessionRepository()

    var body: some View {
        if isEmbedded {
            stepContent
        } else {
            NavigationStack { stepContent }
        }
    }

    /// ⚠️ macOS: ZERO PUSH. This view is hosted in the inspector, and pushing a
    /// screen there is the documented risky pattern (§N.1: pane painted under
    /// pushed content, AutoLayout freezes and crashes). Since the mapping step
    /// is now ALWAYS shown — no longer skipped when the format was known — this
    /// push used to fire on every CSV import and freeze the window. Mapping
    /// therefore replaces the content WITHIN the same view, and the module's
    /// `NavigationStack` stays at its root.
    /// iOS keeps the push, which is native and safe there.
    @ViewBuilder private var stepContent: some View {
        #if os(macOS)
        if case .mapping(let index) = step,
           index < pendingMappings.count,
           let accountId = selectedAccountId {
            // See `formContent`: only the `.sheet` level-2+ case needs
            // hand-drawn chrome (the native translucent material is
            // inoperative on this surface, per feedback) —
            // embedded and inspector stay on their native toolbar, which is fine.
            if !isEmbedded, paneHostContext == .modal {
                macSheetChrome(
                    title: "Mapping des colonnes",
                    cancel: PaneBarButton(label: "Retour", systemImage: "chevron.left", showsTitle: false, action: { step = nil }),
                    destructive: nil,
                    confirm: nil
                ) {
                    mappingView(index: index, accountId: accountId)
                }
            } else {
                mappingView(index: index, accountId: accountId)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { step = nil } label: {
                                Label("Retour", systemImage: "chevron.left")
                            }
                        }
                    }
            }
        } else {
            formContent
        }
        #else
        formContent
        #endif
    }

    /// Mapping screen for one file, shared across both platforms
    /// (pushed on iOS, swapped in place on macOS).
    @ViewBuilder
    private func mappingView(index: Int, accountId: Int) -> some View {
        let pending = pendingMappings[index]
        ColumnMappingView(
            parsed: pending.grid,
            // `nil` for a workbook: its cells don't depend on any
            // separator, so the screen hides the picker.
            siblingSheets: pending.siblingSheets,
            rawContent: pending.rawText,
            accountId: accountId,
            sourceFile: pending.displayName,
            onRowsReady: { rows in
                coordinator.addRows(rows)
                mappingIndex = index + 1
                advance()
            },
            startingRowNumber: coordinator.seedRows.count + 1
        )
        // Identity tied to the file: without it, the next screen would reuse
        // the previous mapping's `@State` (columns from the earlier file,
        // already pre-selected).
        .id(pending.id)
    }

    /// Chrome (title + "Cancel") above `formBody`, adapted to the
    /// multiple presentation contexts of this view:
    /// - Embedded (sidebar/MoreView/Settings): the parent stack's back
    ///   button is enough, no extra chrome.
    /// - macOS level-1 pane (inspector): chrome published in the
    ///   system bar via `ImportEntryInspectorChrome` (a safe native
    ///   surface, no bug).
    /// - macOS `.sheet` level-2+ (`.adaptivePane` nested inside another
    ///   already-open pane): the ONLY case where a native `.toolbar`
    ///   would land on the separate window whose translucent material
    ///   lets the desktop show through (per feedback) — chrome hand-drawn
    ///   via `macSheetChrome`, reused from `AdaptivePane.swift` rather
    ///   than a generic `.paneChrome` that doesn't know this view's
    ///   own `isEmbedded` axis.
    /// - iOS not embedded (sheet): native `.toolbar`, never affected (the
    ///   bug is macOS-only).
    @ViewBuilder private var formContent: some View {
        #if os(macOS)
        if !isEmbedded, paneHostContext == .modal {
            macSheetChrome(
                title: "Importer",
                cancel: PaneBarButton(label: "Annuler", systemImage: "xmark", showsTitle: false, action: cancelFunnel),
                destructive: nil,
                confirm: nil
            ) {
                formBody
            }
        } else {
            formBody
                .localizedNavigationTitle("Importer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // The only other case where this toolbar could show a button
                    // is already covered above by `!isEmbedded, host == .modal`
                    // (routed to `macSheetChrome`) — so what's left here is
                    // only the inspector (chrome published elsewhere, no native
                    // button) or embedded (nothing to show).
                }
                .modifier(ImportEntryInspectorChrome(isEmbedded: isEmbedded, dismiss: cancelFunnel))
        }
        #else
        formBody
            .localizedNavigationTitle("Importer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { cancelFunnel() } label: {
                            Label("Annuler", systemImage: "xmark")
                        }
                    }
                }
            }
        #endif
    }

    @ViewBuilder private var formBody: some View {
            Form {
                Section {
                    Picker("Destination", selection: Binding(
                        get: { destination ?? initialDestination },
                        set: { newValue in destination = newValue }
                    )) {
                        ForEach(ImportDestination.allCases) { dest in
                            Label(LocalizedStringKey(dest.displayName), systemImage: dest.icon)
                                .tag(dest)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Destination")
                } footer: {
                    Text(LocalizedStringKey(activeDestination.hint))
                }

                Section("Compte cible") {
                    if activeDestination == .transactions {
                        if accounts.isEmpty {
                            Text("Aucun compte disponible — créez-en un d'abord.")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            Button {
                                showAccountPicker = true
                            } label: {
                                HStack {
                                    Text("Compte").foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    // Wrap required: coalescing with `.name`
                                    // makes the whole expression a `String` —
                                    // without it `Text(String)` stays verbatim,
                                    // see CLAUDE.md §5.
                                    Text(LocalizedStringKey(accounts.first(where: { $0.id == selectedAccountId })?.name ?? "Choisir…"))
                                        .foregroundStyle(selectedAccountId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                        }
                    } else {
                        if investmentAccounts.isEmpty {
                            Text("Aucun compte d'investissement — créez-en un d'abord.")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            Button {
                                showInvestmentAccountPicker = true
                            } label: {
                                HStack {
                                    Text("Compte").foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    if let a = investmentAccounts.first(where: { $0.id == selectedInvestmentAccountId }) {
                                        Text("\(a.name) (\(a.broker))").foregroundStyle(AppTheme.Colors.textPrimary)
                                    } else {
                                        Text("Choisir…").foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                        }
                    }
                }

                Section("Fichiers") {
                    if !preloadedFileURLs.isEmpty {
                        // files already received (share / shortcut):
                        // confirm the account then continue directly.
                        HStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .foregroundStyle(AppTheme.Colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preloadedFileURLs.count == 1
                                     ? "1 fichier reçu"
                                     : "\(preloadedFileURLs.count) fichiers reçus")
                                Text("Transmis via le partage ou un raccourci")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Button {
                            handleFileResult(.success(preloadedFileURLs), sharedNaming: true)
                        } label: {
                            if isParsing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Analyse en cours…")
                                }
                            } else {
                                Label("Continuer", systemImage: "arrow.right.circle.fill")
                            }
                        }
                        .disabled(!hasTargetAccount || isParsing)

                        Button("Choisir d'autres fichiers") {
                            showFilePicker = true
                        }
                        .disabled(!hasTargetAccount || isParsing)
                    } else {
                        // Selections ACCUMULATE. Nothing starts until
                        // the user taps "Import": they can add files and
                        // screenshots over several picks, which an
                        // automatic launch on selection would prevent.
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Ajouter des fichiers", systemImage: "doc.badge.plus")
                        }
                        .disabled(!hasTargetAccount || isParsing)

                        // Bank app screenshots — `PhotosPicker`
                        // also exists on macOS (Photos is available there), the
                        // photo library just wasn't offered here.
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                            Label("Ajouter des captures", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(!hasTargetAccount || isParsing)

                        ForEach(Array(stagedFiles.enumerated()), id: \.offset) { index, file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(AppTheme.Colors.accent)
                                Text(file.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    stagedFiles.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let parseError {
                        Text(parseError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }

                if preloadedFileURLs.isEmpty {
                    Section {
                        Button {
                            startImport()
                        } label: {
                            HStack {
                                Spacer()
                                if isParsing {
                                    ProgressView().controlSize(.small)
                                    Text("Préparation…")
                                } else {
                                    Label(importButtonLabel, systemImage: "arrow.right.circle.fill")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(stagedFiles.isEmpty || !hasTargetAccount || isParsing)
                        .tint(AppTheme.Colors.accent)
                    }
                }

                Section {
                    Text("CSV, PDF ou capture d'écran. Pour un CSV, vous mapperez les colonnes (date / montant / libellé) — le mapping est mémorisé pour les prochains imports du même format. Un PDF ou une capture est analysé automatiquement.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: { Text("À savoir") }
            }
            .nemorisFormStyle()
            // Project convention: the brand tint is set PER VIEW (there is
            // no global tint). A view presented in a pane doesn't inherit it
            // from its caller — without this, its native controls fall back
            // to the system's accent color, hence blue icons.
            .tint(AppTheme.Colors.accent)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .utf8PlainText,
                                      .text, .pdf, .image, .png, .jpeg, .heic, .data, .item],
                allowsMultipleSelection: true
            ) { result in
                handleFileResult(result)
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                loadPhotos(items)
            }
            // iOS only: on macOS mapping replaces the content in
            // place (see `stepContent`), never pushes.
            #if !os(macOS)
            .navigationDestination(item: $step) { current in
                switch current {
                case .mapping(let index):
                    // The index comes from the step: `pendingMappings` is never
                    // mutated mid-flow, so this content stays valid for as
                    // long as the screen is pushed.
                    if index < pendingMappings.count, let accountId = selectedAccountId {
                        mappingView(index: index, accountId: accountId)
                    }
                }
            }
            #endif
            .alert("Une session d'import est déjà en cours",
                   isPresented: $showResumeAlert, presenting: existingActiveSession) { _ in
                Button("Reprendre") {
                    // Same handoff as the end of import: presenting the
                    // session while dismissing this screen in the same cycle
                    // didn't work on iOS (two concurrent `.sheet`s).
                    Self.handOver(to: appState, dismissSelf: dismiss)
                }
                Button("Annuler la précédente", role: .destructive) {
                    if let id = existingActiveSession?.id {
                        sessionRepo.deleteSession(id: id)
                        ImportNotificationService.cancelReminder(forSessionId: id)
                        appState.reloadActiveImportSession()
                        existingActiveSession = nil
                    }
                }
                Button("Fermer", role: .cancel) { cancelFunnel() }
            } message: { _ in
                Text("Vous devez d'abord la terminer ou l'annuler avant d'en démarrer une nouvelle.")
            }
            .task { loadInitialState() }
            .adaptivePane(isPresented: $showAccountPicker) {
                AccountSearchSheet(accounts: accounts, selectedId: selectedAccountId, title: "Choisir un compte") { picked in
                    selectedAccountId = picked?.id
                }
            }
            .adaptivePane(isPresented: $showInvestmentAccountPicker) {
                InvestmentAccountSearchSheet(accounts: investmentAccounts, selectedId: selectedInvestmentAccountId, title: "Choisir un compte") { picked in
                    selectedInvestmentAccountId = picked.id
                }
            }
    }

    // MARK: - Logic

    /// Effective destination: the one chosen on screen, or else the
    /// one pre-filled by the entry point.
    private var activeDestination: ImportDestination { destination ?? initialDestination }

    private var importButtonLabel: LocalizedStringKey {
        switch stagedFiles.count {
        case 0:  return "Importer"
        case 1:  return "Importer 1 document"
        default: return "Importer \(stagedFiles.count) documents"
        }
    }

    /// Is a target account selected for the current destination?
    private var hasTargetAccount: Bool {
        activeDestination == .transactions ? selectedAccountId != nil : selectedInvestmentAccountId != nil
    }

    private func loadInitialState() {
        accounts = repository.fetchAccounts()
        investmentAccounts = InvestmentRepository().fetchAccounts()
        if selectedInvestmentAccountId == nil {
            selectedInvestmentAccountId = investmentAccounts.first?.id
        }
        if selectedAccountId == nil {
            let preferred = appState.defaultAccountId > 0 ? appState.defaultAccountId : (appState.selectedAccountId ?? 0)
            selectedAccountId = accounts.first(where: { $0.id == preferred })?.id ?? accounts.first?.id
        }
        if let active = sessionRepo.fetchActiveSummary() {
            existingActiveSession = active
            showResumeAlert = true
        }
    }

    /// `sharedNaming`: files from the inbox have opaque UUID
    /// names — we substitute a readable name for display and for the
    /// session's `source_file`.
    private func handleFileResult(_ result: Result<[URL], Error>, sharedNaming: Bool = false) {
        parseError = nil
        switch result {
        case .failure(let err):
            parseError = err.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // Files received via share/shortcut: process right away.
            // Manual selection: just queue it, the user decides
            // when to launch (see `stagedFiles`).
            guard sharedNaming else {
                stageFiles(urls)
                return
            }
            resetPipeline()
            isParsing = true
            Task {
                // Read off the main thread: on N files, loading it on
                // the main thread freezes the UI for the whole import.
                let loaded: [(data: Data, name: String)] = urls.enumerated().compactMap { index, url in
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    let name = sharedNaming
                        ? "Relevé partagé \(index + 1).\(url.pathExtension)"
                        : url.lastPathComponent
                    return (data, name)
                }
                guard !loaded.isEmpty else {
                    await MainActor.run {
                        isParsing = false
                        parseError = "Lecture impossible du ou des fichiers sélectionnés."
                    }
                    return
                }
                await classify(loaded)
            }
        }
    }

    /// Starts processing the accumulated selection.
    private func startImport() {
        parseError = nil
        let files = stagedFiles          // captured BEFORE the reset
        guard !files.isEmpty else { return }
        resetPipeline()
        isParsing = true
        Task { await classify(files) }
    }

    /// Queues picked files without starting anything.
    private func stageFiles(_ urls: [URL]) {
        Task {
            let loaded: [(data: Data, name: String)] = urls.compactMap { url in
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (data, url.lastPathComponent)
            }
            await MainActor.run {
                guard !loaded.isEmpty else {
                    parseError = "Lecture impossible du ou des fichiers sélectionnés."
                    return
                }
                stagedFiles.append(contentsOf: loaded)
            }
        }
    }

    /// Screenshots picked from the photo library: they join the exact
    /// same queue as files (the real type is sniffed from the bytes).
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        parseError = nil
        Task {
            var loaded: [(data: Data, name: String)] = []
            for (index, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    loaded.append((data, "Capture \(stagedFiles.count + index + 1)"))
                }
            }
            await MainActor.run {
                guard !loaded.isEmpty else {
                    parseError = "Lecture impossible de la ou des captures sélectionnées."
                    return
                }
                stagedFiles.append(contentsOf: loaded)
                // The picker is cleared so a new selection triggers
                // `onChange` again (otherwise picking the same screenshots
                // again would produce nothing).
                photoItems = []
            }
        }
    }

    /// Reads the files through the pipeline, then splits off what needs
    /// the user (tables to map) from what goes to the background.
    ///
    /// ⚠️ This screen no longer sniffs anything itself. It used to have its
    /// own format detection, duplicating the parsers' — three copies in total,
    /// which ended up diverging (one knew about workbooks, the others didn't).
    /// The pipeline's read phase is now the only place that decides
    /// "this file is a table / a document / a structured statement".
    private func classify(_ files: [(data: Data, name: String)]) async {
        let sources = files.map { ImportDocumentSource(data: $0.data, displayName: $0.name) }
        let readout = await ImportPipeline.read(sources: sources, destination: activeDestination)

        // "Investments" destination: no column mapping or
        // session — everything goes to the parser, whose prompt is tuned
        // for trade confirmations and portfolios.
        guard activeDestination == .transactions else {
            await MainActor.run {
                isParsing = false
                handledFileNames = files.map(\.name)
                guard let account = targetAccountId else { return }
                coordinator.beginJob(destination: activeDestination,
                                     accountId: account,
                                     sourceLabel: sessionLabel())
                // No mapping possible on the investments side: nothing to wait
                // for from the user, the result is reviewable as soon as it's ready.
                coordinator.setAwaitingUserMapping(false)
                coordinator.startAnalysis(readout: readout)
                step = nil
                Task { @MainActor in dismiss() }
            }
            return
        }

        await MainActor.run {
            isParsing = false
            // ⚠️ The mapping screen is ALWAYS shown, even when the
            // header signature is already known. The remembered format is used to
            // PRE-FILL (the "Known format" banner), not to skip the step:
            // two files with the same header can have a different separator or
            // decimal convention, and the user needs to be able to
            // check the columns before importing.
            pendingMappings = readout.pendingGrids
            mappingIndex = 0
            pendingReadout = ImportPipeline.Readout(units: readout.units)
            handledFileNames = files.map(\.name)
            // Opens the job BEFORE the first step: from here on, every
            // source (mapped tables, then analyzed documents) feeds the
            // same coordinator, which survives this screen's dismissal.
            if let account = targetAccountId {
                coordinator.beginJob(destination: activeDestination,
                                     accountId: account,
                                     sourceLabel: sessionLabel())
            }
            // ⚠️ Document analysis now starts AT THE SAME TIME as the
            // first mapping screen. Mapping a CSV no longer blocks the
            // PDFs in the same batch — on a mixed import, the user maps
            // while the documents are being analyzed, instead of waiting afterward.
            //
            // The `awaitingUserMapping` lock keeps the banner from offering
            // "Continue" before mapping is done: the result would be
            // incomplete, and would open a second sheet on top of the
            // mapping screen.
            coordinator.setAwaitingUserMapping(!readout.pendingGrids.isEmpty)
            if !readout.units.isEmpty {
                coordinator.startAnalysis(readout: ImportPipeline.Readout(units: readout.units))
            }
            advance()
        }
    }

    /// Target account for the current destination.
    private var targetAccountId: Int? {
        activeDestination == .transactions ? selectedAccountId : selectedInvestmentAccountId
    }

    /// Next step: documents first (they have a review screen), then the
    /// column mappings one by one, then session creation.
    private func advance() {
        // Column mappings first: they're the ONLY steps that need
        // the user. Document analysis is already
        // running in the background since `classify`.
        if mappingIndex < pendingMappings.count {
            step = .mapping(index: mappingIndex)
            return
        }
        // Nothing left to map: release the lock, which makes the
        // analysis result available in the banner as soon as it's ready (it may
        // already be — that's the whole point of running it in parallel).
        coordinator.setAwaitingUserMapping(false)

        // Documents are still running or already analyzed: hand off, the
        // banner takes over and will reopen the review.
        if !pendingReadout.units.isEmpty {
            step = nil
            // Dismiss on the next cycle: popping, closing and letting
            // the banner appear in the same render cycle crashes
            // SwiftUI.
            Task { @MainActor in dismiss() }
            return
        }
        // No documents: every source was a table, the session
        // can be created right away. Pop FIRST, and creating it
        // (which closes this sheet and presents another) waits for the next
        // cycle, for the same reason.
        step = nil
        Task { @MainActor in finalize() }
    }

    /// User abandons the flow (the "Cancel" button).
    ///
    /// ⚠️ ALSO cancels the job: since analysis starts in parallel with
    /// mapping, closing the funnel would leave an analysis running whose
    /// tables will never be mapped — so an import missing part of
    /// its files, presented as complete. "Cancel" on the import screen
    /// means the import doesn't happen.
    private func cancelFunnel() {
        if coordinator.isActive { coordinator.cancel() }
        dismiss()
    }

    /// No document to analyze: every source is an already-mapped CSV,
    /// create the session right away with the accumulated set.
    private func finalize() {
        guard let accountId = selectedAccountId else { return }
        let rows = coordinator.transactionRows
        guard !rows.isEmpty else {
            parseError = "Aucune opération exploitable dans le ou les fichiers sélectionnés."
            coordinator.clear()
            return
        }
        guard let summary = sessionRepo.createSession(rows: rows,
                                                      accountId: accountId,
                                                      sourceFile: coordinator.sourceLabel ?? sessionLabel()) else {
            parseError = "Échec de la sauvegarde de la session."
            return
        }
        coordinator.clear()   // job consumed
        appState.activeImportSession = summary
        Self.handOver(to: appState, dismissSelf: dismiss)
    }

    /// Hands off to the full review (payees, categories, confirm/skip
    /// row by row) without flickering.
    ///
    /// ⚠️ Two RADICALLY different mechanisms:
    ///   • macOS — the inspector has a single slot and
    ///     `InspectorPaneCenter.present` can replace its content in ONE
    ///     operation (it closes the previous owner itself). Closing first
    ///     produced a close THEN a reopen, visible and jarring.
    ///   • iOS — these are `.sheet`s: a second one can't be presented
    ///     while the first is on screen, closing then waiting is required.
    @MainActor
    static func handOver(to appState: AppState, dismissSelf: () -> Void) {
        #if os(macOS)
        appState.showImportSessionSheet = true
        #else
        dismissSelf()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            appState.showImportSessionSheet = true
        }
        #endif
    }

    /// Session label: the first file, followed by the count of others.
    private func sessionLabel() -> String? {
        guard let first = handledFileNames.first else { return nil }
        return handledFileNames.count > 1 ? "\(first) +\(handledFileNames.count - 1)" : first
    }

    private func resetPipeline() {
        stagedFiles = []
        pendingMappings = []
        mappingIndex = 0
        pendingReadout = ImportPipeline.Readout()
        handledFileNames = []
        step = nil
    }

}

#if os(macOS)
/// Publishes "Cancel" in the macOS system bar ONLY when this content is
/// actually hosted in the pane (adaptivePane level 1, `!isEmbedded`).
/// Pushed as a direct module (sidebar/MoreView) or as a level-2 sheet → no-op
/// (the body's conditional `.toolbar` already handles those cases).
private struct ImportEntryInspectorChrome: ViewModifier {
    let isEmbedded: Bool
    let dismiss: () -> Void
    @Environment(\.paneHostContext) private var host

    func body(content: Content) -> some View {
        if !isEmbedded, host == .inspector {
            content.publishesInspectorChrome {
                PaneChromeModel(title: "Importation",
                                leading: PaneBarButton(label: "Annuler", action: dismiss),
                                trailing: [])
            }
        } else {
            content
        }
    }
}
#endif
