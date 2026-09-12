import SwiftUI
import NemorisEngine

/// Main view of the import flow.
///
/// Loads the session by id (from the DB), runs engine resolution in the background,
/// shows the list of rows with actions (confirm / skip / manually reassign),
/// then does the final commit into the `transactions` table.
///
/// Reached:
///   - from the import entry point (`ImportEntryView` → `ColumnMappingView` → here)
///   - from the "Import in progress" banner in `MainTabView` to resume.
struct ImportSessionView: View {
    let sessionId: UUID

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var viewModel: ImportSessionViewModel?
    @State private var loadError: String?
    @State private var showCommitConfirm = false
    @State private var showCancelConfirm = false
    @State private var rowToEnrich: ImportSessionRow?
    /// Help sheet describing each processing option.
    @State private var showActionsHelp = false
    /// Full creation form (PayeeCreationFormSheet) with AI/Sirene/Maps help.
    @State private var rowToCreatePayee: ImportSessionRow?
    /// Step 1 of the "link to an existing payee" flow: opens PayeePickerSheet.
    @State private var rowToPickPayee: ImportSessionRow? = nil
    /// Step 2 (or direct for .matched): opens TierUpdateSheet.
    @State private var pendingUpdate: PendingTierUpdate? = nil
    /// Cascade toast (auto-dismisses after ~3s).
    @State private var visibleBulkToast: BulkApplyInfo? = nil

