import SwiftUI
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI settings: one row PER FEATURE, plus configuring the
/// backends they share.
///
/// ⚠️ A backend is configured ONCE (a local server's address, a
/// provider's API key) and then serves as many features as needed. That's
/// what makes per-feature settings workable: without it, the same
/// key would have to be re-entered five times.
///
/// ⚠️ **Localization pitfall** (already hit elsewhere):
/// `Text(aVariable)` / `Label(String, ...)` NEVER consult
/// `Localizable.strings` — only `Text("literal")` and
/// `Label(LocalizedStringKey, ...)` do. Every dynamic label on this
/// screen (backend names, feature names) must therefore be wrapped
/// in `LocalizedStringKey(...)`, otherwise it stays in French on a device
/// set to English.
struct AISettingsView: View {

    @State private var choices: [AIFeature: AIBackendChoice] = [:]
    @State private var appleStatus: AppleIntelligenceStatus = .iosTooOld

    // Serveur local
    @State private var localBaseURL = ""
    @State private var localModel = ""
    @State private var localAPIKey = ""
    @State private var localDisableThinking = false

    // Embedded model (downloaded from Hugging Face, run inside the app)
    @State private var embeddedModels: [EmbeddedModelInfo] = []
    @State private var embeddedActiveID: String?
    @State private var embeddedInput = ""
    @State private var embeddedCandidates: [EmbeddedModelCandidate] = []
    @State private var mlxRepoCandidate: EmbeddedMLXRepoCandidate?
    @State private var embeddedWarnings: [String: String] = [:]
    /// RAM warning shown AFTER the fact — importing or activating a
    /// model already in place, where there's no dedicated candidate/row to
    /// carry `embeddedWarnings` the way a download does.
    @State private var embeddedActionWarning: String?
    @State private var embeddedAnalyzeError: String?
    @State private var isAnalyzingEmbedded = false
    // Progress of an ongoing download: read DIRECTLY from
    // `EmbeddedModelDownloadStatus.shared` everywhere it's shown, with no
    // wrapper — it's an `@Observable` singleton external to this view (the same
    // convention as `EmbeddedModelManager.shared` just below), not
    // state this view owns. `@Observable` automatically subscribes any
    // `body` that READS one of its properties; that's precisely what lets
    // the indicator survive the screen being closed and reopened (the
    // download itself is already continuing behind the scenes).
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

    /// `nil` on iOS (the `NavigationLink` that pushes this screen already
    /// provides its own native back button). On macOS, provided by the
    /// caller (`SettingsView.settingsSectionPage`) — this screen REPLACES
    /// the parent's content (not a push), so `dismiss()` alone has nothing to close.
    /// Same doctrine as `ModulesSettingsView.onBack`: stacking a
    /// second generic back button HERE on top of this one merged the two
    /// `.toolbar`s into two stacked chevrons.
    var onBack: (() -> Void)? = nil

    /// "Advanced sources" screen opened on top of the per-feature list.
    ///
    /// ⚠️ DIFFERENT navigation per platform, and it's intentional here — not
    /// a divergence to unify. On macOS, `AISettingsView` is reached by
    /// REPLACING content from `SettingsView` (`pushedSection`), with no
    /// `NavigationStack` at this point: a real push would have no stack to
    /// land on. On iOS, on the other hand, `AISettingsView` IS pushed via a
    /// real `NavigationLink` from `SettingsView` — a stack genuinely
    /// exists here, and a second internal push (`.navigationDestination`)
    /// works natively there. An earlier attempt deliberately kept the
    /// same mechanism (state + a manual button) on both platforms "so as
    /// not to diverge" — but on iOS that manual button was ADDED to the
    /// push's automatic back button rather than replacing it (both
    /// live at the same stack level), producing two stacked chevrons in
    /// the bar. Diverging HERE is therefore the right call, not a
    /// departure from doctrine.
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

    /// Main screen: only the five per-feature settings — configuring the
    /// sources they share (Apple Intelligence, a local server, cloud
    /// keys) lives behind "Advanced sources", so as not to
    /// bury the simple choice (Automatic/Disabled) under fields
    /// most users will never open.
    private var mainBody: some View {
        // A Form (not a List): static, settings-like content → rendered identically
        // on iOS and as native rounded boxes on macOS via nemorisFormStyle().
        // No ZStack+Color (infinite height on macOS): the background is via .background.
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
        // A real push: the AUTOMATIC back button at this stack level is
        // then enough in `advancedBody` (native, a single chevron) — see
        // the comment on `showAdvanced` above.
        .navigationDestination(isPresented: $showAdvanced) { advancedBody }
        #endif
    }

