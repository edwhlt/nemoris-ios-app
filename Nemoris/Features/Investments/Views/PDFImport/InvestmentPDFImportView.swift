import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Vue d'import intelligent (PDF, image/screenshot, CSV) pour les investissements.
///
/// **Flux :**
/// 1. Sélection du fichier OU d'une capture (photothèque) + compte cible
/// 2. Extraction texte (PDFKit / Vision OCR) + parsing IA page par page (progress bar)
/// 3. Preview des ordres OU positions détectés — l'utilisateur peut cocher/décocher
/// 4. Résumé + bouton Importer
/// 5. Commit en base : création positions + ordres (BUY synthétique en mode snapshot)
struct InvestmentPDFImportView: View {

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    // MARK: - State

    @State private var step: ImportStep = .selectFile
    @State private var selectedAccountId: Int?
    @State private var accounts: [InvestmentAccount] = []

    // Parsing
    @State private var pageResults: [PDFPageResult] = []
    /// Sortie brute du pipeline, conservée pour le détail par source et son
    /// inspection JSON. `pageResults` en est une projection : on garde
    /// l'original plutôt que de tenter de reconstruire l'origine des éléments
    /// à partir de la projection.
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
    @State private var pdfURLs: [URL] = []

    // Chantier C — captures depuis la photothèque (screenshots de PEA/CTO).
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickedImages: [Data] = []
    /// Documents fournis par l'entonnoir unifié (déjà chargés en mémoire).
    @State private var preloadedSources: [ImportDocumentSource] = []

    private let repository = InvestmentRepository()
    private let parser = InvestmentPDFParser.shared

    /// Repli proposé quand Apple Intelligence n'est pas disponible : bascule
    /// vers l'import CSV déterministe (mapping de colonnes, sans IA). nil =
    /// aucun repli proposé.
    private let onFallbackToCSV: (() -> Void)?

    /// Init standard (ouverture depuis le menu ⋯).
    init(onFallbackToCSV: (() -> Void)? = nil) {
        self.onFallbackToCSV = onFallbackToCSV
        self.onFinished = nil
    }

    /// Chantier D — init pré-rempli avec les fichiers déposés par un raccourci
    /// Siri ou la share extension. L'utilisateur choisit le compte cible puis
    /// lance l'analyse (aucun import automatique).
    init(preloadedFileURLs urls: [URL], onFallbackToCSV: (() -> Void)? = nil) {
        _pdfURLs = State(initialValue: urls)
        self.onFallbackToCSV = onFallbackToCSV
        self.onFinished = nil
    }

    /// Entrée depuis l'entonnoir d'import unifié (`ImportEntryView`) : la
    /// destination, le compte cible et les documents sont DÉJÀ choisis, on
    /// démarre donc directement sur l'analyse. `onFinished` ferme tout
    /// l'entonnoir — sans lui, « Terminer » ne dépilerait que cet écran et
    /// ramènerait sur la sélection de fichiers.
    init(preloadedSources sources: [ImportDocumentSource],
         accountId: Int,
         onFinished: @escaping () -> Void) {
        _preloadedSources = State(initialValue: sources)
        _selectedAccountId = State(initialValue: accountId)
        _step = State(initialValue: .parsing)
        self.onFallbackToCSV = nil
        self.onFinished = onFinished
    }

    /// Résultat d'une analyse déjà faite en ARRIÈRE-PLAN par
    /// `DocumentImportCoordinator` : on ouvre directement la relecture. C'est
    /// ce qui permet à l'utilisateur de fermer l'import pendant l'analyse et de
    /// revenir dessus par le bandeau sans rien reperdre.
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

