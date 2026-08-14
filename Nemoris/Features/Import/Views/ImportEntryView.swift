import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Point d'entrée du parcours d'import de transactions.
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
struct ImportEntryView: View {
    // Vue présentée dans des contextes MIXTES : pushée (sidebar macOS, MoreView,
    // Settings) OU pane adaptatif (Dashboard, import préchargé). La
    // fermeture appelle les DEUX mécanismes — chacun est no-op hors de son
    // contexte (paneDismiss par défaut = {}, DismissAction sans présentation = rien).
    @Environment(\.dismiss) private var navDismiss
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState
    @Environment(\.paneHostContext) private var paneHostContext

    /// Fermeture : EXACTEMENT un mécanisme, jamais les deux.
    ///
    /// ⚠️ Appeler `paneDismiss()` PUIS `navDismiss()` — ce que faisait la
    /// version « universelle » — ferme d'abord le panneau, après quoi le
    /// `DismissAction` n'a plus rien à fermer. Sur macOS il remonte alors à la
    /// fenêtre et **la ferme** : l'app disparaissait dans le Dock alors que le
    /// process (et l'analyse en cours) continuaient de tourner. Le commentaire
    /// d'origine supposait un no-op « hors de son contexte » ; c'est vrai du
    /// `paneDismiss` (défaut `{}`), pas du `DismissAction`.
    private func dismiss() {
        if !isEmbedded, paneHostContext != .root {
            paneDismiss()   // hébergée par `.adaptivePane` (sheet iOS / inspecteur macOS)
            return
        }
        #if os(macOS)
        // Embarquée dans la sidebar ou les Réglages : sur Mac ces deux hôtes
        // affichent le contenu par bascule d'ÉTAT, sans rien empiler — il n'y a
        // donc AUCUNE présentation à fermer, et un `DismissAction` qui n'en
        // trouve pas ferme la fenêtre (l'app repartait dans le Dock).
        if isEmbedded { return }
        #endif
        navDismiss()        // poussée dans le `NavigationStack` d'un parent
    }

    /// fichiers déjà déposés dans `PendingImportInbox` (raccourci Siri
    /// ou share extension). Affichés comme "Fichier(s) reçu(s)" : l'utilisateur
    /// confirme le compte cible puis continue — pas de picker à rouvrir.
    var preloadedFileURLs: [URL] = []

    /// Destination PRÉ-REMPLIE par le point d'entrée (Dashboard/Réglages →
    /// transactions, module Investissements → investissements). Modifiable dans
    /// l'écran : c'est un seul entonnoir pour les deux cas d'usage.
    var initialDestination: ImportDestination = .transactions

    /// `true` quand la vue est POUSSÉE dans un `NavigationStack` parent (MoreView,
    /// Réglages, recherche, sidebar macOS) → on NE ré-enveloppe PAS dans un stack.
    /// `false` (défaut) = présentée en sheet (Dashboard / import préchargé) → elle
    /// fournit son propre `NavigationStack`. Un stack imbriqué faisait "sauter" la
    /// vue au 1er affichage (elle se refermait, puis OK au 2ᵉ tap).
    var isEmbedded: Bool = false

    @State private var destination: ImportDestination?
    @State private var accounts: [Account] = []
    @State private var investmentAccounts: [InvestmentAccount] = []
    @State private var selectedAccountId: Int? = nil
    @State private var selectedInvestmentAccountId: Int? = nil
    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var parseError: String?
    /// Documents choisis mais PAS encore traités : la sélection s'accumule
    /// (fichiers et captures, en plusieurs fois) et rien ne démarre avant que
    /// l'utilisateur ne valide.
    @State private var stagedFiles: [(data: Data, name: String)] = []

    @State private var existingActiveSession: ImportSessionSummary?
    @State private var showResumeAlert = false
    @State private var isParsing = false

