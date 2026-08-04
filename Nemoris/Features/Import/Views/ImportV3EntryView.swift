import SwiftUI
import UniformTypeIdentifiers

/// Point d'entrée du parcours d'import de transactions (AXE D, étendu).
///
/// Flux :
///   1. Sélection du compte cible + sélection d'UN OU PLUSIEURS fichiers.
///   2. Chaque fichier est routé selon son type RÉEL (sniffé sur les octets) :
///      • CSV / texte tabulaire → mapping des colonnes, réutilisé sans écran
///        quand la signature du header est déjà connue ;
///      • PDF / capture d'écran / texte non tabulaire → extraction par
///        `TransactionDocumentParser` (déterministe + IA).
///   3. Les lignes de TOUS les fichiers sont agrégées en UNE session d'import.
///
/// ⚠️ Le type ne se déduit JAMAIS de l'extension : un fichier partagé arrive
/// nommé `<uuid>.dat`, et un décodage Latin-1 d'un PNG « réussit » toujours en
/// produisant des centaines de milliers de caractères de binaire (classe de bug
/// documentée dans `InvestmentPDFParser.detectKind`).
struct ImportV3EntryView: View {
    // Vue présentée dans des contextes MIXTES : pushée (sidebar macOS, MoreView,
    // Settings) OU pane adaptatif (Dashboard, import préchargé AXE P). La
    // fermeture appelle les DEUX mécanismes — chacun est no-op hors de son
    // contexte (paneDismiss par défaut = {}, DismissAction sans présentation = rien).
    @Environment(\.dismiss) private var navDismiss
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    #if os(macOS)
    @Environment(\.paneHostContext) private var paneHostContext
    #endif

    /// Fermeture universelle (cf. commentaire sur les environnements).
    private func dismiss() {
        paneDismiss()
        navDismiss()
    }

    /// AXE P — fichiers déjà déposés dans `PendingImportInbox` (raccourci Siri
    /// ou share extension). Affichés comme "Fichier(s) reçu(s)" : l'utilisateur
    /// confirme le compte cible puis continue — pas de picker à rouvrir.
    var preloadedFileURLs: [URL] = []

    /// `true` quand la vue est POUSSÉE dans un `NavigationStack` parent (MoreView,
    /// Réglages, recherche, sidebar macOS) → on NE ré-enveloppe PAS dans un stack.
    /// `false` (défaut) = présentée en sheet (Dashboard / import préchargé) → elle
    /// fournit son propre `NavigationStack`. Un stack imbriqué faisait "sauter" la
    /// vue au 1er affichage (elle se refermait, puis OK au 2ᵉ tap).
    var isEmbedded: Bool = false

    @State private var accounts: [Account] = []
    @State private var selectedAccountId: Int? = nil
    @State private var showFilePicker = false
    @State private var parseError: String?

    @State private var existingActiveSession: ImportSessionSummary?
    @State private var showResumeAlert = false
    @State private var isParsing = false

    /// Un CSV dont le format n'est pas encore connu : il faudra afficher
    /// l'écran de mapping. Les formats déjà mémorisés n'arrivent jamais ici.
    private struct PendingCSV: Identifiable {
        let id = UUID()
        let parsed: CSVParserV3.Parsed
        let name: String
    }

