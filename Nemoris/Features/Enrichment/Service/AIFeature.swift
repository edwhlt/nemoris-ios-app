import Foundation

// MARK: - The AI setting becomes PER FEATURE
//
// ─── Why a global setting isn't enough anymore ─────────────────────────────
//
// An earlier version shipped a single per-device preference (Automatic / Local server
// / Disabled). That was enough as long as a single capability was in play: plain
// text.
//
// It isn't anymore. Foundation Models can read TEXT since iOS 26, but
// IMAGES only since iOS 27. A global setting therefore can't express
// "on this iPhone running iOS 26, Foundation Models for merchant
// identification (text), but a local server for screenshot import (image,
// which FM can't read here)". You'd have to choose between depriving a
// feature of AI, or sending everything else to the network.
//
// Hence: a preference PER feature, each declaring what it actually
// needs from the model.

// MARK: - Capabilities

/// What a feature asks of the inference engine.
struct AICapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// Text completion — the baseline, required by everyone.
    static let text       = AICapabilities(rawValue: 1 << 0)
    /// Reading an image as-is (not its OCR).
    static let image      = AICapabilities(rawValue: 1 << 1)
    /// Schema-guided generation (`@Generable`) — specific to Foundation Models.
    static let structured = AICapabilities(rawValue: 1 << 2)
    /// Multi-turn conversation with state kept between questions.
    static let multiTurn  = AICapabilities(rawValue: 1 << 3)
}

// MARK: - Features