    /// Apple Intelligence status, local-server configuration, cloud
    /// provider keys, a connection test — everything configured ONCE
    /// and serving several features, grouped so as not to repeat
    /// these fields five times or show them flat on the main screen.
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
        // On macOS, `advancedBody` REPLACES `mainBody` via state (not a
        // push): no automatic back button exists at this point, the
        // manual button stays necessary here.
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
        // On iOS, `advancedBody` is a real push (`.navigationDestination`
        // on `mainBody`): the stack's automatic back button already
        // natively returns to `mainBody`. A second manual button here
        // would be ADDED to that one (the same stack level) rather than
        // replacing it, hence the double chevron that was fixed.
    }

    /// Row linking to "Advanced sources", the same style as
    /// `SettingsView.settingsLink`'s links.
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

    // MARK: - Features

    /// ⚠️ An INLINE selector, not a screen pushed per feature.
    ///
    /// Two reasons: five round trips to set five rows is tedious,
    /// and above all stacking a screen from Settings is the documented risky
    /// pattern on macOS (§N.1: pane painted under pushed content, AutoLayout
    /// freezes). Everything therefore fits in the row, including what
    /// justifies the choice.
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

                    // What will ACTUALLY be used, plus the warning if
                    // there is one — the information that would be missing if the
                    // detail lived behind a push.
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

    /// The status line below the picker: first the problem if there is one,
    /// otherwise the effective backend — and the reminder that data leaves
    /// the device when that's the case.
    ///
    /// ⚠️ Returns a COMPOSED `Text` (a concatenation of literal `Text`
    /// fragments), never an assembled `String` passed to a single `Text`: a
    /// `Text(LocalizedStringKey(anAlreadyResolvedString))` freezes the key on the
    /// already-translated text — the Settings language picker then never
    /// refreshes it again (`Text(LocalizedStringKey)`/`Text(LocalizedStringResource)`
    /// re-resolve against `\.locale` at render time, a frozen `String` doesn't). The same
    /// pattern as `PatrimoineView.goalSubtitle`.
    private func statusLine(for feature: AIFeature) -> Text {
        if let reason = AIEnrichmentBackend.unavailabilityReason(for: feature) {
            return Text(LocalizedStringKey(reason))
        }
        var line = effectiveLabel(for: feature)
        // ⚠️ On the RESOLVED backend, not the raw choice: "Automatic"
        // falling back to the cloud makes data leave just as much as an explicit
        // `.cloud` choice — `(choices[feature] ?? .automatic).leavesDevice`
        // always evaluated to `false` for `.automatic` and missed this case.
        if AIEnrichmentBackend.resolved(for: feature)?.leavesDevice == true {
            line = line + Text(" · ⚠️ les données quittent l'appareil")
        }
        if feature.benefitsFromImage, !AIEnrichmentBackend.supportsImageInput(for: feature) {
            // Not an error: import still works, but by OCR-ing the
            // screenshot — so losing the layout, which carries meaning.
            line = line + Text(" · captures océrisées (pas de lecture d'image)")
        }
        return line
    }

    /// True when the resolved backend isn't 100% on-device — that's
    /// when reporting consumption (network, compute, an API bill) becomes
    /// relevant. Apple Intelligence and "no AI" show nothing.
    private func showsConsumptionHint(for feature: AIFeature) -> Bool {
        switch AIEnrichmentBackend.resolved(for: feature) {
        case .localServer, .cloud: return true
        default: return false
        }
    }

    /// What will ACTUALLY be used, not just what's requested.
    ///
    /// ⚠️ The distinction matters: "Automatic" on a device where nothing is
    /// configured means "no AI at all", and the user needs to see that here
    /// rather than discovering it in front of a grayed-out button.
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
        // Orange also when it works but data leaves the device: it's
        // not an error, it's a choice that deserves to be visible at a
        // glance in the list.
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

    // MARK: - Embedded model

    /// No marketplace: a field to paste a Hugging Face link/repo, a
    /// button to analyze it (size + a RAM/storage warning BEFORE any
    /// byte is downloaded), and the list of models already downloaded
    /// (rename/activate/delete). Only one active at a time — see
    /// `EmbeddedModelService`.
    private var embeddedModelSection: some View {
        Section {
            // FIRST, and INDEPENDENT of `embeddedCandidates`/`mlxRepoCandidate`
            // (which, themselves, are lost if the screen is left then
            // reopened): this is precisely what keeps an ongoing download visible
            // after navigating away, even though the download itself was
            // never interrupted — see `EmbeddedModelDownloadStatus`.
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

            // The MAIN path, not just a fallback: any
            // file/folder already present on the device, whatever its
            // origin — not just Hugging Face.
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

    /// Visible whether the screen just opened or has stayed open since
    /// the download started — that's the whole point of reading
    /// `EmbeddedModelDownloadStatus.shared` rather than a local `@State`.
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

    /// An MLX model is ALWAYS several files — nothing to disambiguate
    /// like GGUF quantizations, so ONE row for the whole
    /// repo rather than a per-file list.
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

    /// Direct import — any source, no dependency on the network
    /// or on Hugging Face. A synchronous copy (fast, same app container),
    /// no progress bar needed unlike a download.
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

    /// Tests EVERY configured backend, not just the last one entered:
    /// with a per-feature setting, several can be in use at the
    /// same time, and knowing which of the two is broken is the useful information.
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

    // MARK: - Loading

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
            // Deliberately the RAW value (not `CloudLLMService.model`,
            // which substitutes the default): the field must stay empty until
            // the user has typed something, so the placeholder shows.
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
