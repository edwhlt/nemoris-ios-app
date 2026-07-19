import SwiftUI
import UniformTypeIdentifiers

/// Vue d'import PDF pour les ordres d'investissement.
///
/// **Flux :**
/// 1. Sélection du fichier PDF + compte cible
/// 2. Extraction texte + parsing IA page par page (progress bar)
/// 3. Preview des ordres détectés — l'user peut cocher/décocher
/// 4. Résumé par position (agrégation ISIN/ticker) + bouton Importer
/// 5. Commit en base : création positions + ordres rattachés
struct InvestmentPDFImportView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var step: ImportStep = .selectFile
    @State private var selectedAccountId: Int?
    @State private var accounts: [InvestmentAccount] = []

    // Parsing
    @State private var pageResults: [PDFPageResult] = []
    @State private var allOrders: [PDFExtractedOrder] = []
    @State private var parsingProgress: Double = 0
    @State private var parsingTotal: Int = 0
    @State private var parsingCurrent: Int = 0
    @State private var parsingError: String?

    // Import
    @State private var importResult: PDFImportResult?

    // File picker
    @State private var showFilePicker = false
    @State private var pdfURL: URL?
    @State private var pdfFileName: String = ""

    private let repository = InvestmentRepository()
    private let parser = InvestmentPDFParser.shared

    enum ImportStep {
        case selectFile
        case parsing
        case preview
        case importing
        case done
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Import intelligent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        .onAppear { loadAccounts() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                UTType.pdf,
                UTType.image, UTType.jpeg, UTType.png, UTType.heic, UTType.tiff, UTType.bmp, UTType.webP,
                UTType.commaSeparatedText, UTType.tabSeparatedText, UTType.plainText,
                UTType.data  // fallback pour tout format
            ],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            pdfURL = url
            pdfFileName = url.lastPathComponent
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
                            Text("L'import PDF utilise l'IA on-device pour comprendre les relevés de n'importe quelle banque. iOS 26+ avec Apple Intelligence activée est requis.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
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
                            Text(pdfURL != nil ? pdfFileName : "Choisir un fichier")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            if pdfURL != nil {
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
            } header: {
                Text("Fichier source")
            } footer: {
                Text("PDF, image (photo d'un relevé), CSV, texte… Le format est détecté automatiquement. L'IA analyse le contenu pour identifier les ordres.")
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
                        Label("Analyser le PDF", systemImage: "sparkles")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canStartParsing)
                .tint(AppTheme.Colors.accent)
            }
        }
    }

    private var canStartParsing: Bool {
        pdfURL != nil && selectedAccountId != nil && parser.isAIAvailable
    }

    // MARK: - Step 2 : Parsing en cours

    private var parsingView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.Colors.accent)
                .symbolEffect(.variableColor.iterative)

            Text("Analyse en cours…")
                .font(.title3).fontWeight(.semibold)

            Text("L'IA analyse le document pour identifier les ordres d'investissement.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                ProgressView(value: parsingProgress)
                    .tint(AppTheme.Colors.accent)
                    .padding(.horizontal, 40)

                Text("Page \(parsingCurrent) / \(parsingTotal)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if let error = parsingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }

    // MARK: - Step 3 : Preview des ordres

    private var previewView: some View {
        List {
            // Résumé
            Section {
                HStack {
                    Label("\(allOrders.count) ordres détectés", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text("\(allOrders.filter(\.isSelected).count) sélectionnés")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                HStack {
                    Label("\(pageResults.count) pages analysées", systemImage: "doc.text")
                    Spacer()
                    let withOrders = pageResults.filter { !$0.orders.isEmpty }.count
                    Text("\(withOrders) avec ordres")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Résumé")
            }

            if allOrders.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("Aucun ordre détecté")
                            .font(.headline)
                        Text("Le PDF ne semble pas contenir d'ordres d'investissement reconnaissables, ou le format n'a pas pu être interprété.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                // Ordres groupés par position
                let groups = InvestmentPDFParser.aggregateByPosition(allOrders)

                Section {
                    Text("\(groups.count) position(s) identifiée(s)")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: {
                    Text("Positions")
                }

                ForEach(groups) { group in
                    Section {
                        // En-tête position
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

                        // Ordres de cette position
                        ForEach(group.orders) { order in
                            orderRow(order)
                        }
                    }
                }

                // Bouton importer
                Section {
                    Button {
                        performImport()
                    } label: {
                        HStack {
                            Spacer()
                            let selectedCount = allOrders.filter(\.isSelected).count
                            Label("Importer \(selectedCount) ordre(s)", systemImage: "square.and.arrow.down.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(allOrders.filter(\.isSelected).isEmpty)
                    .tint(AppTheme.Colors.accent)
                }
            }
        }
        .listStyle(.insetGrouped)
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
                    Text("×\(order.quantity.formatted())")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(order.executedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("@ \(order.unitPrice.formatted(.currency(code: order.currency)))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if order.fees > 0 {
                        Text("+ \(order.fees.formatted(.currency(code: order.currency))) frais")
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
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: Double) -> some View {
        let (label, color): (String, Color) = {
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
                dismiss()
            } label: {
                Text("Fermer")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func summaryRow(icon: String, label: String, value: String, color: Color) -> some View {
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

    // MARK: - Actions

    private func loadAccounts() {
        accounts = repository.fetchAccounts()
        if accounts.count == 1 { selectedAccountId = accounts.first?.id }
    }

    private func startParsing() {
        guard let url = pdfURL else { return }
        step = .parsing
        parsingError = nil

        let hasAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            // Point d'entrée universel — détecte PDF, image, CSV, texte automatiquement
            let results = await parser.parseFile(from: url) { current, total in
                Task { @MainActor in
                    parsingCurrent = current
                    parsingTotal = total
                    parsingProgress = total > 0 ? Double(current) / Double(total) : 0
                }
            }

            if results.isEmpty {
                parsingError = "Impossible de lire le fichier ou aucun texte exploitable."
                return
            }

            pageResults = results
            allOrders = results.flatMap(\.orders)
            step = .preview
        }
    }

    private func performImport() {
        guard let accountId = selectedAccountId else { return }
        step = .importing

        Task.detached(priority: .userInitiated) {
            let selected = await MainActor.run { allOrders.filter(\.isSelected) }
            let groups = InvestmentPDFParser.aggregateByPosition(selected)
            let repo = InvestmentRepository()

            var positionsCreated = 0
            var positionsReused = 0
            var ordersInserted = 0
            var errors: [String] = []

            // Charger les positions existantes du compte pour détecter les doublons
            let existingPositions = repo.fetchPositions(accountId: accountId)

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