/// The places in the app that can talk to a model.
///
/// ⚠️ This list is the SOURCE OF TRUTH. Any new AI feature must
/// be added here rather than calling an inference service directly: two
/// features used to do that (the financial coach and the SQL assistant),
/// so they completely ignored the user's setting — a "Disabled"
/// or "Local server" choice made in Settings had no effect on
/// them at all.
enum AIFeature: String, CaseIterable, Identifiable, Sendable {
    /// Merchant identification (payee enrichment).
    case merchantEnrichment
    /// Extracting operations from a bank statement or a screenshot.
    case transactionImport
    /// Extracting orders and positions from a trade confirmation or a portfolio.
    case investmentImport
    /// Spending coach: analyzes budget and habits.
    ///
    /// ⚠️ The `rawValue` stays "insights" even though the feature has
    /// changed in nature (it no longer rephrases statistical analyses,
    /// it PRODUCES them). That's deliberate: it's the key under which the
    /// backend choice is already persisted (`ai.backend.insights`). Renaming it
    /// would silently reset every user to "Automatic" without telling them.
    case insights
    /// Investment coach: portfolio analysis.
    case investmentCoach
    /// SQL-writing assistant for the console.
    case sqlAssistant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merchantEnrichment: return "Identification des marchands"
        case .transactionImport:  return "Import de relevés"
        case .investmentImport:   return "Import de portefeuille"
        case .insights:           return "Coach dépenses"
        case .investmentCoach:    return "Coach investissement"
        case .sqlAssistant:       return "Assistant SQL"
        }
    }

    var icon: String {
        switch self {
        case .merchantEnrichment: return "storefront"
        case .transactionImport:  return "doc.text.magnifyingglass"
        case .investmentImport:   return "chart.line.uptrend.xyaxis"
        case .insights:           return "lightbulb"
        case .investmentCoach:    return "chart.line.uptrend.xyaxis"
        case .sqlAssistant:       return "terminal"
        }
    }

    /// What AI brings here, and what happens without it.
    var explanation: String {
        switch self {
        case .merchantEnrichment:
            return "Devine le vrai nom d'un marchand depuis un libellé bancaire. Sans IA, la recherche par registre d'entreprises et par carte continue de fonctionner."
        case .transactionImport:
            return "Lit un relevé PDF ou une capture d'écran. Sans IA, l'extraction déterministe prend le relais — moins souple sur les mises en page inhabituelles."
        case .investmentImport:
            return "Lit un avis d'opéré ou une capture de portefeuille. Sans IA, seul l'ancrage par code ISIN fonctionne, et les captures de portefeuille ne sont pas exploitables."
        case .insights:
            return "Analyse tes dépenses, tes charges et tes enveloppes, puis propose des actions chiffrées. Sans IA, seule la détection statistique à seuils fixes reste disponible."
        case .investmentCoach:
            return "Analyse ton portefeuille : concentration, liquidités dormantes, frais, cohérence avec tes objectifs. Sans IA, aucune recommandation n'est produite."
        case .sqlAssistant:
            return "Rédige des requêtes SQL en conversation. Sans IA, la console reste utilisable à la main."
        }
    }

    /// REQUIRED capabilities: a backend that lacks them is unusable here.
    var requiredCapabilities: AICapabilities {
        switch self {
        case .sqlAssistant: return [.text, .multiTurn]
        default:            return [.text]
        }
    }

    /// Capabilities that IMPROVE the result without being necessary.
    ///
    /// ⚠️ The distinction isn't cosmetic: document import works
    /// fine without image reading (it OCRs the screenshot then), so requiring
    /// `.image` would deprive iOS 26 devices of AI even though they do
    /// perfectly well on text. That's exactly the tradeoff the
    /// global setting couldn't express.
    var optionalCapabilities: AICapabilities {
        switch self {
        case .transactionImport, .investmentImport: return [.image, .structured]
        default:                                    return []
        }
    }

    /// True if this feature gets a real benefit from reading an image.
    var benefitsFromImage: Bool { optionalCapabilities.contains(.image) }

    /// OUTPUT budget, in tokens.
    ///
    /// ⚠️ Essential, and missing on the local-server side for a long time: without
    /// `max_tokens` in the request, an OpenAI-compatible server (LM Studio,
    /// Ollama) applies its own default limit, often a few
    /// hundred tokens. The response is then cut off outright regardless of
    /// context size — which is what truncated coach analyses in
    /// the middle of their preamble (observed in real usage, 2026-08-28).
    ///
    /// The values aren't uniform because the needs aren't either:
    /// identifying a merchant fits in three lines, a coach analysis
    /// develops N argued recommendations.
    var maxOutputTokens: Int {
        switch self {
        case .merchantEnrichment:                 return 512
        case .transactionImport, .investmentImport: return 4_096
        // ⚠️ A "thinking" model (Qwen3, DeepSeek-R1…) spends part of
        // THIS budget on its internal reasoning BEFORE writing the
        // final answer — seen in real usage: 3,527 tokens spent on
        // reasoning out of a 4,096 budget, `content` left empty. A larger value
        // doesn't fix a model that stops without ever concluding (that stays
        // a model/server flaw, see `LocalLLMService.reasoning_content`),
        // but it reduces the risk of a larger document making an
        // otherwise complete reasoning pass overflow the budget itself.
        case .insights, .investmentCoach:         return 8_192
        case .sqlAssistant:                       return 2_048
        }
    }

    /// Order of magnitude of what goes to the model, shown in Settings
    /// when the resolved backend is NOT 100% on-device (local server or
    /// cloud) — so the user knows what to expect before it
    /// consumes network, compute time, or an API bill. Deliberately
    /// WITHOUT a cost figure in euros (providers' rates move faster
    /// than the app): an order of magnitude in tokens stays true longer.
    var consumptionHint: String {
        switch self {
        case .merchantEnrichment:
            return "Prompt court par marchand inconnu — quelques centaines de tokens."
        case .transactionImport, .investmentImport:
            return "Le document entier part au modèle : plusieurs milliers de tokens par page, davantage encore si elle est transmise en image plutôt qu'en texte."
        case .insights, .investmentCoach:
            // ⚠️ Fixed: this was no longer true. The coach no longer sends "a
            // short prompt on every dashboard load" — it sends
            // an aggregated BRIEF (~1,000 tokens) and only re-runs on
            // demand, or automatically once the analysis goes stale (7 days).
            return "Un dossier agrégé de ta situation, environ un millier de tokens, à chaque analyse — à la demande ou une fois par semaine au plus."
        case .sqlAssistant:
            return "Conversation multi-tours : le contexte s'accumule au fil des questions, donc la consommation augmente avec l'échange."
        }
    }
}

