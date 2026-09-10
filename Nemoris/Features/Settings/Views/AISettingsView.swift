import SwiftUI
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Réglages IA : une ligne PAR FONCTIONNALITÉ, plus la configuration des
/// backends qu'elles se partagent.
///
/// ⚠️ Un backend se configure UNE fois (adresse du serveur local, clé API d'un
/// fournisseur) et sert ensuite à autant de fonctionnalités qu'on veut. C'est ce
/// qui rend le réglage par fonctionnalité praticable : sans ça, il faudrait
/// ressaisir la même clé cinq fois.
///
/// ⚠️ **Piège de localisation** (déjà rencontré ailleurs) :
/// `Text(uneVariable)` / `Label(String, ...)` ne consultent JAMAIS
/// `Localizable.strings` — seuls `Text("littéral")` et
/// `Label(LocalizedStringKey, ...)` le font. Tous les libellés dynamiques de cet
/// écran (noms de backends, de fonctionnalités) doivent donc être enveloppés
/// dans `LocalizedStringKey(...)`, sinon ils restent en français sur un appareil
/// en anglais.
struct AISettingsView: View {

    @State private var choices: [AIFeature: AIBackendChoice] = [:]
    @State private var appleStatus: AppleIntelligenceStatus = .iosTooOld

    // Serveur local
    @State private var localBaseURL = ""
    @State private var localModel = ""
    @State private var localAPIKey = ""
    @State private var localDisableThinking = false

    // Modèle embarqué (téléchargé depuis Hugging Face, exécuté dans l'app)
    @State private var embeddedModels: [EmbeddedModelInfo] = []
    @State private var embeddedActiveID: String?
    @State private var embeddedInput = ""
    @State private var embeddedCandidates: [EmbeddedModelCandidate] = []
    @State private var mlxRepoCandidate: EmbeddedMLXRepoCandidate?
    @State private var embeddedWarnings: [String: String] = [:]
    /// Avertissement RAM affiché APRÈS coup — import ou activation d'un
    /// modèle déjà en place, où il n'y a pas de candidat/ligne dédiée pour
    /// porter `embeddedWarnings` comme lors d'un téléchargement.
    @State private var embeddedActionWarning: String?
    @State private var embeddedAnalyzeError: String?
    @State private var isAnalyzingEmbedded = false
    // Progression du téléchargement en cours : lue DIRECTEMENT depuis
    // `EmbeddedModelDownloadStatus.shared` partout où c'est affiché, sans
    // wrapper — c'est un singleton `@Observable` externe à cette vue (même
    // convention que `EmbeddedModelManager.shared` juste en dessous), pas un
    // état que la vue possède. `@Observable` abonne automatiquement tout
    // `body` qui LIT une de ses propriétés ; c'est précisément ce qui permet
    // à l'indication de survivre à la fermeture/réouverture de l'écran (le
    // téléchargement lui-même continue déjà en coulisses).
    @State private var downloadError: String?
    @State private var renamingModelID: String?
    @State private var renameText = ""
    #if !os(macOS)
    @State private var showImportGGUFPicker = false
    @State private var showImportMLXFolderPicker = false
    #endif

    // Fournisseurs cloud
    @State private var cloudKeys: [AICloudProvider: String] = [:]
    @State private var cloudModels: [AICloudProvider: String] = [:]

    @State private var testSuccess: String?
    @State private var testError: String?
    @State private var isTesting = false

    /// `nil` sur iOS (le `NavigationLink` qui pousse cet écran fournit déjà
    /// son bouton retour natif). Sur macOS, fourni par l'appelant
    /// (`SettingsView.settingsSectionPage`) — cet écran REMPLACE le contenu
    /// du parent (pas un push), donc `dismiss()` seul n'a rien à fermer.
    /// Même doctrine que `ModulesSettingsView.onBack` : superposer ICI un
    /// second bouton retour générique en plus de celui-ci fusionnait les deux
    /// `.toolbar` en deux chevrons empilés.
    var onBack: (() -> Void)? = nil

