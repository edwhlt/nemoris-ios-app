import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Panneau Settings dédié à l'IA Apple Foundation Models.
/// Explique au user dans quel cas l'IA est utilisée, quel est l'état actuel
/// (disponible / iOS trop ancien / hardware non éligible), et rassure sur le
/// fallback (Sirene + MapKit + Companies House continuent même sans IA).
///
/// AXE H — clarifier l'UX autour de la pré-requis iOS 26 + Apple Intelligence.
struct AISettingsView: View {

    /// État détaillé de l'IA pour cet appareil.
    enum AIStatus {
        case available                  // iOS 26 + hw Apple Intelligence OK
        case iosTooOld                  // iOS < 26
        case hardwareNotEligible        // iOS 26 mais hw non Apple Intelligence
        case appleIntelligenceDisabled  // iOS 26 + hw OK mais user a désactivé AI dans Settings

        var title: String {
            switch self {
            case .available:                  return "Activée"
            case .iosTooOld:                  return "iOS 26 requis"
            case .hardwareNotEligible:        return "Appareil non compatible"
            case .appleIntelligenceDisabled:  return "Apple Intelligence désactivée"
            }
        }

        var color: Color {
            switch self {
            case .available: return AppTheme.Colors.success
            default:         return AppTheme.Colors.warning
            }
        }

        var icon: String {
            switch self {
            case .available: return "checkmark.circle.fill"
            default:         return "exclamationmark.circle.fill"
            }
        }

        var detail: String {
            switch self {
            case .available:
                return "L'IA Apple Foundation Models tourne directement sur cet appareil. Aucune donnée n'est envoyée à un serveur. Elle est utilisée pour identifier les marchands inconnus lors d'un import ou d'une recherche manuelle."
            case .iosTooOld:
                return "Cette fonctionnalité nécessite iOS 26 ou supérieur. Mettez à jour votre appareil dans Réglages → Général → Mise à jour logicielle pour en profiter."
            case .hardwareNotEligible:
                return "Apple Intelligence nécessite un iPhone 15 Pro ou plus récent (iPad M1+, Mac M1+). L'enrichissement continue de fonctionner via les annuaires d'entreprise (Sirene, Companies House, etc.) et MapKit."
            case .appleIntelligenceDisabled:
                return "Apple Intelligence est désactivée sur cet appareil. Activez-la dans Réglages iOS → Apple Intelligence & Siri pour utiliser l'IA dans Nemoris."
            }
        }
    }

    @State private var status: AIStatus = .iosTooOld

    // ── Source de l'IA (réglage propre à CET appareil, cf. AXE T) ──────────
    @State private var backendPreference: AIBackendPreference = .automatic
    @State private var localServerURL: String = ""
    @State private var localServerModel: String = ""
    @State private var localServerAPIKey: String = ""
    @State private var isTestingConnection = false
    @State private var testFeedback: String? = nil
    @State private var testFeedbackIsError = false