    /// ⚠️ Les lignes accumulées ne vivent PLUS ici : elles appartiennent à
    /// `DocumentImportCoordinator`. Cet écran traverse plusieurs étapes (un
    /// mapping par table, puis l'analyse des documents) et se ferme avant la fin
    /// du job — un `@State` local rendait la fusion dépendante de sa survie, et
    /// toutes les sources ne se retrouvaient pas dans l'import final.
    private var coordinator: DocumentImportCoordinator { .shared }
    /// Tables en attente de mapping, rendues par la phase de LECTURE du
    /// pipeline. CSV et feuilles de classeur y arrivent indifféremment : les
    /// deux posent la même question (quelle colonne est quoi).
    @State private var pendingMappings: [ImportPipeline.PendingGrid] = []
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
    /// Unités NON tabulaires (pages PDF, captures, relevés structurés) : elles
    /// partent à l'analyse de fond, sans interaction.
    @State private var pendingReadout = ImportPipeline.Readout()
    /// Noms de tous les fichiers retenus, pour le libellé de la session.
    @State private var handledFileNames: [String] = []
    /// Étape poussée courante. UNE seule `navigationDestination` pilotée par
    /// cette valeur : deux destinations concurrentes qu'on bascule dans le même
    /// cycle de rendu produisent des transitions incohérentes. L'index du
    /// mapping est porté PAR l'étape, pour que le contenu poussé reste toujours
    /// valide (cf. `mappingIndex`).
    @State private var step: Step? = nil

    /// Seule étape POUSSÉE restante : le mapping de colonnes, qui a besoin de
    /// l'utilisateur. L'analyse des documents, elle, part en arrière-plan — ce
    /// qui supprime au passage un écran poussé de plus sur macOS.
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

