import SwiftUI
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
/// ⚠️ **Piège de localisation** (déjà payé en AXE P et AXE T) :
/// `Text(uneVariable)` / `Label(String, ...)` ne consultent JAMAIS
/// `Localizable.strings` — seuls `Text("littéral")` et
/// `Label(LocalizedStringKey, ...)` le font. Tous les libellés dynamiques de cet
/// écran (noms de backends, de fonctionnalités) doivent donc être enveloppés
/// dans `LocalizedStringKey(...)`, sinon ils restent en français sur un appareil
/// en anglais.
struct AISettingsView: View {

    @State private var choices: [AIFeature: AIBackendChoice] = [:]
    @State private var appleStatus: AppleIntelligenceStatus = .iosTooOld

    // Serveur local (AXE T)
    @State private var localBaseURL = ""
    @State private var localModel = ""
    @State private var localAPIKey = ""

    // Fournisseurs cloud
    @State private var cloudKeys: [AICloudProvider: String] = [:]
    @State private var cloudModels: [AICloudProvider: String] = [:]

    @State private var testSuccess: String?
    @State private var testError: String?
    @State private var isTesting = false

    var body: some View {
        // Form (pas List) : contenu statique de type réglages → rendu identique
        // sur iOS et boxes arrondies natives sur macOS via nemorisFormStyle().
        // Pas de ZStack+Color (hauteur infinie sur macOS) : fond via .background.
        Form {
            featuresSection
            appleSection
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
        .navigationTitle("Intelligence artificielle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
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
                    Text(LocalizedStringKey(statusLine(for: feature)))
                        .font(.caption)
                        .foregroundStyle(effectiveColor(for: feature))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedStringKey(feature.explanation))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    private func statusLine(for feature: AIFeature) -> String {
        if let reason = AIEnrichmentBackend.unavailabilityReason(for: feature) { return reason }
        var line = effectiveLabel(for: feature)
        if (choices[feature] ?? .automatic).leavesDevice {
            line += " · ⚠️ les données quittent l'appareil"
        }
        if feature.benefitsFromImage, !AIEnrichmentBackend.supportsImageInput(for: feature) {
            // Pas une erreur : l'import fonctionne, mais en océrisant la
            // capture — donc en perdant la mise en page, qui porte du sens.
            line += " · captures océrisées (pas de lecture d'image)"
        }
        return line
    }

    /// Ce qui sera RÉELLEMENT utilisé, pas seulement ce qui est demandé.
    ///
    /// ⚠️ La distinction compte : « Automatique » sur un appareil où rien n'est
    /// configuré veut dire « aucune IA », et l'utilisateur doit le voir ici
    /// plutôt que de le découvrir devant un bouton grisé.
    private func effectiveLabel(for feature: AIFeature) -> String {
        let asked = choices[feature] ?? .automatic
        guard let resolved = AIEnrichmentBackend.resolved(for: feature) else {
            return asked == .off ? "Désactivée" : "\(asked.displayName) — indisponible"
        }
        if asked == .automatic { return "Automatique → \(resolved.displayName)" }
        return resolved.displayName
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
        } header: {
            Text("Serveur local")
        } footer: {
            Text("Un serveur compatible OpenAI (LM Studio, Ollama…) sur ton Mac ou sur cet appareil. Les données restent sur ton réseau.")
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