    /// Fermeture de l'entonnoir parent, quand cette vue y est hébergée.
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
        // Entrée par l'entonnoir unifié : documents et compte sont déjà
        // choisis, l'analyse démarre seule (aucun bouton intermédiaire).
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
                UTType.data  // fallback pour tout format
            ],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            pdfURLs = urls
        }
        // Chantier C — chargement des captures choisies dans la photothèque.
        // Fichiers et captures se CUMULENT désormais (un relevé PDF plus une
        // capture de la même appli sont deux vues complémentaires du même
        // portefeuille) : la déduplication par ISIN/ticker de `aggregatePositions`
        // absorbe les recouvrements.
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

    // MARK: - Step 1 : Sélection fichier + compte

    private var selectFileView: some View {
        Form {
            // IA disponibilité
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

                    // Repli sans IA : l'import CSV déterministe (mapping de
                    // colonnes) reste pleinement disponible — offline-first.
                    if let onFallbackToCSV {
                        Button {
                            dismiss()
                            // Laisse la sheet se fermer avant d'en présenter une autre.
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

                // Chantier C — capture depuis la photothèque (screenshot d'app PEA/CTO).
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(AppTheme.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(imageSelectionLabel)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(pickedImages.isEmpty ? "Depuis la photothèque" : "Toucher pour changer")
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
                    Picker("Compte cible", selection: $selectedAccountId) {
                        Text("Sélectionner…").tag(nil as Int?)
                        ForEach(accounts) { account in
                            Text("\(account.name) (\(account.broker))")
                                .tag(account.id as Int?)
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

    // MARK: - Step 2 : Parsing en cours

    /// Même écran de traitement que l'import de transactions
    /// (`DocumentAnalysisProgressSection`) : barre déterminée dès que le nombre
    /// d'unités est connu, et vocabulaire neutre — « Page X / Y » n'avait aucun
    /// sens pour une capture d'écran ou un CSV.
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

    // MARK: - Step 3 : Preview des ordres

    private var previewView: some View {
        // Form (pas List) : review type formulaire → boxes arrondies natives
        // macOS via nemorisFormStyle(), insetGrouped natif sur iOS.
        Form {
            // Résumé
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
                    // Vocabulaire adapté au format réel : « page » n'a de sens
                    // que pour un PDF depuis que l'import accepte captures,
                    // images et CSV.
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
                        // Raison PRÉCISE plutôt qu'un message unique : sans
                        // elle, impossible de distinguer un OCR muet, une IA
                        // indisponible, une IA en échec et un document
                        // réellement sans opération.
                        Text(emptyStateReason)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                // Détail PAR UNITÉ (même bloc que l'import de transactions) :
                // pourquoi chacune n'a rien donné, et le texte réellement lu.
                ImportSourceBreakdownSection(
                    summaries: batch.perSource(),
                    noun: "ligne",
                    debugJSON: { batch.debugJSON(sourceIndex: $0.sourceIndex) })
                DocumentAnalysisDiagnosticsSection(
                    units: pageResults.map { $0.analysisUnit(sourceName: $0.sourceName) })
            } else {
                // Mode capture de portefeuille — positions détectées
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

                // Mode ordres — groupés par position
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

                // Même quand des lignes ont été trouvées, les unités en échec
                // restent listées : sur un PDF de plusieurs pages, certaines
                // peuvent n'avoir rien donné sans que ce soit visible.
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

    /// Row de preview d'une position détectée (mode snapshot) avec toggle sélection.
    @ViewBuilder
    private func positionRow(_ position: PDFExtractedPosition) -> some View {
        // ⚠️ La row affichée est AGRÉGÉE : elle peut fusionner plusieurs lignes
        // brutes venues de pages ou de captures différentes. Le toggle doit
        // donc porter sur TOUT le groupe — matcher sur le seul `id` ne
        // décochait que la première ligne brute, et les autres étaient
        // importées quand même.
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
        // Décoché = grisé, jamais masqué : la ligne reste visible et re-cochable.
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
            // Toggle sélection
            Toggle(isOn: binding) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.7)
            .frame(width: 36)

            // Icône type
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
        // Décoché = grisé, jamais masqué (cf. `positionRow`).
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

    // MARK: - Step 4 : Import en cours

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

    // MARK: - Step 5 : Terminé

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
                // Hébergée dans l'entonnoir unifié : `dismiss()` ne dépilerait
                // que cet écran et ramènerait sur la sélection de fichiers.
                if let onFinished { onFinished() } else { dismiss() }
            } label: {
                Text("Fermer")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            // Sans ça, macOS applique le chrome de bouton par défaut (teinté
            // par l'accent de l'app) par-dessus le fond déjà accent — le
            // texte blanc devient illisible (même bug que `SettingsView`
            // "Passer Pro" / `ReferenceDataView.accountRow`).
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

    // MARK: - Résumé & diagnostic

    /// Nature du document analysé (toutes les unités viennent du même fichier).
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

    /// Raison la plus informative parmi les unités analysées : un vrai échec
    /// (OCR muet, IA en erreur) prime sur un simple « rien de reconnu ».
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

    // (Le texte lu est désormais affiché PAR UNITÉ par le bloc de diagnostic
    // partagé, plutôt que concaténé et tronqué pour tout le document.)

    // MARK: - Actions

    private func loadAccounts() {
        accounts = repository.fetchAccounts()
        // Ne jamais écraser un compte déjà imposé (entonnoir unifié).
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
            // Chargement en mémoire (hors main thread), fichiers ET captures :
            // le parcours d'analyse est ensuite le même pour les deux.
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

            // Lecture (parallèle) puis analyse, par le pipeline unifié — le
            // même que l'import de transactions. Ce module avait son propre
            // orchestrateur, avec son propre découpage et sa propre détection
            // de format : deux copies qui ont fini par diverger.
            let readout = await ImportPipeline.read(sources: sources, destination: .investments)
            let batch = await ImportPipeline.analyze(readout, destination: .investments) { done, total in
                parsingCurrent = done
                parsingTotal = total
            }
            // Les numéros d'unité sont déjà GLOBAUX (attribués par le pipeline
            // sur l'ensemble des sources), et les ordres les portent déjà :
            // c'est ce qui alimente leurs notes « Import PDF — p.N ».
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

            // Charger les positions existantes du compte pour détecter les doublons
            var existingPositions = repo.fetchPositions(accountId: accountId)

            // ── Mode capture de portefeuille : positions snapshot ────────────
            // Nouvelle position → création + BUY synthétique (qty @ PRU) pour
            // matérialiser qty/PRU (dérivés des ordres depuis v30) + current_value.
            // Position existante → maj current_value (+ backfill ISIN), SANS
            // toucher aux ordres saisis par l'utilisateur (pas d'écrasement silencieux).
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
                    // BUY synthétique : notes préfixées "Sync " pour rester
                    // éligible à deleteSyntheticOrders (comme LiveSync).
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
                    // current_value = valeur de marché de la capture.
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
                    // Réinjecte dans la liste locale pour dédupe intra-batch.
                    existingPositions.append(created)
                }
            }

            for group in groups {
                // Chercher une position existante par ISIN ou ticker
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
                    // Créer la position
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

                // Insérer les ordres
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
                        // Peut être un doublon (externalId déjà présent) — pas une erreur grave
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