// MARK: - Choix de backend

/// Cloud providers offered.
///
/// ⚠️ The data for the feature involved LEAVES the device. It's the
/// only backend in that case, and the UI must say so explicitly — the rest
/// of the app (Sirene aside) is designed to stay local.
enum AICloudProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case openAI

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openAI: return "OpenAI"
        }
    }

    /// Default suggested model. Editable by the user: catalogs
    /// evolve faster than the app.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-5"
        case .openAI: return "gpt-4o"
        }
    }

    var supportsImages: Bool { true }
}

/// What the user chose for ONE feature.
enum AIBackendChoice: Codable, Hashable, Sendable {
    /// Foundation Models if the required capability is there, otherwise the
    /// first configured backend that has it, otherwise nothing — silently.
    case automatic
    /// Foundation Models forced. An explicit error if the capability is
    /// missing, rather than a silent fallback — that's what makes it diagnosable.
    case foundationModels
    /// Serveur HTTP compatible OpenAI (LM Studio, Ollama…).
    case localServer
    /// A GGUF model downloaded from Hugging Face and run INSIDE the app
    /// (`SwiftLlama`/llama.cpp) — no external server, no dependency on
    /// Apple Intelligence. See `EmbeddedModelService`.
    case embeddedModel
    case cloud(AICloudProvider)
    /// No call, ever.
    case off

    var displayName: String {
        switch self {
        case .automatic:        return "Automatique"
        case .foundationModels: return "Apple Intelligence"
        case .localServer:      return "Serveur local"
        case .embeddedModel:    return "Modèle embarqué"
        case .cloud(let p):     return p.displayName
        case .off:              return "Désactivée"
        }
    }

    var icon: String {
        switch self {
        case .automatic:        return "sparkles"
        case .foundationModels: return "apple.logo"
        case .localServer:      return "server.rack"
        case .embeddedModel:    return "internaldrive"
        case .cloud:            return "cloud"
        case .off:              return "slash.circle"
        }
    }

    /// True if this choice makes data leave the device.
    var leavesDevice: Bool {
        if case .cloud = self { return true }
        return false
    }

    /// Options offered in the picker, in display order.
    static var allChoices: [AIBackendChoice] {
        [.automatic, .foundationModels, .embeddedModel, .localServer]
            + AICloudProvider.allCases.map { .cloud($0) }
            + [.off]
    }
}

// MARK: - Resolving the effective backend

/// What a device can actually do, at a given point in time.
struct AIBackendAvailability: Sendable, Hashable {
    var foundationModels = false
    var foundationModelsReadsImages = false
    var localServer = false
    var embeddedModel = false
    var configuredCloudProviders: [AICloudProvider] = []

    init(foundationModels: Bool = false,
         foundationModelsReadsImages: Bool = false,
         localServer: Bool = false,
         embeddedModel: Bool = false,
         configuredCloudProviders: [AICloudProvider] = []) {
        self.foundationModels = foundationModels
        self.foundationModelsReadsImages = foundationModelsReadsImages
        self.localServer = localServer
        self.embeddedModel = embeddedModel
        self.configuredCloudProviders = configuredCloudProviders
    }
}

/// Confronts the user's choice against what the device can actually do.
///
/// PURE engine — it knows neither Foundation Models, nor the network, nor
/// Settings: the state is GIVEN to it. That's what makes it testable
/// (`run_ai_backend_tests.sh`), whereas real resolution depends on APIs
/// only available from iOS 26 onward and on a keychain.
enum AIBackendResolver {

