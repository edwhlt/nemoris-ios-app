import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Smart import view (PDF, image/screenshot, CSV) for investments.
///
/// **Flow:**
/// 1. Pick the file OR a capture (photo library) + target account
/// 2. Text extraction (PDFKit / Vision OCR) + AI parsing page by page (progress bar)
/// 3. Preview of the detected orders OR positions — the user can tick/untick
/// 4. Summary + Import button
/// 5. Database commit: positions + orders created (synthetic BUY in snapshot mode)
struct InvestmentPDFImportView: View {

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    // MARK: - State

    @State private var step: ImportStep = .selectFile
    @State private var selectedAccountId: Int?
    @State private var accounts: [InvestmentAccount] = []

    // Parsing
    @State private var pageResults: [PDFPageResult] = []
    /// Raw pipeline output, kept for the per-source detail and its JSON
    /// inspection. `pageResults` is a projection of it: the original is kept
    /// rather than trying to rebuild the elements' origin from the projection.
    @State private var batch = ImportBatchResult()
    @State private var allOrders: [PDFExtractedOrder] = []
    /// Chantier C — positions extraites en mode capture de portefeuille.
    @State private var allPositions: [PDFExtractedPosition] = []
    @State private var parsingTotal: Int = 0
    @State private var parsingCurrent: Int = 0
    @State private var parsingError: String?

    // Import
    @State private var importResult: PDFImportResult?

    // File picker
    @State private var showFilePicker = false
    @State private var showAccountPicker = false
    @State private var pdfURLs: [URL] = []

    // Captures from the photo library (screenshots of PEA/brokerage apps).
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickedImages: [Data] = []
    /// Documents supplied by the unified funnel (already loaded in memory).
    @State private var preloadedSources: [ImportDocumentSource] = []

    private let repository = InvestmentRepository()
    private let parser = InvestmentPDFParser.shared

    /// Fallback offered when Apple Intelligence isn't available: switches to the
    /// deterministic CSV import (column mapping, no AI). nil = no fallback offered.
    private let onFallbackToCSV: (() -> Void)?

    /// Standard init (opened from the ⋯ menu).
    init(onFallbackToCSV: (() -> Void)? = nil) {
        self.onFallbackToCSV = onFallbackToCSV
        self.onFinished = nil
    }

    /// Init pre-filled with the files dropped by a Siri shortcut or the share
    /// extension. The user picks the target account, then starts the analysis
    /// (no automatic import).
    init(preloadedFileURLs urls: [URL], onFallbackToCSV: (() -> Void)? = nil) {
        _pdfURLs = State(initialValue: urls)
        self.onFallbackToCSV = onFallbackToCSV
        self.onFinished = nil
    }

    /// Entry from the unified import funnel (`ImportEntryView`): the destination,
    /// the target account and the documents are ALREADY chosen, so the analysis
    /// starts right away. `onFinished` closes the whole funnel — without it,
    /// "Done" would only pop this screen and return to file selection.
    init(preloadedSources sources: [ImportDocumentSource],
         accountId: Int,
         onFinished: @escaping () -> Void) {
        _preloadedSources = State(initialValue: sources)
        _selectedAccountId = State(initialValue: accountId)
        _step = State(initialValue: .parsing)
        self.onFallbackToCSV = nil
        self.onFinished = onFinished
    }

    /// Result of an analysis already done in the BACKGROUND by
    /// `DocumentImportCoordinator`: the review opens directly. That's what lets
    /// the user close the import during the analysis and come back to it through
    /// the banner without losing anything.
    init(preparsedBatch: ImportBatchResult,
         accountId: Int,
         onFinished: @escaping () -> Void) {
        let results = preparsedBatch.investmentPages()
        _batch = State(initialValue: preparsedBatch)
        _pageResults = State(initialValue: results)
        _allOrders = State(initialValue: results.flatMap(\.orders))
        _allPositions = State(initialValue: results.flatMap(\.positions))
        _selectedAccountId = State(initialValue: accountId)
        _step = State(initialValue: .preview)
        self.onFallbackToCSV = nil
        self.onFinished = onFinished
    }

    /// Closes the parent funnel, when this view is hosted in it.
    private var onFinished: (() -> Void)?

    enum ImportStep {
        case selectFile
        case parsing
        case preview
        case importing
        case done
    }