    var body: some View {
        // Form (pas List) : contenu statique de type réglages → rendu identique
        // sur iOS et boxes arrondies natives sur macOS via nemorisFormStyle().
        // Pas de ZStack+Color (hauteur infinie sur macOS) : fond via .background.
        Form {
            // ── Source de l'IA ────────────────────────────────────────
            Section {
                Picker("Source", selection: $backendPreference) {
                    ForEach(AIBackendPreference.allCases, id: \.self) { pref in
                        // `pref.displayName` est un `String` dynamique, pas un littéral :
                        // `Label(String, ...)` ne consulte JAMAIS Localizable.strings
                        // (seul `Label(LocalizedStringKey, ...)`/`Text("littéral")` le
                        // fait). Le wrap explicite force la résolution fr/en.
                        Label(LocalizedStringKey(pref.displayName), systemImage: pref.icon).tag(pref)
                    }
                }
                .onChange(of: backendPreference) { _, newValue in
                    AIBackendPreference.current = newValue
                    testFeedback = nil
                }

                if backendPreference == .localServer {
                    TextField("Adresse du serveur", text: $localServerURL, prompt: Text("http://192.168.1.10:1234"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: localServerURL) { _, newValue in
                            LocalLLMService.baseURL = newValue
                        }
                    TextField("Nom du modèle", text: $localServerModel, prompt: Text("ex. llama-3.2-3b-instruct"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: localServerModel) { _, newValue in
                            LocalLLMService.model = newValue
                        }
                    SecureField("Clé API (optionnel)", text: $localServerAPIKey)
                        .onChange(of: localServerAPIKey) { _, newValue in
                            LocalLLMKeychain.save(newValue, for: LocalLLMKeychain.apiKeyID)
                        }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTestingConnection {
                            HStack { ProgressView().controlSize(.small); Text("Test en cours…") }
                        } else {
                            Label("Tester la connexion", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(isTestingConnection || localServerURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let testFeedback {
                        Label(testFeedback, systemImage: testFeedbackIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(testFeedbackIsError ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                }
            } header: {
                Text("Source de l'IA")
            } footer: {
                // Même remarque : `backendFooterText` est un `String` calculé, on force
                // le passage par LocalizedStringKey pour que fr/en s'appliquent.
                Text(LocalizedStringKey(backendFooterText))
                    .font(.caption)
            }
            .listRowBackground(AppTheme.Colors.surface)

            // ── Statut actuel ─────────────────────────────────────────
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: status.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(status.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.title)
                            .font(AppTheme.Typography.titleMedium)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text("Apple Foundation Models")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, AppTheme.Spacing.xs)

                Text(status.detail)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("État actuel")
            }
            .listRowBackground(AppTheme.Colors.surface)

            // ── Comment c'est utilisé ─────────────────────────────────
            Section {
                AIUsageRow(
                    icon: "terminal",
                    title: "Lors de la création de requêtes SQL",
                    text: "Vous pouvez créer votre requête SQL afin de questionner vos données bancaires et d'investissement dans une conversation avec l'IA"
                )
                AIUsageRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Lors d'un import",
                    text: "Quand le moteur ne reconnaît pas un libellé, l'IA propose un nom canonique, une ville et un pays."
                )
                AIUsageRow(
                    icon: "magnifyingglass.circle",
                    title: "Recherche manuelle",
                    text: "Depuis la fiche d'un tier, vous pouvez relancer l'identification IA avec une requête personnalisée."
                )
            } header: {
                Text("Comment Nemoris utilise l'IA")
            } footer: {
                Text(LocalizedStringKey(usageFooterText))
                    .font(.caption)
            }
            .listRowBackground(AppTheme.Colors.surface)

            // ── Sources de secours ────────────────────────────────────
            Section {
                AIUsageRow(
                    icon: "building.columns",
                    title: "Annuaires d'entreprise",
                    text: "Sirene (FR), Companies House (UK), Zefix (CH) — configurables dans Réglages → Sources de données."
                )
                AIUsageRow(
                    icon: "map",
                    title: "MapKit",
                    text: "Recherche de POI Apple. Disponible sans iOS 26 ni Apple Intelligence."
                )
                AIUsageRow(
                    icon: "tray.full",
                    title: "Moteur embarqué Nemoris",
                    text: "Identification par embeddings BERT MiniLM sur ~200 marchands canoniques fréquents."
                )
            } header: {
                Text("Sources d'enrichissement de secours")
            } footer: {
                Text("Ces sources fonctionnent indépendamment de l'IA. Si l'IA n'est pas disponible, l'enrichissement reste fonctionnel.")
                    .font(.caption)
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Intelligence artificielle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            status = Self.detectStatus()
            backendPreference = AIBackendPreference.current
            localServerURL = LocalLLMService.baseURL
            localServerModel = LocalLLMService.model
            localServerAPIKey = LocalLLMKeychain.load(id: LocalLLMKeychain.apiKeyID) ?? ""
        }
    }

    /// Texte du footer de la section "Source de l'IA" — explique le réglage choisi
    /// et rappelle qu'il est propre à CET appareil (un Mac peut rester sur Foundation
    /// Models pendant qu'un iPhone pointe vers un serveur local, par exemple).
    private var backendFooterText: String {
        // Chaque branche est une phrase complète et FIXE (pas de concaténation
        // runtime) : c'est la clé exacte qu'il faut retrouver dans les deux
        // Localizable.strings (fr/en), cf. `Text(LocalizedStringKey(...))` ci-dessus.
        switch backendPreference {
        case .automatic:
            return "Utilise Apple Foundation Models si disponible sur cet appareil, sinon aucune IA. Ce réglage est propre à cet appareil — les autres appareils Nemoris peuvent utiliser une source différente."
        case .localServer:
            return "Nemoris envoie le libellé de la transaction à l'adresse configurée (LM Studio, Ollama, ou tout serveur compatible OpenAI). L'adresse et la clé restent sur cet appareil, rien n'est envoyé à un serveur Nemoris. Ce réglage est propre à cet appareil — les autres appareils Nemoris peuvent utiliser une source différente."
        case .off:
            return "Aucune source IA n'est appelée. L'enrichissement reste fonctionnel via Sirene, MapKit et le moteur embarqué. Ce réglage est propre à cet appareil — les autres appareils Nemoris peuvent utiliser une source différente."
        }
    }

    /// Le footer "100% on-device" de la section usage n'est vrai que pour Foundation
    /// Models (ou quand l'IA est désactivée, auquel cas la question ne se pose pas).
    private var usageFooterText: String {
        backendPreference == .localServer
            ? "Avec un serveur local, le libellé de la transaction part vers l'adresse configurée ci-dessus — pas vers un serveur Nemoris."
            : "100% on-device. Aucune donnée bancaire ne quitte l'appareil."
    }

    private func testConnection() async {
        isTestingConnection = true
        testFeedback = nil
        defer { isTestingConnection = false }
        do {
            let message = try await LocalLLMService.shared.testConnection()
            testFeedback = message
            testFeedbackIsError = false
        } catch {
            testFeedback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testFeedbackIsError = true
        }
    }

    /// Détecte l'état actuel de Foundation Models sur cet appareil.
    /// On distingue plusieurs cas pour informer précisément le user.
    private static func detectStatus() -> AIStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.isAvailable {
                return .available
            }
            // iOS 26 mais pas dispo : on essaie de discriminer hw vs réglages.
            // L'API publique expose `availability` qui peut renvoyer plusieurs cas.
            switch model.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceDisabled
            case .unavailable(.deviceNotEligible):
                return .hardwareNotEligible
            case .unavailable(.modelNotReady):
                return .appleIntelligenceDisabled // En cours de DL → traité comme "non activé"
            case .unavailable:
                return .hardwareNotEligible
            }
        }
        #endif
        return .iosTooOld
    }
}

// MARK: - Row helper

private struct AIUsageRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(text)
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