    /// Lignes déjà produites par les fichiers traités — agrégées jusqu'à la
    /// création d'UNE session unique.
    @State private var aggregatedRows: [ImportSessionRow] = []
    @State private var pendingMappings: [PendingCSV] = []
    /// Index du mapping affiché. On AVANCE un curseur, on ne retire jamais
    /// d'élément de `pendingMappings` pendant le parcours :
    ///
    /// ⚠️ Retirer l'élément courant depuis le callback de l'écran poussé (ce
    /// que faisait `removeFirst()`) vide le contenu de la `navigationDestination`
    /// PENDANT qu'elle est encore à l'écran — la destination s'évalue alors à
    /// `EmptyView` dans le même cycle de rendu que la dépile, la fermeture de
    /// la feuille et la présentation de la feuille de session. C'est la cause
    /// du crash constaté à l'import d'un CSV.
    @State private var mappingIndex: Int = 0
    @State private var documentSources: [TransactionDocumentParser.DocumentSource] = []
    /// Noms de tous les fichiers retenus, pour le libellé de la session.
    @State private var handledFileNames: [String] = []
    /// Étape poussée courante. UNE seule `navigationDestination` pilotée par
    /// cette valeur : deux destinations concurrentes qu'on bascule dans le même
    /// cycle de rendu produisent des transitions incohérentes. L'index du
    /// mapping est porté PAR l'étape, pour que le contenu poussé reste toujours
    /// valide (cf. `mappingIndex`).
    @State private var step: Step? = nil

    private enum Step: Hashable {
        case documents
        case mapping(index: Int)
    }

    private let repository = TransactionRepository()
    private let sessionRepo = ImportSessionRepository()

    var body: some View {
        if isEmbedded {
            formContent
        } else {
            NavigationStack { formContent }
        }
    }

    @ViewBuilder private var formContent: some View {
            Form {
                Section("Compte cible") {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible — créez-en un d'abord.")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Picker("Compte", selection: $selectedAccountId) {
                            Text("Choisir…").tag(Int?.none)
                            ForEach(accounts) { a in
                                Text(a.name).tag(Int?.some(a.id))
                            }
                        }
                    }
                }