    /// Écran « Sources avancées » ouvert par-dessus la liste par fonctionnalité.
    ///
    /// ⚠️ Navigation DIFFÉRENTE selon la plateforme, et c'est voulu ici — pas
    /// une divergence à unifier. Sur macOS, `AISettingsView` est atteinte par
    /// REMPLACEMENT de contenu depuis `SettingsView` (`pushedSection`), sans
    /// `NavigationStack` à cet endroit : un vrai push n'aurait aucune pile où
    /// s'empiler. Sur iOS en revanche, `AISettingsView` EST poussée via un
    /// vrai `NavigationLink` depuis `SettingsView` — une pile existe donc
    /// réellement ici, et un second push interne (`.navigationDestination`)
    /// y fonctionne nativement. Un ancien essai avait volontairement gardé le
    /// même mécanisme (état + bouton manuel) sur les deux plateformes « pour
    /// ne pas diverger » — mais sur iOS ce bouton manuel s'AJOUTAIT au bouton
    /// retour automatique du push plutôt que de le remplacer (les deux
    /// vivent au même niveau de pile), d'où deux chevrons empilés dans la
    /// barre (retour d'usage, capture à l'appui). Diverger ICI est donc le
    /// bon choix, pas une entorse à la doctrine.
    @State private var showAdvanced = false

    var body: some View {
        Group {
            #if os(macOS)
            if showAdvanced {
                advancedBody
            } else {
                mainBody
            }
            #else
            mainBody
            #endif
        }
        .onAppear(perform: load)
    }