    /// ⚠️ macOS : ZÉRO PUSH. Cette vue est hébergée dans l'inspecteur, et y
    /// empiler un écran est le motif à risque documenté (§N.1 : panneau peint
    /// sous le contenu poussé, gels et crashs AutoLayout). Depuis que l'étape
    /// de mapping est TOUJOURS affichée — et non plus sautée quand le format
    /// était connu — ce push se produisait à chaque import CSV et gelait la
    /// fenêtre. Le mapping remplace donc le contenu DANS la même vue, et la
    /// `NavigationStack` du module reste à sa racine.
    /// iOS garde le push, qui y est natif et sans danger.
    @ViewBuilder private var stepContent: some View {
        #if os(macOS)
        if case .mapping(let index) = step,
           index < pendingMappings.count,
           let accountId = selectedAccountId {
            mappingView(index: index, accountId: accountId)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { step = nil } label: {
                            Label("Retour", systemImage: "chevron.left")
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

    /// Écran de mapping d'un fichier, partagé par les deux plateformes
    /// (poussé sur iOS, substitué sur macOS).
    @ViewBuilder
    private func mappingView(index: Int, accountId: Int) -> some View {
        let pending = pendingMappings[index]
        ColumnMappingView(
            parsed: pending.grid,
            // `nil` pour un classeur : ses cellules ne dépendent d'aucun
            // séparateur, l'écran masque donc le sélecteur.
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
        // Identité liée au fichier : sans ça, l'écran suivant réutiliserait
        // l'état @State du mapping précédent (colonnes du fichier d'avant,
        // pré-sélectionnées).
        .id(pending.id)
    }

    @ViewBuilder private var formContent: some View {
            Form {
                Section {
                    Picker("Destination", selection: Binding(
                        get: { destination ?? initialDestination },
                        set: { newValue in destination = newValue }
                    )) {
                        ForEach(ImportDestination.allCases) { dest in
                            Label(dest.displayName, systemImage: dest.icon)
                                .tag(dest)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Destination")
                } footer: {
                    Text(activeDestination.hint)
                }

                Section("Compte cible") {
                    if activeDestination == .transactions {
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
                    } else {
                        if investmentAccounts.isEmpty {
                            Text("Aucun compte d'investissement — créez-en un d'abord.")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            Picker("Compte", selection: $selectedInvestmentAccountId) {
                                Text("Choisir…").tag(Int?.none)
                                ForEach(investmentAccounts) { a in
                                    Text("\(a.name) (\(a.broker))").tag(Int?.some(a.id))
                                }
                            }
                        }
                    }
                }

                Section("Fichiers") {
                    if !preloadedFileURLs.isEmpty {
                        // fichiers déjà reçus (partage / raccourci) :
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
                        .disabled(!hasTargetAccount || isParsing)

                        Button("Choisir d'autres fichiers") {
                            showFilePicker = true
                        }
                        .disabled(!hasTargetAccount || isParsing)
                    } else {
                        // Les sélections s'ACCUMULENT. Rien ne démarre tant que
                        // l'utilisateur n'a pas cliqué « Importer » : il peut
                        // ajouter des fichiers et des captures en plusieurs
                        // fois, ce qu'un lancement automatique à la sélection
                        // rendait impossible.
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Ajouter des fichiers", systemImage: "doc.badge.plus")
                        }
                        .disabled(!hasTargetAccount || isParsing)

                        // Captures d'écran de l'appli bancaire — `PhotosPicker`
                        // existe aussi sur macOS (Photos y est disponible), la
                        // photothèque n'était simplement pas proposée ici.
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
            // Convention du projet : le tint ADN est posé PAR VUE (il n'y a pas
            // de tint global). Une vue présentée en panneau ne l'hérite pas de
            // son appelant — sans ça, ses contrôles système reprennent la
            // couleur d'accentuation du système, d'où des icônes bleues.
            .tint(AppTheme.Colors.accent)
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
                        Button { cancelFunnel() } label: {
                            Label("Annuler", systemImage: "xmark")
                        }
                    }
                }
                #else
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { cancelFunnel() } label: {
                            Label("Annuler", systemImage: "xmark")
                        }
                    }
                }
                #endif
            }
            #if os(macOS)
            .modifier(ImportEntryInspectorChrome(isEmbedded: isEmbedded, dismiss: cancelFunnel))
            #endif
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
            // iOS uniquement : sur macOS le mapping remplace le contenu sur
            // place (cf. `stepContent`), sans jamais empiler.
            #if !os(macOS)
            .navigationDestination(item: $step) { current in
                switch current {
                case .mapping(let index):
                    // L'index vient de l'étape : `pendingMappings` n'est jamais
                    // mutée en cours de parcours, donc ce contenu reste valide
                    // tant que l'écran est poussé.
                    if index < pendingMappings.count, let accountId = selectedAccountId {
                        mappingView(index: index, accountId: accountId)
                    }
                }
            }
            #endif
            .alert("Une session d'import est déjà en cours",
                   isPresented: $showResumeAlert, presenting: existingActiveSession) { _ in
                Button("Reprendre") {
                    // Même passage de main que la fin d'import : présenter la
                    // session en fermant cet écran dans le même cycle ne
                    // marchait pas côté iOS (deux `.sheet` concurrentes).
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
    }

    // MARK: - Logic

    /// Destination effective : celle choisie dans l'écran, sinon celle
    /// pré-remplie par le point d'entrée.
    private var activeDestination: ImportDestination { destination ?? initialDestination }

    private var importButtonLabel: String {
        switch stagedFiles.count {
        case 0:  return "Importer"
        case 1:  return "Importer 1 document"
        default: return "Importer \(stagedFiles.count) documents"
        }
    }

    /// Un compte cible est-il sélectionné pour la destination courante ?
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

    /// `sharedNaming` : les fichiers de l'inbox ont des noms UUID
    /// opaques — on leur substitue un nom lisible pour l'affichage et pour le
    /// `source_file` de la session.
    private func handleFileResult(_ result: Result<[URL], Error>, sharedNaming: Bool = false) {
        parseError = nil
        switch result {
        case .failure(let err):
            parseError = err.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // Fichiers reçus par partage/raccourci : traitement direct.
            // Sélection manuelle : on empile seulement, l'utilisateur décide
            // quand lancer (cf. `stagedFiles`).
            guard sharedNaming else {
                stageFiles(urls)
                return
            }
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

    /// Lance le traitement de la sélection accumulée.
    private func startImport() {
        parseError = nil
        let files = stagedFiles          // capturés AVANT la remise à zéro
        guard !files.isEmpty else { return }
        resetPipeline()
        isParsing = true
        Task { await classify(files) }
    }

    /// Empile des fichiers choisis, sans rien lancer.
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

    /// Captures choisies dans la photothèque : elles rejoignent exactement la
    /// même file que les fichiers (le type réel est sniffé sur les octets).
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
                // Le picker est vidé pour qu'une nouvelle sélection déclenche
                // à nouveau `onChange` (sinon choisir les mêmes captures ne
                // produirait rien).
                photoItems = []
            }
        }
    }

    /// Lit les fichiers par le pipeline, puis répartit ce qui a besoin de
    /// l'utilisateur (tables à mapper) et ce qui part en arrière-plan.
    ///
    /// ⚠️ Cet écran ne sniffe plus rien lui-même. Il avait sa propre détection
    /// de format, doublant celle des parseurs — trois copies au total, qui ont
    /// fini par diverger (l'une connaissait le classeur, les autres non). La
    /// phase de lecture du pipeline est désormais le seul endroit qui décide
    /// « ce fichier est un tableau / un document / un relevé structuré ».
    private func classify(_ files: [(data: Data, name: String)]) async {
        let sources = files.map { ImportDocumentSource(data: $0.data, displayName: $0.name) }
        let readout = await ImportPipeline.read(sources: sources, destination: activeDestination)

        // Destination « investissements » : pas de mapping de colonnes ni de
        // session — tout part au parseur dont le prompt est calibré pour des
        // avis d'opéré et des portefeuilles.
        guard activeDestination == .transactions else {
            await MainActor.run {
                isParsing = false
                handledFileNames = files.map(\.name)
                guard let account = targetAccountId else { return }
                coordinator.beginJob(destination: activeDestination,
                                     accountId: account,
                                     sourceLabel: sessionLabel())
                // Aucun mapping possible côté investissements : rien à attendre
                // de l'utilisateur, le résultat est relisible dès qu'il est prêt.
                coordinator.setAwaitingUserMapping(false)
                coordinator.startAnalysis(readout: readout)
                step = nil
                Task { @MainActor in dismiss() }
            }
            return
        }

        await MainActor.run {
            isParsing = false
            // ⚠️ L'écran de mapping est TOUJOURS affiché, même quand la
            // signature de l'en-tête est déjà connue. Le format mémorisé sert à
            // PRÉ-REMPLIR (bandeau « Format connu »), pas à sauter l'étape :
            // deux fichiers au même en-tête peuvent avoir un séparateur ou une
            // convention décimale différents, et l'utilisateur doit pouvoir
            // vérifier les colonnes avant d'importer.
            pendingMappings = readout.pendingGrids
            mappingIndex = 0
            pendingReadout = ImportPipeline.Readout(units: readout.units)
            handledFileNames = files.map(\.name)
            // Ouvre le job AVANT la première étape : à partir d'ici, toutes les
            // sources (tables mappées puis documents analysés) alimentent le
            // même coordinateur, qui survit à la fermeture de cet écran.
            if let account = targetAccountId {
                coordinator.beginJob(destination: activeDestination,
                                     accountId: account,
                                     sourceLabel: sessionLabel())
            }
            // ⚠️ L'analyse des documents part MAINTENANT, en même temps que le
            // premier écran de mapping. Le mapping d'un CSV ne bloque donc plus
            // les PDF du même lot — sur un import mixte, l'utilisateur mappe
            // pendant que les documents sont analysés, au lieu d'attendre après.
            //
            // Le verrou `awaitingUserMapping` empêche le bandeau de proposer
            // « Continuer » avant la fin des mappings : le résultat serait
            // incomplet, et ouvrirait une seconde feuille par-dessus l'écran de
            // mapping.
            coordinator.setAwaitingUserMapping(!readout.pendingGrids.isEmpty)
            if !readout.units.isEmpty {
                coordinator.startAnalysis(readout: ImportPipeline.Readout(units: readout.units))
            }
            advance()
        }
    }

    /// Compte cible de la destination courante.
    private var targetAccountId: Int? {
        activeDestination == .transactions ? selectedAccountId : selectedInvestmentAccountId
    }

    /// Étape suivante : documents d'abord (ils ont un écran de revue), puis les
    /// mappings de colonnes un par un, puis création de la session.
    private func advance() {
        // Les mappings de colonnes d'abord : ce sont les SEULES étapes qui
        // demandent l'utilisateur. L'analyse des documents, elle, tourne déjà
        // en fond depuis `classify`.
        if mappingIndex < pendingMappings.count {
            step = .mapping(index: mappingIndex)
            return
        }
        // Plus rien à mapper : on libère le verrou, ce qui rend le résultat
        // d'analyse disponible dans le bandeau dès qu'il est prêt (il peut déjà
        // l'être — c'est justement le but de l'avoir lancé en parallèle).
        coordinator.setAwaitingUserMapping(false)

        // Des documents sont en cours ou déjà analysés : on rend la main, le
        // bandeau prend le relais et rouvrira la revue.
        if !pendingReadout.units.isEmpty {
            step = nil
            // Fermeture au cycle suivant : dépiler, fermer et laisser le
            // bandeau apparaître dans le même cycle de rendu fait crasher
            // SwiftUI.
            Task { @MainActor in dismiss() }
            return
        }
        // Aucun document : toutes les sources étaient des tables, la session
        // peut être créée tout de suite. On dépile D'ABORD, et la création
        // (qui ferme cette feuille et en présente une autre) attend le cycle
        // suivant, pour la même raison.
        step = nil
        Task { @MainActor in finalize() }
    }

    /// Abandon du parcours par l'utilisateur (bouton « Annuler »).
    ///
    /// ⚠️ Annule AUSSI le job : depuis que l'analyse démarre en parallèle des
    /// mappings, fermer l'entonnoir laisserait tourner une analyse dont les
    /// tables ne seront jamais mappées — donc un import amputé d'une partie de
    /// ses fichiers, présenté comme complet. « Annuler » sur l'écran d'import
    /// veut dire que l'import n'a pas lieu.
    private func cancelFunnel() {
        if coordinator.isActive { coordinator.cancel() }
        dismiss()
    }

    /// Aucun document à analyser : toutes les sources sont des CSV déjà mappés,
    /// on crée la session immédiatement avec l'ensemble accumulé.
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
        coordinator.clear()   // job consommé
        appState.activeImportSession = summary
        Self.handOver(to: appState, dismissSelf: dismiss)
    }

    /// Passe la main à la revue complète (tiers, catégories, valider/ignorer
    /// ligne par ligne) sans clignotement.
    ///
    /// ⚠️ Deux mécanismes RADICALEMENT différents :
    ///   • macOS — l'inspecteur a un slot unique et `InspectorPaneCenter.present`
    ///     sait remplacer son contenu en UNE opération (il ferme l'ancien
    ///     propriétaire lui-même). Fermer d'abord produisait une fermeture PUIS
    ///     une réouverture, visible et désagréable.
    ///   • iOS — ce sont des `.sheet` : on ne peut pas en présenter une seconde
    ///     tant que la première est à l'écran, il FAUT fermer puis attendre.
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

    /// Libellé de la session : le premier fichier, suivi du nombre d'autres.
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