                Section("Fichiers") {
                    if !preloadedFileURLs.isEmpty {
                        // AXE P — fichiers déjà reçus (partage / raccourci) :
                        // confirmation du compte puis continuation directe.
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
                        .disabled(selectedAccountId == nil || isParsing)

                        Button("Choisir d'autres fichiers") {
                            showFilePicker = true
                        }
                        .disabled(selectedAccountId == nil || isParsing)
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            if isParsing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Analyse en cours…")
                                }
                            } else {
                                Label("Choisir un ou plusieurs fichiers", systemImage: "doc.badge.plus")
                            }
                        }
                        .disabled(selectedAccountId == nil || isParsing)
                    }

                    if let parseError {
                        Text(parseError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }

                Section {
                    Text("CSV, PDF ou capture d'écran. Pour un CSV, vous mapperez les colonnes (date / montant / libellé) — le mapping est mémorisé pour les prochains imports du même format. Un PDF ou une capture est analysé automatiquement.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: { Text("À savoir") }
            }
            .nemorisFormStyle()
            .navigationTitle("Importer des transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Poussée (module direct, sidebar/MoreView/Settings) : le bouton
                // retour du stack parent suffit. En sheet iOS OU panneau macOS
                // (adaptivePane) : on fournit "Annuler" — publié dans la barre
                // système sur macOS via `paneHostContext == .inspector` (pas de
                // `.toolbar` natif qui remonterait dans la barre du module),
                // rendu natif ici sinon.
                #if os(macOS)
                if !isEmbedded, paneHostContext != .inspector {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { dismiss() }
                    }
                }
                #else
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { dismiss() }
                    }
                }
                #endif
            }
            #if os(macOS)
            .modifier(ImportEntryInspectorChrome(isEmbedded: isEmbedded, dismiss: dismiss))
            #endif
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .utf8PlainText,
                                      .text, .pdf, .image, .png, .jpeg, .heic, .data, .item],
                allowsMultipleSelection: true
            ) { result in
                handleFileResult(result)
            }
            .navigationDestination(item: $step) { current in
                switch current {
                case .documents:
                    TransactionDocumentParseView(
                        sources: documentSources,
                        startingRowNumber: aggregatedRows.count + 1
                    ) { rows in
                        aggregatedRows.append(contentsOf: rows)
                        documentSources = []
                        advance()
                    }
                case .mapping(let index):
                    // L'index vient de l'étape : `pendingMappings` n'est jamais
                    // mutée en cours de parcours, donc ce contenu reste valide
                    // tant que l'écran est poussé.
                    if index < pendingMappings.count, let accountId = selectedAccountId {
                        let pending = pendingMappings[index]
                        ColumnMappingView(
                            parsed: pending.parsed,
                            accountId: accountId,
                            sourceFile: pending.name,
                            onRowsReady: { rows in
                                aggregatedRows.append(contentsOf: rows)
                                mappingIndex = index + 1
                                advance()
                            },
                            startingRowNumber: aggregatedRows.count + 1
                        )
                        // Identité liée au fichier : sans ça, l'écran suivant
                        // réutiliserait l'état @State du mapping précédent
                        // (colonnes du fichier d'avant, pré-sélectionnées).
                        .id(pending.id)
                    }
                }
            }
            .alert("Une session d'import est déjà en cours",
                   isPresented: $showResumeAlert, presenting: existingActiveSession) { _ in
                Button("Reprendre") {
                    appState.showImportSessionSheet = true
                    dismiss()
                }
                Button("Annuler la précédente", role: .destructive) {
                    if let id = existingActiveSession?.id {
                        sessionRepo.deleteSession(id: id)
                        ImportNotificationService.cancelReminder(forSessionId: id)
                        appState.reloadActiveImportSession()
                        existingActiveSession = nil
                    }
                }
                Button("Fermer", role: .cancel) { dismiss() }
            } message: { _ in
                Text("Vous devez d'abord la terminer ou l'annuler avant d'en démarrer une nouvelle.")
            }
            .task { loadInitialState() }
    }

    // MARK: - Logic

    private func loadInitialState() {
        accounts = repository.fetchAccounts()
        if selectedAccountId == nil {
            let preferred = appState.defaultAccountId > 0 ? appState.defaultAccountId : (appState.selectedAccountId ?? 0)
            selectedAccountId = accounts.first(where: { $0.id == preferred })?.id ?? accounts.first?.id
        }
        if let active = sessionRepo.fetchActiveSummary() {
            existingActiveSession = active
            showResumeAlert = true
        }
    }

    /// `sharedNaming` (AXE P) : les fichiers de l'inbox ont des noms UUID
    /// opaques — on leur substitue un nom lisible pour l'affichage et pour le
    /// `source_file` de la session.
    private func handleFileResult(_ result: Result<[URL], Error>, sharedNaming: Bool = false) {
        parseError = nil
        switch result {
        case .failure(let err):
            parseError = err.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            resetPipeline()
            isParsing = true
            Task {
                // Lecture hors du main thread : sur N fichiers, la charger sur
                // le thread principal fige l'UI pendant tout l'import.
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

    /// Route chaque fichier vers le bon parcours d'après son type RÉEL, et
    /// consomme immédiatement les CSV dont le format est déjà mémorisé.
    private func classify(_ files: [(data: Data, name: String)]) async {
        var directRows: [ImportSessionRow] = []
        var mappings: [PendingCSV] = []
        var documents: [TransactionDocumentParser.DocumentSource] = []
        var names: [String] = []

        for file in files {
            names.append(file.name)
            let ext = (file.name as NSString).pathExtension
            let kind = InvestmentPDFParser.detectKind(data: file.data, fileExtension: ext)

            guard kind == .text else {
                // PDF, capture, ou contenu non textuel : extraction documentaire.
                documents.append(.init(data: file.data, displayName: file.name))
                continue
            }

            let content = Self.decodeText(from: file.data)
            let parsed = await Task.detached(priority: .userInitiated) {
                CSVParserV3.parse(content: content)
            }.value

            // Un texte qui n'a pas de structure tabulaire (relevé .txt, export
            // en prose) n'est pas un CSV : l'envoyer au mapping de colonnes
            // demanderait à l'utilisateur de mapper des colonnes inexistantes.
            guard let parsed, !parsed.rows.isEmpty, parsed.headers.count >= 2 else {
                documents.append(.init(data: file.data, displayName: file.name))
                continue
            }

            let signature = ColumnMappingSignature.compute(headers: parsed.headers)
            if let known = sessionRepo.findMapping(headerSignature: signature) {
                // Format déjà rencontré : aucun écran de mapping à afficher.
                let (rows, _) = CSVParserV3.buildRows(
                    parsed: parsed, mapping: known,
                    startingAt: directRows.count + 1,
                    sourceFile: files.count > 1 ? file.name : nil
                )
                directRows.append(contentsOf: rows)
            } else {
                mappings.append(PendingCSV(parsed: parsed, name: file.name))
            }
        }

        await MainActor.run {
            isParsing = false
            aggregatedRows = directRows
            pendingMappings = mappings
            mappingIndex = 0
            documentSources = documents
            handledFileNames = names
            advance()
        }
    }

    /// Étape suivante : documents d'abord (ils ont un écran de revue), puis les
    /// mappings de colonnes un par un, puis création de la session.
    private func advance() {
        if !documentSources.isEmpty {
            step = .documents
            return
        }
        if mappingIndex < pendingMappings.count {
            step = .mapping(index: mappingIndex)
            return
        }
        // Fin du parcours. On dépile D'ABORD, et la création de session (qui
        // ferme cette feuille et en présente une autre) attend le cycle de
        // rendu suivant : dépiler, fermer et présenter dans le même cycle fait
        // crasher SwiftUI.
        step = nil
        Task { @MainActor in finalize() }
    }

    /// Crée UNE session pour l'ensemble des fichiers traités.
    private func finalize() {
        guard let accountId = selectedAccountId else { return }
        guard !aggregatedRows.isEmpty else {
            parseError = "Aucune opération exploitable dans le ou les fichiers sélectionnés."
            return
        }
        guard let summary = sessionRepo.createSession(rows: aggregatedRows,
                                                      accountId: accountId,
                                                      sourceFile: sessionLabel()) else {
            parseError = "Échec de la sauvegarde de la session."
            return
        }
        appState.activeImportSession = summary
        appState.showImportSessionSheet = true
        dismiss()
    }

    /// Libellé de la session : le premier fichier, suivi du nombre d'autres.
    private func sessionLabel() -> String? {
        guard let first = handledFileNames.first else { return nil }
        return handledFileNames.count > 1 ? "\(first) +\(handledFileNames.count - 1)" : first
    }

    private func resetPipeline() {
        aggregatedRows = []
        pendingMappings = []
        mappingIndex = 0
        documentSources = []
        handledFileNames = []
        step = nil
    }

    /// Décodage permissif (BOM UTF-8, UTF-16, Windows-1252, ISO Latin-1).
    /// `nonisolated static` pour pouvoir être appelée depuis `Task.detached`.
    nonisolated static func decodeText(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return ""
    }
}

#if os(macOS)
/// Publie "Annuler" dans la barre système macOS UNIQUEMENT quand ce contenu est
/// réellement hébergé dans le panneau (adaptivePane niveau 1, `!isEmbedded`).
/// Poussé en module direct (sidebar/MoreView) ou en sheet niveau 2 → no-op (le
/// `.toolbar` conditionnel du body gère déjà ces cas).
private struct ImportEntryInspectorChrome: ViewModifier {
    let isEmbedded: Bool
    let dismiss: () -> Void
    @Environment(\.paneHostContext) private var host

    func body(content: Content) -> some View {
        if !isEmbedded, host == .inspector {
            content.publishesInspectorChrome {
                PaneChromeModel(title: "Importer un CSV",
                                leading: PaneBarButton(label: "Annuler", action: dismiss),
                                trailing: [])
            }
        } else {
            content
        }
    }
}
#endif