    /// Écran principal : les cinq réglages par fonctionnalité seulement — la
    /// configuration des sources qu'elles partagent (Apple Intelligence,
    /// serveur local, clés cloud) vit derrière « Sources avancées », pour ne
    /// pas noyer le choix simple (Automatique/Désactivée) sous des champs que
    /// la plupart des utilisateurs n'ouvriront jamais.
    private var mainBody: some View {
        // Form (pas List) : contenu statique de type réglages → rendu identique
        // sur iOS et boxes arrondies natives sur macOS via nemorisFormStyle().
        // Pas de ZStack+Color (hauteur infinie sur macOS) : fond via .background.
        Form {
            featuresSection
            advancedLinkSection
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .tint(AppTheme.Colors.accent)
        .localizedNavigationTitle("Intelligence artificielle")
        .navigationBarTitleDisplayMode(.inline)
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack?()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Réglages")
                .localizedAccessibilityLabel("Réglages")
            }
        }
        #else
        // Vrai push : le bouton retour AUTOMATIQUE de ce niveau de pile
        // suffit alors dans `advancedBody` (natif, un seul chevron) — cf.
        // le commentaire de `showAdvanced` ci-dessus.
        .navigationDestination(isPresented: $showAdvanced) { advancedBody }
        #endif
    }

    /// Statut Apple Intelligence, configuration du serveur local, clés des
    /// fournisseurs cloud, test de connexion — tout ce qui se configure UNE
    /// fois et sert à plusieurs fonctionnalités, regroupé pour ne pas répéter
    /// ces champs cinq fois ni les afficher à plat sur l'écran principal.
    private var advancedBody: some View {
        Form {
            appleSection
            embeddedModelSection
            localServerSection
            ForEach(AICloudProvider.allCases, id: \.self) { provider in
                cloudSection(provider)
            }
            testSection
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .tint(AppTheme.Colors.accent)
        .localizedNavigationTitle("Sources avancées")
        .navigationBarTitleDisplayMode(.inline)
        #if os(macOS)
        // Sur macOS, `advancedBody` REMPLACE `mainBody` par état (pas de
        // push) : aucun bouton retour automatique n'existe à cet endroit, le
        // bouton manuel reste nécessaire ici.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showAdvanced = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .localizedHelp("Intelligence artificielle")
                .localizedAccessibilityLabel("Intelligence artificielle")
            }
        }
        #endif
        // Sur iOS, `advancedBody` est un vrai push (`.navigationDestination`
        // sur `mainBody`) : le bouton retour automatique de la pile revient
        // déjà nativement à `mainBody`. Un second bouton manuel ici
        // s'AJOUTERAIT à celui-là (même niveau de pile) plutôt que de le
        // remplacer, d'où le double chevron corrigé (retour d'usage).
    }

    /// Ligne d'accès à « Sources avancées », même style que les liens de
    /// `SettingsView.settingsLink`.
    private var advancedLinkSection: some View {
        Section {
            Button {
                showAdvanced = true
            } label: {
                HStack {
                    Label("Sources avancées", systemImage: "gearshape.2")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            Text("Statut d'Apple Intelligence, adresse du serveur local, clés API Claude et OpenAI, test de connexion.")
        }
    }

    // MARK: - Fonctionnalités

    /// ⚠️ Sélecteur INLINE, pas un écran poussé par fonctionnalité.
    ///
    /// Deux raisons : cinq allers-retours pour régler cinq lignes est pénible,
    /// et surtout empiler un écran depuis les Réglages est le motif à risque
    /// documenté sur macOS (§N.1 : panneau peint sous le contenu poussé, gels
    /// AutoLayout). Tout tient donc dans la ligne, y compris ce qui justifie le
    /// choix.
    private var featuresSection: some View {
        Section {
            ForEach(AIFeature.allCases) { feature in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: Binding(
                        get: { choices[feature] ?? .automatic },
                        set: { newValue in
                            choices[feature] = newValue
                            AIFeatureSettings.setChoice(newValue, for: feature)
                        }
                    )) {
                        ForEach(AIBackendChoice.allChoices, id: \.self) { choice in
                            Label(LocalizedStringKey(choice.displayName), systemImage: choice.icon)
                                .tag(choice)
                        }
                    } label: {
                        Label(LocalizedStringKey(feature.displayName), systemImage: feature.icon)
                    }
                    .pickerStyle(.menu)

                    // Ce qui sera RÉELLEMENT utilisé, plus l'avertissement s'il
                    // y a lieu — l'information qui manquerait si le détail
                    // vivait derrière un push.
                    statusLine(for: feature)
                        .font(.caption)
                        .foregroundStyle(effectiveColor(for: feature))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedStringKey(feature.explanation))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsConsumptionHint(for: feature) {
                        Text(LocalizedStringKey("Consommation estimée : \(feature.consumptionHint)"))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Par fonctionnalité")
        } footer: {
            Text("Chaque fonctionnalité choisit sa source. Utile quand Apple Intelligence sait faire l'une mais pas l'autre — la lecture d'images, par exemple, demande iOS 27.")
        }
    }

    /// La ligne d'état sous le sélecteur : d'abord le problème s'il y en a un,
    /// sinon le backend effectif — et le rappel que les données sortent quand
    /// c'est le cas.
    ///
    /// ⚠️ Renvoie un `Text` COMPOSÉ (concaténation de fragments `Text` littéraux),
    /// jamais une `String` assemblée puis passée à un seul `Text` : un
    /// `Text(LocalizedStringKey(uneStringDéjàRésolue))` fige la clé sur le texte
    /// déjà traduit — le picker de langue des Réglages ne le rafraîchit alors
    /// plus jamais (`Text(LocalizedStringKey)`/`Text(LocalizedStringResource)`
    /// se ré-résolvent contre `\.locale` au rendu, une `String` figée non). Même
    /// motif que `PatrimoineView.goalSubtitle`.
    private func statusLine(for feature: AIFeature) -> Text {
        if let reason = AIEnrichmentBackend.unavailabilityReason(for: feature) {
            return Text(LocalizedStringKey(reason))
        }
        var line = effectiveLabel(for: feature)
        // ⚠️ Sur le backend RÉSOLU, pas le choix brut : « Automatique » qui
        // retombe sur le cloud fait sortir les données tout autant qu'un choix
        // `.cloud` explicite — `(choices[feature] ?? .automatic).leavesDevice`
        // valait toujours `false` pour `.automatic` et ratait ce cas.
        if AIEnrichmentBackend.resolved(for: feature)?.leavesDevice == true {
            line = line + Text(" · ⚠️ les données quittent l'appareil")
        }
        if feature.benefitsFromImage, !AIEnrichmentBackend.supportsImageInput(for: feature) {
            // Pas une erreur : l'import fonctionne, mais en océrisant la
            // capture — donc en perdant la mise en page, qui porte du sens.
            line = line + Text(" · captures océrisées (pas de lecture d'image)")
        }
        return line
    }

    /// Vrai quand le backend résolu n'est pas 100 % sur l'appareil — c'est là
    /// que la consommation (réseau, calcul, facture API) devient pertinente à
    /// signaler. Apple Intelligence et « aucune IA » n'affichent rien.
    private func showsConsumptionHint(for feature: AIFeature) -> Bool {
        switch AIEnrichmentBackend.resolved(for: feature) {
        case .localServer, .cloud: return true
        default: return false
        }
    }

    /// Ce qui sera RÉELLEMENT utilisé, pas seulement ce qui est demandé.
    ///
    /// ⚠️ La distinction compte : « Automatique » sur un appareil où rien n'est
    /// configuré veut dire « aucune IA », et l'utilisateur doit le voir ici
    /// plutôt que de le découvrir devant un bouton grisé.
    private func effectiveLabel(for feature: AIFeature) -> Text {
        let asked = choices[feature] ?? .automatic
        guard let resolved = AIEnrichmentBackend.resolved(for: feature) else {
            if asked == .off { return Text("Désactivée") }
            return Text(LocalizedStringKey(asked.displayName)) + Text(" — indisponible")
        }
        if asked == .automatic {
            return Text("Automatique → ") + Text(LocalizedStringKey(resolved.displayName))
        }
        return Text(LocalizedStringKey(resolved.displayName))
    }

    private func effectiveColor(for feature: AIFeature) -> Color {
        let asked = choices[feature] ?? .automatic
        if asked == .off { return AppTheme.Colors.textSecondary }
        guard let resolved = AIEnrichmentBackend.resolved(for: feature) else {
            return AppTheme.Colors.warning
        }
        // Orange aussi quand ça marche mais que les données sortent : ce n'est
        // pas une erreur, c'est un choix qui mérite d'être visible en un coup
        // d'œil dans la liste.
        return resolved.leavesDevice ? AppTheme.Colors.warning : AppTheme.Colors.success
    }

    // MARK: - Apple Intelligence

    private var appleSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appleStatus.icon)
                    .foregroundStyle(appleStatus.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(appleStatus.title))
                        .font(.subheadline.weight(.semibold))
                    Text(LocalizedStringKey(appleStatus.detail))
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("100 % sur l'appareil, aucune donnée transmise. C'est la source retenue en priorité par le mode Automatique quand elle est disponible.")
        }
    }

    // MARK: - Modèle embarqué

    /// Pas de marketplace : un champ pour coller un lien/repo Hugging Face, un
    /// bouton pour analyser (taille + avertissement RAM/stockage AVANT tout
    /// octet téléchargé), et la liste des modèles déjà téléchargés
    /// (renommer/activer/supprimer). Un seul actif à la fois — cf.
    /// `EmbeddedModelService`.
    private var embeddedModelSection: some View {
        Section {
            // EN PREMIER, et INDÉPENDANT de `embeddedCandidates`/`mlxRepoCandidate`
            // (qui, eux, sont perdus si on quitte l'écran puis qu'on y revient) :
            // c'est précisément ce qui rend un téléchargement en cours visible
            // après une navigation, alors que le téléchargement lui-même n'a
            // jamais été interrompu — cf. `EmbeddedModelDownloadStatus`.
            if let inFlight = EmbeddedModelDownloadStatus.shared.inFlight {
                inFlightDownloadBanner(inFlight)
            }

            TextField("Lien ou repo Hugging Face", text: $embeddedInput,
                      prompt: Text("owner/repo (GGUF ou MLX), ou lien vers un .gguf"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disableAutocorrection(true)

            Button {
                Task { await analyzeEmbedded() }
            } label: {
                if isAnalyzingEmbedded {
                    HStack { ProgressView().controlSize(.small); Text("Analyse…") }
                } else {
                    Label("Analyser", systemImage: "magnifyingglass")
                }
            }
            .disabled(isAnalyzingEmbedded || embeddedInput.trimmingCharacters(in: .whitespaces).isEmpty)

            if let embeddedAnalyzeError {
                Label(LocalizedStringKey(embeddedAnalyzeError), systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
            }

            ForEach(embeddedCandidates) { candidate in
                candidateRow(candidate)
            }
            if let mlxRepoCandidate {
                mlxRepoCandidateRow(mlxRepoCandidate)
            }

            // Chemin PRINCIPAL, pas seulement un repli : n'importe quel
            // fichier/dossier déjà présent sur l'appareil, quelle que soit son
            // origine — pas seulement Hugging Face.
            Button {
                #if os(macOS)
                presentOpenPanel(contentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { url in
                    Task { await importGGUFFile(url) }
                }
                #else
                showImportGGUFPicker = true
                #endif
            } label: {
                Label("Importer un fichier .gguf…", systemImage: "square.and.arrow.down.on.square")
            }

            if EmbeddedModelManager.mlxSupported {
                Button {
                    #if os(macOS)
                    presentOpenPanel(contentTypes: [.folder]) { url in
                        Task { await importMLXFolder(url) }
                    }
                    #else
                    showImportMLXFolderPicker = true
                    #endif
                } label: {
                    Label("Importer un dossier de modèle MLX…", systemImage: "folder.badge.plus")
                }
            }

            if let downloadError {
                Label(LocalizedStringKey(downloadError), systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
            }
            if let embeddedActionWarning {
                Label(LocalizedStringKey(embeddedActionWarning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !embeddedModels.isEmpty {
                ForEach(embeddedModels) { model in
                    downloadedModelRow(model)
                }
            }
        } header: {
            Text("Modèle embarqué")
        } footer: {
            Text("Un fichier .gguf ou un dossier de modèle MLX, obtenu par le moyen de ton choix (lien direct, Hugging Face, Fichiers, Mac…), exécuté entièrement sur cet appareil. Aucune donnée transmise une fois en place. Fonctionne sans Apple Intelligence.")
        }
        #if !os(macOS)
        .sheet(isPresented: $showImportGGUFPicker) {
            DocumentPickerView(contentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { url in
                showImportGGUFPicker = false
                Task { await importGGUFFile(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showImportMLXFolderPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                showImportMLXFolderPicker = false
                Task { await importMLXFolder(url) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// Visible que l'écran vienne d'ouvrir ou soit resté ouvert depuis le
    /// début du téléchargement — c'est tout l'intérêt de lire
    /// `EmbeddedModelDownloadStatus.shared` plutôt qu'un `@State` local.
    private func inFlightDownloadBanner(_ inFlight: EmbeddedModelDownloadStatus.InFlight) -> some View {
        HStack(spacing: 10) {
            if let progress = inFlight.progress {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(inFlight.label) — \(Int((progress * 100).rounded())) %")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ProgressView().controlSize(.small)
                Text("Téléchargement de \(inFlight.label)…")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func candidateRow(_ candidate: EmbeddedModelCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.fileName)
                        .font(.subheadline.weight(.medium))
                    if let size = candidate.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                if EmbeddedModelDownloadStatus.shared.inFlight?.candidateID == candidate.id {
                    if let progress = EmbeddedModelDownloadStatus.shared.inFlight?.progress {
                        ProgressView(value: progress)
                            .frame(width: 60)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button {
                        Task { await downloadCandidate(candidate) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(EmbeddedModelDownloadStatus.shared.inFlight != nil)
                }
            }
            if let warning = embeddedWarnings[candidate.id] {
                Label(LocalizedStringKey(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Un modèle MLX est TOUJOURS plusieurs fichiers — rien à désambiguïser
    /// comme pour les quantizations GGUF, donc UNE seule ligne pour tout le
    /// repo plutôt qu'une liste par fichier.
    private func mlxRepoCandidateRow(_ candidate: EmbeddedMLXRepoCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(candidate.repo)
                            .font(.subheadline.weight(.medium))
                        Text("MLX")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppTheme.Colors.textSecondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    if let total = candidate.totalSizeBytes {
                        Text("\(candidate.files.count) fichiers · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Text("\(candidate.files.count) fichiers")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                if EmbeddedModelDownloadStatus.shared.inFlight?.candidateID == candidate.id {
                    if let progress = EmbeddedModelDownloadStatus.shared.inFlight?.progress {
                        ProgressView(value: progress)
                            .frame(width: 60)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button {
                        Task { await downloadMLXRepoCandidate(candidate) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(EmbeddedModelDownloadStatus.shared.inFlight != nil)
                }
            }
            if let warning = embeddedWarnings[candidate.id] {
                Label(LocalizedStringKey(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func downloadedModelRow(_ model: EmbeddedModelInfo) -> some View {
        HStack {
            Button {
                Task { await setActiveEmbedded(model.id) }
            } label: {
                Image(systemName: embeddedActiveID == model.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(embeddedActiveID == model.id ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if renamingModelID == model.id {
                    TextField("Nom", text: $renameText)
                        .font(.subheadline)
                        .onSubmit { Task { await commitRename(model.id) } }
                } else {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.subheadline.weight(embeddedActiveID == model.id ? .semibold : .regular))
                        Text(model.format == .mlx ? "MLX" : "GGUF")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppTheme.Colors.textSecondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                Text("\(model.sourceDescription) · \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Menu {
                Button {
                    renamingModelID = model.id
                    renameText = model.displayName
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await deleteEmbedded(model.id) }
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadEmbeddedModels() async {
        embeddedModels = await EmbeddedModelManager.shared.downloadedModels()
        embeddedActiveID = EmbeddedModelManager.activeModelID
    }

    private func analyzeEmbedded() async {
        isAnalyzingEmbedded = true
        embeddedAnalyzeError = nil
        embeddedCandidates = []
        mlxRepoCandidate = nil
        embeddedWarnings = [:]
        defer { isAnalyzingEmbedded = false }
        do {
            let result = try await EmbeddedModelManager.shared.analyze(embeddedInput)
            switch result {
            case .ggufFiles(let candidates):
                embeddedCandidates = candidates
                for candidate in candidates {
                    guard let size = candidate.sizeBytes else { continue }
                    if let warning = await EmbeddedModelManager.shared.sizeWarning(forBytes: size) {
                        embeddedWarnings[candidate.id] = warning
                    }
                }
            case .mlxRepo(let repo):
                mlxRepoCandidate = repo
                if let total = repo.totalSizeBytes,
                   let warning = await EmbeddedModelManager.shared.sizeWarning(forBytes: total) {
                    embeddedWarnings[repo.id] = warning
                }
            }
        } catch {
            embeddedAnalyzeError = error.localizedDescription
        }
    }

    private func downloadCandidate(_ candidate: EmbeddedModelCandidate) async {
        EmbeddedModelDownloadStatus.shared.start(candidateID: candidate.id, label: candidate.fileName)
        downloadError = nil
        do {
            _ = try await EmbeddedModelManager.shared.download(candidate: candidate) { progress in
                Task { @MainActor in EmbeddedModelDownloadStatus.shared.update(progress: progress) }
            }
            embeddedInput = ""
            embeddedCandidates = []
            embeddedWarnings = [:]
            await loadEmbeddedModels()
        } catch {
            downloadError = error.localizedDescription
        }
        EmbeddedModelDownloadStatus.shared.finish()
    }

    private func downloadMLXRepoCandidate(_ candidate: EmbeddedMLXRepoCandidate) async {
        EmbeddedModelDownloadStatus.shared.start(candidateID: candidate.id, label: candidate.repo)
        downloadError = nil
        do {
            _ = try await EmbeddedModelManager.shared.downloadMLXRepo(candidate: candidate) { progress in
                Task { @MainActor in EmbeddedModelDownloadStatus.shared.update(progress: progress) }
            }
            embeddedInput = ""
            mlxRepoCandidate = nil
            embeddedWarnings = [:]
            await loadEmbeddedModels()
        } catch {
            downloadError = error.localizedDescription
        }
        EmbeddedModelDownloadStatus.shared.finish()
    }

    private func setActiveEmbedded(_ id: String) async {
        embeddedActionWarning = await EmbeddedModelManager.shared.setActive(id: id)
        embeddedActiveID = id
    }

    private func deleteEmbedded(_ id: String) async {
        await EmbeddedModelManager.shared.delete(id: id)
        await loadEmbeddedModels()
    }

    private func commitRename(_ id: String) async {
        await EmbeddedModelManager.shared.rename(id: id, to: renameText)
        renamingModelID = nil
        await loadEmbeddedModels()
    }

    /// Import direct — n'importe quelle source, aucune dépendance au réseau
    /// ni à Hugging Face. Copie synchrone (rapide, même conteneur de l'app),
    /// pas de barre de progression nécessaire contrairement au téléchargement.
    private func importGGUFFile(_ url: URL) async {
        downloadError = nil
        embeddedActionWarning = nil
        do {
            let result = try await EmbeddedModelManager.shared.importFile(from: url)
            embeddedActionWarning = result.warning
            await loadEmbeddedModels()
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func importMLXFolder(_ url: URL) async {
        downloadError = nil
        embeddedActionWarning = nil
        do {
            let result = try await EmbeddedModelManager.shared.importFolder(from: url)
            embeddedActionWarning = result.warning
            await loadEmbeddedModels()
        } catch {
            downloadError = error.localizedDescription
        }
    }

    // MARK: - Serveur local

    private var localServerSection: some View {
        Section {
            TextField("Adresse du serveur", text: $localBaseURL,
                      prompt: Text("http://192.168.1.10:1234"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: localBaseURL) { _, value in LocalLLMService.baseURL = value }

            TextField("Modèle (optionnel)", text: $localModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: localModel) { _, value in LocalLLMService.model = value }

            SecureField("Clé API (optionnelle)", text: $localAPIKey)
                .onChange(of: localAPIKey) { _, value in
                    LocalLLMKeychain.save(value, for: LocalLLMKeychain.apiKeyID)
                }

            Toggle("Couper le mode raisonnement", isOn: $localDisableThinking)
                .onChange(of: localDisableThinking) { _, value in
                    LocalLLMService.disableThinking = value
                }
        } header: {
            Text("Serveur local")
        } footer: {
            Text("Un serveur compatible OpenAI (LM Studio, Ollama…) sur ton Mac ou sur cet appareil. Les données restent sur ton réseau.\n\nLe mode raisonnement est conservé par défaut : c'est lui qui donne les meilleures analyses. Ne le coupe que si ce serveur renvoie des réponses vides — certains modèles (Qwen, DeepSeek) dépensent alors tout leur budget en réflexion sans jamais écrire de réponse. Tous les serveurs n'honorent pas ce réglage.")
        }
    }

    // MARK: - Fournisseurs cloud

    private func cloudSection(_ provider: AICloudProvider) -> some View {
        Section {
            SecureField("Clé API", text: Binding(
                get: { cloudKeys[provider] ?? "" },
                set: { value in
                    cloudKeys[provider] = value
                    CloudLLMKeychain.save(value, for: provider)
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("Modèle", text: Binding(
                get: { cloudModels[provider] ?? "" },
                set: { value in
                    cloudModels[provider] = value
                    CloudLLMService.setModel(value, for: provider)
                }
            ), prompt: Text(provider.defaultModel))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text(LocalizedStringKey(provider.displayName))
        } footer: {
            Text("Ta clé reste dans le trousseau de cet appareil, jamais synchronisée. Laisse le modèle vide pour utiliser celui proposé. ⚠️ Les données envoyées à ce fournisseur quittent l'appareil.")
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                Task { await runTest() }
            } label: {
                if isTesting {
                    HStack { ProgressView().controlSize(.small); Text("Test en cours…") }
                } else {
                    Label("Tester les backends configurés", systemImage: "bolt.horizontal")
                }
            }
            .disabled(isTesting)

            if let testSuccess {
                Label(LocalizedStringKey(testSuccess), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.success)
            }
            if let testError {
                Label(LocalizedStringKey(testError), systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
            }
        } footer: {
            Text("Envoie un ping minimal à chaque backend configuré et rapporte sa réponse.")
        }
    }

    /// Teste TOUS les backends configurés, pas seulement le dernier saisi :
    /// avec un réglage par fonctionnalité, plusieurs peuvent servir en même
    /// temps, et savoir lequel des deux est cassé est l'information utile.
    private func runTest() async {
        isTesting = true
        testSuccess = nil
        testError = nil
        defer { isTesting = false }

        var successes: [String] = []
        var failures: [String] = []

        if EmbeddedModelManager.hasConfiguration {
            do {
                let message = try await EmbeddedModelService.shared.testConnection()
                successes.append("Modèle embarqué : \(message)")
            } catch {
                failures.append("Modèle embarqué — \(error.localizedDescription)")
            }
        }
        if LocalLLMService.hasConfiguration {
            do {
                let message = try await LocalLLMService.shared.testConnection()
                successes.append("Serveur local : \(message)")
            } catch {
                failures.append("Serveur local — \(error.localizedDescription)")
            }
        }
        for provider in AICloudProvider.allCases where CloudLLMService.hasConfiguration(provider) {
            do {
                let message = try await CloudLLMService(provider: provider).testConnection()
                successes.append("\(provider.displayName) : \(message)")
            } catch {
                failures.append("\(provider.displayName) — \(error.localizedDescription)")
            }
        }

        if successes.isEmpty && failures.isEmpty {
            testError = "Aucun backend configuré à tester."
            return
        }
        testSuccess = successes.isEmpty ? nil : successes.joined(separator: "\n")
        testError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: - Chargement

    private func load() {
        for feature in AIFeature.allCases {
            choices[feature] = AIFeatureSettings.choice(for: feature)
        }
        localBaseURL = LocalLLMService.baseURL
        localModel = LocalLLMService.model
        localDisableThinking = LocalLLMService.disableThinking
        localAPIKey = LocalLLMKeychain.load(id: LocalLLMKeychain.apiKeyID) ?? ""
        for provider in AICloudProvider.allCases {
            cloudKeys[provider] = CloudLLMKeychain.load(provider) ?? ""
            // Volontairement la valeur BRUTE (et non `CloudLLMService.model`,
            // qui substitue le défaut) : le champ doit rester vide tant que
            // l'utilisateur n'a rien saisi, pour que le prompt s'affiche.
            cloudModels[provider] = UserDefaults.standard
                .string(forKey: "ai.cloud.\(provider.rawValue).model") ?? ""
        }
        appleStatus = Self.detectAppleStatus()
        Task { await loadEmbeddedModels() }
    }

    // MARK: - Statut Apple Intelligence

    enum AppleIntelligenceStatus {
        case available
        case iosTooOld
        case hardwareNotEligible
        case appleIntelligenceDisabled

        var title: String {
            switch self {
            case .available:                 return "Disponible"
            case .iosTooOld:                 return "iOS 26 requis"
            case .hardwareNotEligible:       return "Appareil non compatible"
            case .appleIntelligenceDisabled: return "Apple Intelligence désactivée"
            }
        }

        var color: Color {
            self == .available ? AppTheme.Colors.success : AppTheme.Colors.warning
        }

        var icon: String {
            self == .available ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        }

        var detail: String {
            switch self {
            case .available:
                return "Le modèle d'Apple tourne directement sur cet appareil."
            case .iosTooOld:
                return "Nécessite iOS 26 ou supérieur. Sans lui, un serveur local ou un fournisseur cloud prend le relais."
            case .hardwareNotEligible:
                return "Nécessite un iPhone 15 Pro ou plus récent (iPad M1+, Mac M1+). Les autres sources restent disponibles."
            case .appleIntelligenceDisabled:
                return "À activer dans Réglages iOS → Apple Intelligence & Siri."
            }
        }
    }

    static func detectAppleStatus() -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceDisabled
                case .deviceNotEligible:           return .hardwareNotEligible
                default:                           return .appleIntelligenceDisabled
                }
            }
        }
        #endif
        return .iosTooOld
    }
}