    /// The chosen payee, captured while waiting to be shown in TierUpdateSheet (after
    /// PayeePickerSheet closes — hence the split into 2 @State bindings).
    private struct PendingTierUpdate: Identifiable {
        let id = UUID()
        let row: ImportSessionRow
        let payee: Tiers
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
                    // Step 1: pick an existing payee via PayeePickerSheet.
                    .sheet(item: $rowToPickPayee) { row in
                        PayeePickerSheet(rawLabel: row.rawLabel) { picked in
                            // PayeePickerSheet calls dismiss() after onPick. If we set
                            // pendingUpdate right now, SwiftUI would see a 2nd sheet
                            // opening at the same time → a glitch / dismissal. We capture
                            // the values and wait for the closing animation before
                            // opening TierUpdateSheet.
                            let captured = PendingTierUpdate(row: row, payee: picked)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                pendingUpdate = captured
                            }
                        }
                        // See CLAUDE.md §5: re-injecting \.locale is required for
                        // every level-2+ `.sheet()` reachable on macOS.
                        // ⚠️ `\.paneHostContext` is required too: this view
                        // (`ImportSessionView`) is itself hosted in the macOS
                        // inspector (`.inspector`) — a bare `.sheet()`
                        // opened from there inherits that value, and `.paneChrome`
                        // reads it to publish its buttons in the system bar
                        // instead of drawing them in THIS separate window
                        // (no button visible in the sheet itself). Reset
                        // to `.modal`, as `.adaptivePane` does on its
                        // own fallback `.sheet()` (see AdaptivePane.swift).
                        .presentationDetents([.medium, .large])
                        .environment(\.locale, AppLocalization.locale)
                        .environment(\.paneHostContext, .modal)
                    }
                    // Step 2 (or direct for .matched): editing the chosen payee before assign.
                    .sheet(item: $pendingUpdate) { pending in
                        TierUpdateSheet(row: pending.row, existingPayee: pending.payee) { updated in
                            if updated == pending.payee {
                                viewModel.assign(rowId: pending.row.id, payee: pending.payee)
                            } else {
                                viewModel.assignAndUpdatePayee(rowId: pending.row.id, payee: pending.payee, updatedPayee: updated)
                            }
                            pendingUpdate = nil
                        }
                        .presentationDetents([.large])
                        .environment(\.locale, AppLocalization.locale)
                        .environment(\.paneHostContext, .modal)
                    }
                    .sheet(item: $rowToEnrich) { row in
                        EnrichmentSheetView(row: row) { enrichment in
                            viewModel.apply(enrichment: enrichment, toRowId: row.id)
                        }
                        .presentationDetents([.large])
                        .environment(\.locale, AppLocalization.locale)
                        .environment(\.paneHostContext, .modal)
                    }
                    .sheet(item: $rowToCreatePayee) { row in
                        PayeeCreationFormSheet(
                            row: row,
                            allCategories: viewModel.allCategories
                        ) { newPayee in
                            viewModel.createPayeeAndAssign(rowId: row.id, newPayee: newPayee)
                        }
                        .presentationDetents([.large])
                        .environment(\.locale, AppLocalization.locale)
                        .environment(\.paneHostContext, .modal)
                    }
                    .sheet(isPresented: $showActionsHelp) {
                        ImportActionsHelpSheet()
                            .presentationDetents([.medium, .large])
                            .environment(\.locale, AppLocalization.locale)
                            .environment(\.paneHostContext, .modal)
                    }
                    .overlay(alignment: .top) {
                        if let toast = visibleBulkToast {
                            BulkApplyToast(info: toast)
                                .padding(.horizontal)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .onChange(of: viewModel.lastBulkApply?.timestamp) { _, _ in
                        if let info = viewModel.lastBulkApply {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                visibleBulkToast = info
                            }
                            // Auto-dismiss after 3s
                            Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if visibleBulkToast?.timestamp == info.timestamp {
                                    withAnimation { visibleBulkToast = nil }
                                }
                            }
                        }
                    }
            } else if let loadError {
                EmptyStateView(icon: "exclamationmark.triangle", title: "Erreur", verbatimMessage: loadError)
            } else {
                // Initial skeleton before the session is loaded and engine resolution has started.
                ScrollView {
                    VStack(spacing: 12) {
                        // Header stats placeholder
                        HStack(spacing: 14) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 2) {
                                    SkeletonLine(width: 50, height: 10)
                                    SkeletonLine(width: 30, height: 14)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.Colors.surface)

                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonImportSessionRow()
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
        .task { await loadAndResolve() }
    }

    // MARK: Loading

    private func loadAndResolve() async {
        let repo = ImportSessionRepository()
        guard let session = repo.fetchSession(id: sessionId) else {
            loadError = "Session introuvable."
            return
        }
        let vm = ImportSessionViewModel(session: session)
        vm.loadReferenceData()
        self.viewModel = vm
        await vm.resolveAllPending()
        refreshAppState()
    }

    private func refreshAppState() {
        appState.reloadActiveImportSession()
    }

    /// Cancels the session and dismisses the view. Optionally deletes the payees created during the session.
    private func cancelSession(_ vm: ImportSessionViewModel, deletingCreatedPayees: Bool) {
        vm.cancel(deletingCreatedPayees: deletingCreatedPayees)
        if deletingCreatedPayees {
            appState.dataRefreshToken = UUID()  // refreshes payee lists
        }
        appState.activeImportSession = nil
        appState.showImportSessionSheet = false
        dismiss()
    }

    // MARK: Main content

    @ViewBuilder
    private func content(_ viewModel: ImportSessionViewModel) -> some View {
        VStack(spacing: 0) {
            headerCard(viewModel)
            toolbarRow(viewModel)
            Divider()
            rowsList(viewModel)
            Divider()
            commitBar(viewModel)
        }
        .localizedNavigationTitle("Import en cours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    viewModel.saveNow()
                    appState.showImportSessionSheet = false
                    refreshAppState()
                    dismiss()
                } label: {
                    Label("Fermer", systemImage: "xmark")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        viewModel.bulkConfirmAuto()
                    } label: {
                        Label("Tout accepter (auto)", systemImage: "checkmark.circle.fill")
                    }
                    Button {
                        Task { await viewModel.enrichUnresolvedRows() }
                    } label: {
                        if viewModel.isEnriching {
                            Label("Enrichissement…", systemImage: "hourglass")
                        } else {
                            Label("Enrichir les non-résolus (Sirene + IA + Maps)", systemImage: "sparkles")
                        }
                    }
                    .disabled(viewModel.isEnriching)
                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        Label("Annuler la session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Annuler la session ?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            let createdCount = viewModel.createdPayeeCount
            if createdCount > 0 {
                Button("Annuler et supprimer \(createdCount) tier\(createdCount > 1 ? "s" : "") créé\(createdCount > 1 ? "s" : "")", role: .destructive) {
                    cancelSession(viewModel, deletingCreatedPayees: true)
                }
                Button("Annuler en gardant les tiers", role: .destructive) {
                    cancelSession(viewModel, deletingCreatedPayees: false)
                }
            } else {
                Button("Annuler la session", role: .destructive) {
                    cancelSession(viewModel, deletingCreatedPayees: false)
                }
            }
            Button("Continuer", role: .cancel) {}
        } message: {
            if viewModel.createdPayeeCount > 0 {
                Text("Les lignes non importées seront perdues. \(viewModel.createdPayeeCount) tier\(viewModel.createdPayeeCount > 1 ? "s ont" : " a") été créé\(viewModel.createdPayeeCount > 1 ? "s" : "") pendant cette session (les transactions déjà en base ne sont pas affectées).")
            } else {
                Text("Les lignes non importées seront perdues.")
            }
        }
        .confirmationDialog("Importer \(viewModel.session.readyRows) transactions ?",
                            isPresented: $showCommitConfirm, titleVisibility: .visible) {
            Button("Importer") {
                Task {
                    await viewModel.commit()
                    appState.activeImportSession = nil
                    appState.showImportSessionSheet = false
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les transactions seront ajoutées au compte. Les lignes en attente seront ignorées.")
        }
    }

    // MARK: Header

    @ViewBuilder
    private func headerCard(_ vm: ImportSessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = vm.session.sourceFile {
                Text(name).font(.caption.monospaced()).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            HStack(spacing: 14) {
                stat("Total", value: "\(vm.session.totalRows)", color: AppTheme.Colors.textPrimary)
                stat("Prêtes", value: "\(vm.session.readyRows)", color: AppTheme.Colors.success)
                stat("En attente", value: "\(vm.session.pendingRows)", color: AppTheme.Colors.warning)
                stat("Ignorées", value: "\(vm.session.skippedRows)", color: AppTheme.Colors.textSecondary)
            }
            if vm.isResolving {
                ProgressView(value: vm.resolveProgress)
                    .progressViewStyle(.linear)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
    }

    @ViewBuilder
    private func stat(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
            Text(value).font(.headline).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func toolbarRow(_ vm: ImportSessionViewModel) -> some View {
        HStack {
            Text("Trier par")
                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            Picker("Trier", selection: Binding(
                get: { vm.sortMode },
                set: { vm.sortMode = $0 }
            )) {
                ForEach(ImportSortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            Button { showActionsHelp = true } label: {
                Label("Aide", systemImage: "questionmark.circle")
                    .font(.caption)
            }
            .tint(AppTheme.Colors.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppTheme.Colors.background)
    }

    /// Does a row have a one-tap-confirmable proposal?
    /// (false during analysis and for "To classify" rows with no safe candidate.)
    private func canValidate(_ row: ImportSessionRow) -> Bool {
        switch row.resolution {
        case .pending, .needsManualPick: return false
        default: return true
        }
    }

    // MARK: List

    @ViewBuilder
    private func rowsList(_ vm: ImportSessionViewModel) -> some View {
        if vm.session.rows.isEmpty {
            EmptyStateView(icon: "tray", title: "Session vide", message: "Aucune ligne à afficher.")
        } else {
            List {
                ForEach(vm.displayedRows) { row in
                    ImportSessionRowCell(
                        row: row,
                        clusterSize: vm.clusterSize(for: row),
                        allCategories: vm.allCategories,
                        canValidate: canValidate(row),
                        // Confirm: accepts the proposal as-is (all types).
                        onValidate: { vm.confirm(rowId: row.id) },
                        // Verify: reviews/adjusts the proposed payee before confirming.
                        // matched → edits the existing payee; otherwise → pre-filled creation form.
                        onVerify: {
                            if case .matched(let pid, _, _, _, _) = row.resolution,
                               let pid, let payee = vm.allTiers.first(where: { $0.id == pid }) {
                                pendingUpdate = PendingTierUpdate(row: row, payee: payee)
                            } else {
                                rowToCreatePayee = row
                            }
                        },
                        onCreatePayee: { rowToCreatePayee = row },
                        onLinkExisting: { rowToPickPayee = row },
                        onQuickEnrich: { rowToEnrich = row },
                        onSkip: { vm.skip(rowId: row.id) },
                        onReset: { vm.resetAction(rowId: row.id) },
                        onHelp: { showActionsHelp = true }
                    )
                    // Shortcut to the 2 main verbs (same as the inline bar):
                    // iOS swipe / macOS right-click via RowActions.
                    .rowActions(
                        leading: (canValidate(row) && row.userAction != .confirmed && row.userAction != .manuallySet)
                            ? [RowAction("Valider", systemImage: "checkmark", tint: AppTheme.Colors.success) { vm.confirm(rowId: row.id) }]
                            : [],
                        trailing: row.userAction != .skipped
                            ? [RowAction("Ignorer", systemImage: "minus.circle", role: .destructive) { vm.skip(rowId: row.id) }]
                            : [],
                        leadingFullSwipe: true,
                        trailingFullSwipe: false
                    )
                }
            }
            .listStyle(.plain)
            #if os(macOS)
            // `List` paints its OWN system background on macOS ON TOP OF
            // the host pane's — without this modifier, the user's
            // desktop shows through.
            .scrollContentBackground(.hidden)
            #endif
        }
    }

    // MARK: Commit bar

    @ViewBuilder
    private func commitBar(_ vm: ImportSessionViewModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.session.readyRows) prêtes")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.Colors.success)
                Text("\(vm.session.pendingRows) en attente · \(vm.session.skippedRows) ignorées")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                if let summary = vm.commitSummary {
                    _ = summary  // already commited, nothing to do
                } else {
                    showCommitConfirm = true
                }
            } label: {
                if vm.commitSummary != nil {
                    Label("Terminé", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                } else {
                    Label("Importer", systemImage: "tray.and.arrow.down.fill").labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.session.readyRows == 0 || vm.commitSummary != nil)
        }
        .padding(14)
        .background(.bar)
    }
}

// MARK: - Row cell

private struct ImportSessionRowCell: View {
    let row: ImportSessionRow
    let clusterSize: Int
    let allCategories: [Category]
    /// Is the proposal confirmable in one tap? (grays out "Confirm" otherwise.)
    let canValidate: Bool
    /// **Confirm**: accepts Nemoris's proposal as-is.
    let onValidate: () -> Void
    /// **Verify / edit**: opens the proposed payee's form to review/adjust it.
    let onVerify: () -> Void
    /// **Create a new payee**: full creation form (with AI/Sirene/Maps help).
    let onCreatePayee: () -> Void
    /// **Link to an existing payee**: picker then edit form.
    let onLinkExisting: () -> Void
    /// **Assisted search**: enrichment search only (without creating a payee).
    let onQuickEnrich: () -> Void
    /// **Skip** this row.
    let onSkip: () -> Void
    let onReset: () -> Void
    /// Shows the help describing each option.
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                MerchantLogo(
                    domain: nil,
                    engineMerchantId: engineId,
                    fallbackIcon: categoryIcon,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(row.rawLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.amount, format: .currency(code: "EUR"))
                        .font(.subheadline.bold())
                        .foregroundStyle(row.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    Text(row.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            HStack(spacing: 6) {
                ResolutionChip(snapshot: row.resolution)
                ActionChip(action: row.userAction)
                if clusterSize > 1 {
                    ClusterChip(count: clusterSize)
                }
                Spacer()
            }
            // Boutons d'action inline (style import V2)
            actionsBar
        }
        .padding(.vertical, 4)
    }

    // MARK: Inline actions

    @ViewBuilder
    private var actionsBar: some View {
        switch row.userAction {
        case .pending:
            pendingActions
        case .confirmed, .manuallySet:
            decidedActions(label: row.userAction == .manuallySet ? "Manuel" : "Validé",
                           color: row.userAction == .manuallySet ? AppTheme.Colors.accentSecondary : AppTheme.Colors.success)
        case .skipped:
            decidedActions(label: "Ignoré", color: AppTheme.Colors.textSecondary)
        case .committed:
            HStack {
                Label("Importée", systemImage: "checkmark.circle.fill").foregroundStyle(AppTheme.Colors.success)
                Spacer()
            }.font(.caption)
        }
    }

    /// NORMALIZED action bar — identical for every pending row.
    /// Same verbs, same order, same place: Confirm · Verify · ⋯ (options) · ?.
    /// Only the *availability* of "Confirm" changes (grayed out when nothing is proposed).
    @ViewBuilder
    private var pendingActions: some View {
        if case .pending = row.resolution {
            // Engine resolution still running — no options yet.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Analyse…").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
            }
        } else {
            HStack(spacing: 6) {
                ActionButton(title: "Valider", icon: "checkmark.circle.fill",
                             tint: AppTheme.Colors.success, action: onValidate)
                    .opacity(canValidate ? 1 : 0.4)
                    .disabled(!canValidate)
                ActionButton(title: "Vérifier", icon: "pencil.circle.fill",
                             tint: AppTheme.Colors.accent, action: onVerify)
                Spacer()
                optionsMenu
                Button(action: onHelp) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Options menu — ALWAYS the same entries, in the same order, whatever the type.
    @ViewBuilder
    private var optionsMenu: some View {
        Menu {
            Button { onLinkExisting() } label: {
                Label("Lier à un tier existant…", systemImage: "link")
            }
            Button { onCreatePayee() } label: {
                Label("Créer un nouveau tier…", systemImage: "plus.circle")
            }
            Button { onQuickEnrich() } label: {
                Label("Recherche assistée (Sirene / IA / Maps)…", systemImage: "sparkles")
            }
            Divider()
            Button(role: .destructive, action: onSkip) {
                Label("Ignorer cette ligne", systemImage: "minus.circle")
            }
            Divider()
            Button(action: onHelp) {
                Label("À quoi servent ces options ?", systemImage: "questionmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private func decidedActions(label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Button(action: onReset) {
                Label("Modifier", systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(color)
        }
    }

    private var displayTitle: String {
        if let n = row.assignedPayeeName, !n.isEmpty { return n }
        switch row.resolution {
        case .matched(_, _, let name, _, _): return name
        case .suggestCreate(_, let name, _, _, _): return name
        case .suggestContact(let name, _): return name
        case .systemOperation(_, let displayName): return displayName
        case .needsManualPick(_, _, let topName, _): return topName ?? "À classer"
        case .pending: return "Analyse en cours…"
        }
    }

    private var engineId: String? {
        switch row.resolution {
        case .matched(_, let eid, _, _, _): return eid
        case .suggestCreate(let eid, _, _, _, _): return eid
        case .needsManualPick(_, let eid, _, _): return eid
        default: return nil
        }
    }

    private var categoryIcon: String? {
        guard let cid = row.assignedCategoryId else { return nil }
        return allCategories.first(where: { $0.id == cid })?.displayIcon
    }
}

private struct ResolutionChip: View {
    let snapshot: TierResolutionSnapshot

    var body: some View {
        chip(label: label, color: color, icon: icon)
    }

    private var label: LocalizedStringKey {
        switch snapshot {
        case .pending: return "Analyse…"
        case .matched: return "Reconnu"
        case .suggestCreate: return "Suggéré"
        case .suggestContact: return "Contact P2P"
        case .systemOperation: return "Système"
        case .needsManualPick: return "À classer"
        }
    }

    private var color: Color {
        switch snapshot {
        case .pending: return AppTheme.Colors.textSecondary
        case .matched: return AppTheme.Colors.success
        case .suggestCreate: return AppTheme.Colors.warning
        case .suggestContact: return AppTheme.Colors.accent
        case .systemOperation: return AppTheme.Colors.textSecondary
        case .needsManualPick: return AppTheme.Colors.danger
        }
    }

    private var icon: String {
        switch snapshot {
        case .pending: return "hourglass"
        case .matched: return "checkmark.seal"
        case .suggestCreate: return "lightbulb"
        case .suggestContact: return "person.crop.circle"
        case .systemOperation: return "building.columns"
        case .needsManualPick: return "questionmark.circle"
        }
    }

    private func chip(label: LocalizedStringKey, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

private struct ActionChip: View {
    let action: ImportUserAction

    var body: some View {
        switch action {
        case .pending:
            EmptyView()
        case .confirmed:
            chip("Validé", icon: "checkmark", color: AppTheme.Colors.success)
        case .manuallySet:
            chip("Manuel", icon: "hand.point.up", color: AppTheme.Colors.accentSecondary)
        case .skipped:
            chip("Ignoré", icon: "minus.circle", color: AppTheme.Colors.textSecondary)
        case .committed:
            chip("Importé", icon: "tray.and.arrow.down.fill", color: AppTheme.Colors.accent)
        }
    }

    private func chip(_ label: LocalizedStringKey, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

/// "+N similar" badge to flag that this row has twins in the session.
/// When the user acts on it, the action cascades to the other pending ones.
private struct ClusterChip: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill").font(.caption2.weight(.bold))
            Text("×\(count)").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
        .foregroundStyle(AppTheme.Colors.accent)
    }
}

/// Compact inline action button for the row cell (revived import V2 style).
private struct ActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// Toast shown at the top of the screen after a cascade ("Cascade: 12 similar rows confirmed").
private struct BulkApplyToast: View {
    let info: BulkApplyInfo
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.body)
                .foregroundStyle(AppTheme.Colors.accent)
            Text(info.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.Colors.accent.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Help on processing options

/// Explanatory sheet: describes each option for processing a transaction at import time.
/// Opened via the "?" button (sort bar, inline action bar, ⋯ menu).
struct ImportActionsHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Option: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let color: Color
        let description: String
    }

    private var options: [Option] {
        [
            Option(icon: "checkmark.circle.fill", title: "Valider", color: AppTheme.Colors.success,
                   description: "Accepte l'identification proposée par Nemoris (tier reconnu, marchand suggéré, contact ou opération bancaire) et prépare la ligne pour l'import. Indisponible tant que rien n'est proposé (statut « À classer »)."),
            Option(icon: "pencil.circle.fill", title: "Vérifier", color: AppTheme.Colors.accent,
                   description: "Ouvre la fiche du tier proposé pour la relire ou l'ajuster (nom, catégorie, regex de détection, ville…) avant de la valider."),
            Option(icon: "link", title: "Lier à un tier existant", color: AppTheme.Colors.accent,
                   description: "Associe la transaction à un tier que tu as déjà, via le sélecteur. Utile quand Nemoris propose le mauvais marchand."),
            Option(icon: "plus.circle", title: "Créer un nouveau tier", color: AppTheme.Colors.accentSecondary,
                   description: "Crée un tier de zéro avec le formulaire complet, épaulé par l'aide à l'identification (Sirene, IA, Maps)."),
            Option(icon: "sparkles", title: "Recherche assistée", color: AppTheme.Colors.warning,
                   description: "Interroge Sirene, l'IA et Maps pour retrouver l'identité du marchand, sans créer de tier tout de suite."),
            Option(icon: "minus.circle", title: "Ignorer", color: AppTheme.Colors.textSecondary,
                   description: "Exclut cette ligne de l'import : elle ne sera pas ajoutée aux transactions."),
        ]
    }

    var body: some View {
            // `Form`, NOT `List`: verified live on macOS — even with the
            // `.frame(maxWidth: .infinity, maxHeight:
            // .infinity)` fix documented on `PayeePickerSheet` in place, a bare
            // `List` (`.automatic` style) presented by a `.sheet()` WITHOUT
            // an external `.adaptivePaneFrame()` rendered a window with
            // almost no height: title + "Got it" button squeezed together, no row
            // visible. A `Form` with `.nemorisFormStyle()` uses EXACTLY
            // the same greedy `.frame` but reliably computes its height —
            // it's the path already proven by every other sheet/form
            // in the repo (`EnrichmentSheetView`, `TierUpdateSheet`,
            // `PayeeCreationFormSheet`, `AddTricountReimbursementSheet`…).
            // Neither of these two has interactive content (just text), so
            // nothing specifically depends on `List`.
            Form {
                Section {
                    ForEach(options) { opt in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle().fill(opt.color.opacity(0.15)).frame(width: 34, height: 34)
                                Image(systemName: opt.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(opt.color)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(opt.title)).font(.subheadline.bold())
                                Text(opt.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Les mêmes options sont disponibles pour chaque ligne.")
                        .textCase(nil)
                }

                Section {
                    Label {
                        Text("Toute action se propage automatiquement aux lignes au **libellé identique** (badge ×N) — tu ne traites une série qu'une seule fois.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } icon: {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                } header: {
                    Text("Bon à savoir").textCase(nil)
                }
            }
            .nemorisFormStyle()
            // `.paneChrome` draws its own bars on macOS-sheet — the
            // native toolbar lets the user's desktop show
            // through. See the `macSheetChrome` comment
            // in AdaptivePane.swift.
            .paneChrome("Traiter une transaction", confirmLabel: "Compris", confirmIcon: "checkmark", onConfirm: { dismiss() })
    }
}