    /// The backend to use, or `nil` if there is none.
    static func resolve(choice: AIBackendChoice,
                        feature: AIFeature,
                        availability: AIBackendAvailability) -> AIBackendChoice? {
        switch choice {
        case .off:
            return nil

        case .foundationModels:
            // Forced: NO fallback at all. That's the whole point of this choice —
            // seeing that it doesn't work, rather than being silently switched elsewhere.
            return supportsFoundationModels(feature, availability) ? .foundationModels : nil

        case .localServer:
            return availability.localServer ? .localServer : nil

        case .embeddedModel:
            return availability.embeddedModel ? .embeddedModel : nil

        case .cloud(let provider):
            return availability.configuredCloudProviders.contains(provider) ? .cloud(provider) : nil

        case .automatic:
            // Preference order: the most private first. The embedded model
            // comes BEFORE the local server: it depends on no other
            // machine and never leaves the device, whereas an external
            // server assumes an IP to reach. We only switch to the network
            // for lack of anything better, and to the cloud only as a last resort.
            if supportsFoundationModels(feature, availability) { return .foundationModels }
            if availability.embeddedModel { return .embeddedModel }
            if availability.localServer { return .localServer }
            if let provider = availability.configuredCloudProviders.first { return .cloud(provider) }
            return nil
        }
    }

    /// ⚠️ On REQUIRED capabilities only. Document import benefits from
    /// reading images but can do without (it OCRs then): requiring
    /// `.image` would deprive Apple Intelligence of any iOS 26 device, even
    /// though it works very well there on text.
    private static func supportsFoundationModels(_ feature: AIFeature,
                                                 _ availability: AIBackendAvailability) -> Bool {
        guard availability.foundationModels else { return false }
        if feature.requiredCapabilities.contains(.image),
           !availability.foundationModelsReadsImages { return false }
        return true
    }

    /// Can the chosen backend read an image?
    static func readsImages(_ resolved: AIBackendChoice?,
                            availability: AIBackendAvailability) -> Bool {
        switch resolved {
        case .foundationModels: return availability.foundationModelsReadsImages
        // The loaded model decides: a purely text-only model will answer with
        // an error, and the caller will fall back to OCR.
        case .localServer:      return true
        // v1 scope: text only. A multimodal GGUF (a separate mmproj) is
        // a distinct, uncovered pipeline — see `EmbeddedModelService`.
        case .embeddedModel:    return false
        case .cloud(let p):     return p.supportsImages
        case .automatic, .off, .none: return false
        }
    }
}

// MARK: - Persistance

/// Each feature's backend choice.
///
/// ⚠️ `UserDefaults.standard`, so DEVICE-SPECIFIC by construction:
/// never touched by CloudKit sync (`SyncSchema.syncedTables` lists no
/// settings table) nor by the iCloud key-value store (never
/// used in this project, entitlement absent). A Mac can therefore stay on
/// Apple Intelligence while an iPhone points at a local server — that's
/// the goal.
enum AIFeatureSettings {

    private static func key(_ feature: AIFeature) -> String { "ai.backend.\(feature.rawValue)" }

    /// Old global key, read once to carry over the existing choice
    /// rather than silently losing it.
    private static let legacyGlobalKey = "ai.backendPreference"
    private static let migrationDoneKey = "ai.backend.migratedToPerFeature"

    static func choice(for feature: AIFeature) -> AIBackendChoice {
        migrateLegacyIfNeeded()
        guard let raw = UserDefaults.standard.data(forKey: key(feature)),
              let decoded = try? JSONDecoder().decode(AIBackendChoice.self, from: raw) else {
            return .automatic
        }
        return decoded
    }

    static func setChoice(_ choice: AIBackendChoice, for feature: AIFeature) {
        migrateLegacyIfNeeded()
        guard let data = try? JSONEncoder().encode(choice) else { return }
        UserDefaults.standard.set(data, forKey: key(feature))
    }

    /// Carries over the previous global setting to EVERY feature.
    ///
    /// A user who had configured a local server must find it
    /// everywhere after the update, not fall back to "Automatic" without
    /// knowing it.
    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDoneKey) else { return }
        defaults.set(true, forKey: migrationDoneKey)

        guard let legacy = defaults.string(forKey: legacyGlobalKey) else { return }
        let migrated: AIBackendChoice
        switch legacy {
        case "localServer": migrated = .localServer
        case "off":         migrated = .off
        default:            return          // "automatic" = already the default
        }
        guard let data = try? JSONEncoder().encode(migrated) else { return }
        for feature in AIFeature.allCases {
            defaults.set(data, forKey: key(feature))
        }
    }
}