    // MARK: - Body

    var body: some View {
            Group {
                switch step {
                case .selectFile:
                    selectFileView
                case .parsing:
                    parsingView
                case .preview:
                    previewView
                case .importing:
                    importingView
                case .done:
                    doneView
                }
            }
            .paneChrome("Import intelligent", cancelLabel: "Fermer", onCancel: { dismiss() })
        .onAppear { loadAccounts() }
        // Entry through the unified funnel: documents and account are already
        // chosen, the analysis starts on its own (no intermediate button).
        .task {
            guard step == .parsing, pageResults.isEmpty, !preloadedSources.isEmpty else { return }
            startParsing()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                UTType.pdf,
                UTType.image, UTType.jpeg, UTType.png, UTType.heic, UTType.tiff, UTType.bmp, UTType.webP,
                UTType.commaSeparatedText, UTType.tabSeparatedText, UTType.plainText,
                UTType.data  // fallback for any format
            ],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            pdfURLs = urls
        }
        // Loading the captures chosen in the photo library. Files and captures
        // ACCUMULATE (a PDF statement plus a capture of the same app are two
        // complementary views of the same portfolio): the ISIN/ticker deduplication
        // of `aggregatePositions` absorbs the overlaps.
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var loaded: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaded.append(data)
                    }
                }
                await MainActor.run { pickedImages = loaded }
            }
        }
    }

    // MARK: - Step 1: file + account selection

    private var selectFileView: some View {
        Form {
            // AI availability
            if !parser.isAIAvailable {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Colors.warning)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Apple Intelligence requise")
                                .font(.subheadline).fontWeight(.semibold)
                            Text("La lecture automatique (PDF, capture d'écran, image) utilise l'IA on-device : iOS 26+ avec Apple Intelligence activée est requis.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)

                    // Fallback without AI: the deterministic CSV import (column mapping) stays
                    // fully available — offline-first.
                    if let onFallbackToCSV {
                        Button {
                            dismiss()
                            // Let the sheet close before presenting another one.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onFallbackToCSV()
                            }
                        } label: {
                            Label("Importer un CSV à la place", systemImage: "tablecells")
                                .font(.subheadline)
                        }
                        .tint(AppTheme.Colors.accent)
                    }
                }
            }

            // Fichier
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileSelectionLabel)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            if !pdfURLs.isEmpty {
                                Text("Toucher pour changer")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                // Capture from the photo library (screenshot of a PEA/brokerage app).
                // Les valeurs sont capturées AVANT le closure `label:` : sous Swift 6
                // strict concurrency, ce paramètre de PhotosPicker n'hérite pas
                // toujours l'isolation MainActor du contexte appelant.
                let imageLabel = imageSelectionLabel
                let hasPickedImages = !pickedImages.isEmpty
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(AppTheme.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(imageLabel)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(hasPickedImages ? "Toucher pour changer" : "Depuis la photothèque")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Fichier source")
            } footer: {
                Text("PDF, image (photo d'un relevé), capture d'écran de ton PEA/CTO, CSV, texte… Le format est détecté automatiquement. L'IA analyse le contenu pour identifier les ordres OU les positions détenues.")
            }

            // Compte cible
            Section {
                if accounts.isEmpty {
                    Text("Aucun compte d'investissement")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.subheadline)
                } else {
                    Button {
                        showAccountPicker = true
                    } label: {
                        HStack {
                            Text("Compte cible").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if let a = accounts.first(where: { $0.id == selectedAccountId }) {
                                Text("\(a.name) (\(a.broker))").foregroundStyle(AppTheme.Colors.textPrimary)
                            } else {
                                Text("Sélectionner…").foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }
            } header: {
                Text("Compte d'investissement")
            } footer: {
                Text("Les ordres importés seront rattachés aux positions de ce compte. Les nouvelles positions seront créées automatiquement.")
            }

            // Lancer
            Section {
                Button {
                    startParsing()
                } label: {
                    HStack {
                        Spacer()
                        Label("Analyser", systemImage: "sparkles")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canStartParsing)
                .tint(AppTheme.Colors.accent)
            }
        }
        .nemorisFormStyle()
        .adaptivePane(isPresented: $showAccountPicker) {
            InvestmentAccountSearchSheet(accounts: accounts, selectedId: selectedAccountId, title: "Compte cible") { picked in
                selectedAccountId = picked.id
            }
        }
    }

    private var fileSelectionLabel: String {
        switch pdfURLs.count {
        case 0:  return "Choisir un ou plusieurs fichiers"
        case 1:  return pdfURLs[0].lastPathComponent
        default: return "\(pdfURLs.count) fichiers sélectionnés"
        }
    }

    private var imageSelectionLabel: String {
        switch pickedImages.count {
        case 0:  return "Choisir une ou plusieurs captures"
        case 1:  return "1 capture sélectionnée"
        default: return "\(pickedImages.count) captures sélectionnées"
        }
    }

    private var canStartParsing: Bool {
        (!pdfURLs.isEmpty || !pickedImages.isEmpty) && selectedAccountId != nil && parser.isAIAvailable
    }

    // MARK: - Step 2: parsing in progress

    /// Same processing screen as the transaction import
    /// (`DocumentAnalysisProgressSection`): a determinate bar as soon as the
    /// number of units is known, and neutral wording — "Page X / Y" means nothing
    /// for a screenshot or a CSV.
    private var parsingView: some View {
        Form {
            Section {
                DocumentAnalysisProgressSection(
                    done: parsingCurrent, total: parsingTotal,
                    subtitle: "Lecture des opérations et des lignes détenues (titre, quantité, cours)."
                )
            }
            if let error = parsingError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                }
            }
        }
        .nemorisFormStyle()
    }

    // MARK: - Step 3: order preview

    private var previewView: some View {
        // Form (not List): a form-like review → native rounded boxes on macOS via
        // nemorisFormStyle(), native insetGrouped on iOS.
        Form {
            // Summary
            Section {
                if !allOrders.isEmpty {
                    HStack {
                        Label("\(allOrders.count) ordre(s) détecté(s)", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text("\(allOrders.filter(\.isSelected).count) sélectionné(s)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                if !allPositions.isEmpty {
                    HStack {
                        Label("\(allPositions.count) position(s) détectée(s)", systemImage: "chart.pie")
                        Spacer()
                        Text("\(allPositions.filter(\.isSelected).count) sélectionnée(s)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                HStack {
                    // Wording matched to the real format: "page" only makes sense for a PDF,
                    // and the import also accepts captures, images and CSV.
                    Label("\(pageResults.count) \(analyzedUnitLabel)", systemImage: analyzedUnitIcon)
                    Spacer()
                }
                if usedDeterministicFallback {
                    Label("Extraction automatique utilisée (sans IA)", systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Résumé")
            }

            if allOrders.isEmpty && allPositions.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("Rien à importer")
                            .font(.headline)
                        // A PRECISE reason rather than a single message: without it, a silent OCR,
                        // an unavailable AI, a failed AI and a document genuinely without any
                        // operation can't be told apart.
                        Text(emptyStateReason)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                // Detail PER UNIT (same block as the transaction import): why each one
                // yielded nothing, and the text actually read.
                ImportSourceBreakdownSection(
                    summaries: batch.perSource(),
                    noun: "ligne",
                    debugJSON: { batch.debugJSON(sourceIndex: $0.sourceIndex) })
                DocumentAnalysisDiagnosticsSection(
                    units: pageResults.map { $0.analysisUnit(sourceName: $0.sourceName) })
            } else {
                // Portfolio capture mode — detected positions
                if !allPositions.isEmpty {
                    let posGroups = InvestmentPDFParser.aggregatePositions(allPositions)
                    Section {
                        Text("Capture de portefeuille — \(posGroups.count) ligne(s) détenue(s)")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } header: {
                        Text("Positions détectées")
                    }
                    ForEach(posGroups) { position in
                        Section { positionRow(position) }
                    }
                }

                // Order mode — grouped by position
                if !allOrders.isEmpty {
                    let groups = InvestmentPDFParser.aggregateByPosition(allOrders)
                    Section {
                        Text("\(groups.count) position(s) identifiée(s)")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } header: {
                        Text("Ordres détectés")
                    }
                    ForEach(groups) { group in
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.assetName)
                                    .font(.headline)
                                HStack(spacing: 12) {
                                    if !group.isin.isEmpty {
                                        Text(group.isin)
                                            .font(.caption).monospaced()
                                            .foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                    if !group.ticker.isEmpty {
                                        Text(group.ticker)
                                            .font(.caption).fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                            .foregroundStyle(AppTheme.Colors.accent)
                                    }
                                    Text(group.assetType)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }
                            }
                            .padding(.vertical, 4)

                            ForEach(group.orders) { order in
                                orderRow(order)
                            }
                        }
                    }
                }

                // Even when rows were found, failed units stay listed: on a multi-page PDF,
                // some may have yielded nothing without it being visible.
                ImportSourceBreakdownSection(
                    summaries: batch.perSource(),
                    noun: "ligne",
                    debugJSON: { batch.debugJSON(sourceIndex: $0.sourceIndex) })
                DocumentAnalysisDiagnosticsSection(
                    units: pageResults.map { $0.analysisUnit(sourceName: $0.sourceName) })

                // Bouton importer
                Section {
                    Button {
                        performImport()
                    } label: {
                        HStack {
                            Spacer()
                            Label(importButtonLabel, systemImage: "square.and.arrow.down.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(selectedImportCount == 0)
                    .tint(AppTheme.Colors.accent)
                }
            }
        }
        .nemorisFormStyle()
    }

    private var selectedImportCount: Int {
        allOrders.filter(\.isSelected).count + allPositions.filter(\.isSelected).count
    }

    private var importButtonLabel: String {
        let orders = allOrders.filter(\.isSelected).count
        let positions = allPositions.filter(\.isSelected).count
        if orders > 0 && positions > 0 { return "Importer \(orders) ordre(s) + \(positions) position(s)" }
        if positions > 0 { return "Importer \(positions) position(s)" }
        return "Importer \(orders) ordre(s)"
    }

    /// Preview row of a detected position (snapshot mode) with a selection toggle.
    @ViewBuilder
    private func positionRow(_ position: PDFExtractedPosition) -> some View {
        // The displayed row is AGGREGATED: it can merge several raw rows coming
        // from different pages or captures. The toggle must therefore apply to the
        // WHOLE group — matching on the `id` alone would untick only the first raw
        // row, and the others would still be imported.
        let key = InvestmentPDFParser.groupKey(isin: position.isin,
                                               ticker: position.ticker,
                                               assetName: position.assetName)
        let binding = Binding<Bool>(
            get: {
                allPositions.contains {
                    InvestmentPDFParser.groupKey(isin: $0.isin, ticker: $0.ticker,
                                                 assetName: $0.assetName) == key && $0.isSelected
                }
            },
            set: { newValue in
                for idx in allPositions.indices
                where InvestmentPDFParser.groupKey(isin: allPositions[idx].isin,
                                                   ticker: allPositions[idx].ticker,
                                                   assetName: allPositions[idx].assetName) == key {
                    allPositions[idx].isSelected = newValue
                }
            }
        )
        HStack(spacing: 10) {
            Toggle(isOn: binding) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.7)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(position.assetName)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !position.ticker.isEmpty {
                        Text(position.ticker)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    (Text("×") + Text(position.quantity, format: .number) + Text(" @ ") + Text(position.averageBuyPrice, format: .currency(code: position.currency)))
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text((position.currentValue ?? position.investedCost), format: .currency(code: position.currency))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                confidenceBadge(position.confidence)
            }
        }
        .padding(.vertical, 2)
        // Unticked = greyed out, never hidden: the row stays visible and can be ticked again.
        .opacity(binding.wrappedValue ? 1 : 0.45)
    }

    @ViewBuilder
    private func orderRow(_ order: PDFExtractedOrder) -> some View {
        let binding = Binding<Bool>(
            get: { allOrders.first(where: { $0.id == order.id })?.isSelected ?? false },
            set: { newValue in
                if let idx = allOrders.firstIndex(where: { $0.id == order.id }) {
                    allOrders[idx].isSelected = newValue
                }
            }
        )

        HStack(spacing: 10) {
            // Selection toggle
            Toggle(isOn: binding) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.7)
            .frame(width: 36)

            // Type icon
            Image(systemName: orderTypeIcon(order.orderType))
                .font(.title3)
                .foregroundStyle(orderTypeColor(order.orderType))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(orderTypeLabel(order.orderType))
                        .font(.subheadline).fontWeight(.medium)
                    (Text("×") + Text(order.quantity, format: .number))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(order.executedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    (Text("@ ") + Text(order.unitPrice, format: .currency(code: order.currency)))
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if order.fees > 0 {
                        (Text("+ ") + Text(order.fees, format: .currency(code: order.currency)) + Text(" frais"))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(order.totalCost, format: .currency(code: order.currency))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(order.orderType == "SELL" || order.orderType == "DIV"
                                     ? AppTheme.Colors.success : AppTheme.Colors.danger)
                // Confiance
                confidenceBadge(order.confidence)
            }
        }
        .padding(.vertical, 2)
        // Unticked = greyed out, never hidden (see `positionRow`).
        .opacity(binding.wrappedValue ? 1 : 0.45)
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: Double) -> some View {
        let (label, color): (LocalizedStringKey, Color) = {
            if confidence >= 0.85 { return ("Sûr", AppTheme.Colors.success) }
            if confidence >= 0.6 { return ("Probable", AppTheme.Colors.warning) }
            return ("Incertain", AppTheme.Colors.danger)
        }()
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Step 4: import in progress

    private var importingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Import en cours…")
                .font(.title3).fontWeight(.semibold)
            Text("Création des positions et rattachement des ordres.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
        }
    }

    // MARK: - Step 5: done

    private var doneView: some View {
        VStack(spacing: 20) {
            Spacer()

            if let result = importResult {
                Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(result.errors.isEmpty ? AppTheme.Colors.success : AppTheme.Colors.warning)

                Text("Import terminé")
                    .font(.title2).fontWeight(.bold)

                VStack(spacing: 8) {
                    summaryRow(icon: "plus.circle.fill", label: "Positions créées", value: "\(result.positionsCreated)", color: AppTheme.Colors.success)
                    summaryRow(icon: "arrow.triangle.2.circlepath", label: "Positions existantes", value: "\(result.positionsReused)", color: AppTheme.Colors.accent)
                    summaryRow(icon: "list.bullet", label: "Ordres importés", value: "\(result.ordersInserted)", color: AppTheme.Colors.accent)

                    if !result.errors.isEmpty {
                        Divider()
                        ForEach(result.errors, id: \.self) { error in
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppTheme.Colors.danger)
                                    .font(.caption)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.danger)
                            }
                        }
                    }
                }
                .padding()
                .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                // Hosted in the unified funnel: `dismiss()` would only pop this screen and
                // return to file selection.
                if let onFinished { onFinished() } else { dismiss() }
            } label: {
                Text("Fermer")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            // Without it, macOS applies the default button chrome (tinted with the
            // app's accent) on top of the already accent-colored background — the
            // white text becomes unreadable.
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func summaryRow(icon: String, label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
        }
    }

    // MARK: - Helpers UI

    private func orderTypeIcon(_ type: String) -> String {
        switch type {
        case "BUY":  return "arrow.down.circle.fill"
        case "SELL": return "arrow.up.circle.fill"
        case "DIV":  return "dollarsign.circle.fill"
        default:     return "questionmark.circle"
        }
    }

    private func orderTypeColor(_ type: String) -> Color {
        switch type {
        case "BUY":  return AppTheme.Colors.success
        case "SELL": return AppTheme.Colors.danger
        case "DIV":  return AppTheme.Colors.accentSecondary
        default:     return AppTheme.Colors.textSecondary
        }
    }

    private func orderTypeLabel(_ type: String) -> String {
        switch type {
        case "BUY":  return "Achat"
        case "SELL": return "Vente"
        case "DIV":  return "Dividende"
        default:     return type
        }
    }

    // MARK: - Summary & diagnostics

    /// Nature of the analyzed document (every unit comes from the same file).
    private var analyzedKind: ImportSourceKind {
        pageResults.first?.kind ?? .unknown
    }

    private var analyzedUnitLabel: String {
        analyzedKind.unitLabel(count: pageResults.count)
    }

    private var analyzedUnitIcon: String {
        switch analyzedKind {
        case .pdf:         return "doc.text"
        case .image:       return "photo"
        case .text:        return "tablecells"
        case .spreadsheet: return "tablecells.badge.ellipsis"
        case .xml:         return "doc.badge.gearshape"
        case .unknown:     return "questionmark.square.dashed"
        }
    }

    private var usedDeterministicFallback: Bool {
        pageResults.contains { $0.usedDeterministicFallback }
    }

    /// The most informative reason among the analyzed units: a real failure
    /// (silent OCR, AI error) wins over a plain "nothing recognized".
    private var emptyStateReason: String {
        let diagnostics = pageResults.map(\.diagnostic)
        if let hard = diagnostics.first(where: {
            if case .nothingRecognized = $0 { return false }
            if case .extracted = $0 { return false }
            return true
        }) {
            return hard.userMessage
        }
        return ImportUnitDiagnostic.nothingRecognized.userMessage
    }

    // (The text read is shown PER UNIT by the shared diagnostic block, rather
    // than concatenated and truncated for the whole document.)

    // MARK: - Actions

    private func loadAccounts() {
        accounts = repository.fetchAccounts()
        // Never overwrite an account already imposed (unified funnel).
        if selectedAccountId == nil, accounts.count == 1 {
            selectedAccountId = accounts.first?.id
        }
    }

    private func startParsing() {
        step = .parsing
        parsingError = nil
        parsingCurrent = 0
        parsingTotal = 0

        let urls = pdfURLs
        let images = pickedImages
        Task {
            // Loaded into memory (off the main thread), files AND captures: the
            // analysis path is then the same for both.
            var sources: [ImportDocumentSource] = preloadedSources
            sources += urls.compactMap { url in
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ImportDocumentSource(data: data, displayName: url.lastPathComponent)
            }
            for (index, data) in images.enumerated() {
                sources.append(ImportDocumentSource(data: data, displayName: "Capture \(index + 1)"))
            }

            // Reading (parallel) then analysis, through the unified pipeline — the same
            // one as the transaction import. A separate orchestrator for this module,
            // with its own splitting and format detection, would inevitably diverge.
            let readout = await ImportPipeline.read(sources: sources, destination: .investments)
            let batch = await ImportPipeline.analyze(readout, destination: .investments) { done, total in
                parsingCurrent = done
                parsingTotal = total
            }
            // Unit numbers are already GLOBAL (assigned by the pipeline across all
            // sources), and the orders carry them already: that's what feeds their
            // "PDF import — p.N" notes.
            await MainActor.run { finishParsing(batch) }
        }
    }

    @MainActor
    private func finishParsing(_ result: ImportBatchResult) {
        let results = result.investmentPages()
        if results.isEmpty {
            parsingError = "Impossible de lire le fichier ou aucun contenu exploitable."
            step = .selectFile
            return
        }
        batch = result
        pageResults = results
        allOrders = results.flatMap(\.orders)
        allPositions = results.flatMap(\.positions)
        step = .preview
    }

    private func performImport() {
        guard let accountId = selectedAccountId else { return }
        step = .importing

        Task.detached(priority: .userInitiated) {
            let selected = await MainActor.run { allOrders.filter(\.isSelected) }
            let selectedPositions = await MainActor.run { allPositions.filter(\.isSelected) }
            let groups = InvestmentPDFParser.aggregateByPosition(selected)
            let posSnapshots = InvestmentPDFParser.aggregatePositions(selectedPositions)
            let repo = InvestmentRepository()

            var positionsCreated = 0
            var positionsReused = 0
            var ordersInserted = 0
            var errors: [String] = []

            // Load the account's existing positions to detect duplicates
            var existingPositions = repo.fetchPositions(accountId: accountId)

            // ── Portfolio capture mode: snapshot positions ──────────────────
            // New position → creation + synthetic BUY (qty @ average cost) to
            // materialize qty/average cost (derived from orders) + current_value.
            // Existing position → current_value update (+ ISIN backfill), WITHOUT
            // touching the orders entered by the user (no silent overwrite).
            for snap in posSnapshots {
                let existing = existingPositions.first { pos in
                    if !snap.isin.isEmpty && !pos.isin.isEmpty {
                        return pos.isin.uppercased() == snap.isin.uppercased()
                    }
                    if !snap.ticker.isEmpty && !pos.ticker.isEmpty {
                        return pos.ticker.uppercased() == snap.ticker.uppercased()
                    }
                    return false
                }
                let marketValue = snap.currentValue ?? snap.investedCost

                if let existing {
                    var updated = existing
                    updated.currentValue = marketValue
                    if updated.isin.isEmpty && !snap.isin.isEmpty { updated.isin = snap.isin }
                    _ = repo.updatePosition(updated)
                    positionsReused += 1
                } else {
                    guard let newId = repo.addPositionAndGetId(
                        accountId: accountId,
                        assetType: snap.assetType,
                        assetName: snap.assetName,
                        ticker: snap.ticker,
                        isin: snap.isin,
                        purchaseDate: Date()
                    ) else {
                        errors.append("Échec création position \(snap.assetName)")
                        continue
                    }
                    // Synthetic BUY: notes prefixed "Sync " so it stays eligible for
                    // deleteSyntheticOrders (like LiveSync).
                    let key = snap.isin.isEmpty ? snap.ticker : snap.isin
                    let synthetic = InvestmentOrder(
                        id: 0,
                        positionId: newId,
                        orderType: .buy,
                        quantity: snap.quantity,
                        unitPrice: snap.averageBuyPrice,
                        fees: 0,
                        executedAt: Date(),
                        notes: "Sync Import IA (capture portefeuille)",
                        externalId: "aisnap_\(key)_\(Self.dateString(Date()))_\(snap.quantity)"
                    )
                    _ = repo.addOrder(synthetic)
                    // current_value = the capture's market value.
                    var created = InvestmentPosition(
                        id: newId, accountId: accountId,
                        assetType: snap.assetType, assetName: snap.assetName,
                        ticker: snap.ticker, isin: snap.isin,
                        quantity: snap.quantity, averageBuyPrice: snap.averageBuyPrice,
                        currentValue: marketValue, purchaseDate: Date()
                    )
                    created.currentValue = marketValue
                    _ = repo.updatePosition(created)
                    positionsCreated += 1
                    // Fed back into the local list for intra-batch deduplication.
                    existingPositions.append(created)
                }
            }

            for group in groups {
                // Look for an existing position by ISIN or ticker
                let existing = existingPositions.first { pos in
                    if !group.isin.isEmpty && !pos.isin.isEmpty {
                        return pos.isin.uppercased() == group.isin.uppercased()
                    }
                    if !group.ticker.isEmpty && !pos.ticker.isEmpty {
                        return pos.ticker.uppercased() == group.ticker.uppercased()
                    }
                    return false
                }

                let positionId: Int
                if let existing {
                    positionId = existing.id
                    positionsReused += 1
                } else {
                    // Create the position
                    guard let newId = repo.addPositionAndGetId(
                        accountId: accountId,
                        assetType: group.assetType,
                        assetName: group.assetName,
                        ticker: group.ticker,
                        isin: group.isin,
                        purchaseDate: group.orders.first?.executedAt ?? Date()
                    ) else {
                        errors.append("Échec création position \(group.assetName)")
                        continue
                    }
                    positionId = newId
                    positionsCreated += 1
                }

                // Insert the orders
                for order in group.orders {
                    guard let orderType = InvestmentOrderType(rawValue: order.orderType) else {
                        errors.append("Type inconnu \(order.orderType) pour \(order.assetName)")
                        continue
                    }

                    let investOrder = InvestmentOrder(
                        id: 0,
                        positionId: positionId,
                        orderType: orderType,
                        quantity: order.quantity,
                        unitPrice: order.unitPrice,
                        fees: order.fees,
                        executedAt: order.executedAt,
                        notes: order.notes ?? "Import PDF — p.\(order.pageNumber)",
                        externalId: "pdf_\(order.isin.isEmpty ? order.ticker : order.isin)_\(Self.dateString(order.executedAt))_\(order.quantity)"
                    )

                    if repo.addOrder(investOrder) {
                        ordersInserted += 1
                    } else {
                        // May be a duplicate (externalId already present) — not a serious error
                        print("[PDFImport] Ordre probablement déjà présent: \(order.assetName) \(order.executedAt)")
                    }
                }
            }

            let result = PDFImportResult(
                positionsCreated: positionsCreated,
                ordersInserted: ordersInserted,
                positionsReused: positionsReused,
                errors: errors
            )

            await MainActor.run {
                importResult = result
                step = .done
            }
        }
    }

    private nonisolated static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}
