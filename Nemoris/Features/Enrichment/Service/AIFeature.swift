import Foundation

// MARK: - Le réglage IA devient PAR FONCTIONNALITÉ
//
// ─── Pourquoi un réglage global ne suffit plus ─────────────────────────────
//
// Une version antérieure livrait une préférence unique par appareil (Automatique / Serveur local
// / Désactivée). C'était suffisant tant qu'une seule capacité était en jeu : du
// texte.
//
// Ça ne l'est plus. Foundation Models sait lire du TEXTE depuis iOS 26, mais des
// IMAGES seulement depuis iOS 27. Un réglage global ne peut donc pas exprimer
// « sur cet iPhone en iOS 26, Foundation Models pour l'identification des
// marchands (texte), mais un serveur local pour l'import de captures (image,
// que FM ne sait pas lire ici) ». Il faut choisir entre priver une
// fonctionnalité d'IA, ou envoyer toutes les autres vers le réseau.
//
// D'où : une préférence PAR fonctionnalité, chacune déclarant ce qu'elle demande
// réellement au modèle.

// MARK: - Capacités

/// Ce qu'une fonctionnalité demande au moteur d'inférence.
struct AICapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// Complétion texte — le minimum, requis par tout le monde.
    static let text       = AICapabilities(rawValue: 1 << 0)
    /// Lecture d'une image telle quelle (pas son OCR).
    static let image      = AICapabilities(rawValue: 1 << 1)
    /// Génération guidée par schéma (`@Generable`) — propre à Foundation Models.
    static let structured = AICapabilities(rawValue: 1 << 2)
    /// Conversation multi-tours avec état conservé entre les questions.
    static let multiTurn  = AICapabilities(rawValue: 1 << 3)
}

// MARK: - Fonctionnalités

/// Les endroits de l'app qui peuvent parler à un modèle.
///
/// ⚠️ Cette liste est la SOURCE DE VÉRITÉ. Toute nouvelle fonctionnalité IA
/// doit y entrer plutôt qu'appeler un service d'inférence en direct : deux
/// d'entre elles le faisaient (le coach financier et l'assistant SQL), et
/// ignoraient donc totalement le réglage de l'utilisateur — un « Désactivée »
/// ou un « Serveur local » choisi dans les Réglages n'avait aucun effet sur
/// elles.
enum AIFeature: String, CaseIterable, Identifiable, Sendable {
    /// Identification des marchands (enrichissement des tiers).
    case merchantEnrichment
    /// Extraction d'opérations depuis un relevé bancaire ou une capture.
    case transactionImport
    /// Extraction d'ordres et de positions depuis un avis d'opéré ou un portefeuille.
    case investmentImport
    /// Coach dépenses : analyse du budget et des habitudes.
    ///
    /// ⚠️ Le `rawValue` reste « insights » alors que la fonctionnalité a
    /// changé de nature (elle ne reformule plus des analyses statistiques,
    /// elle les PRODUIT). C'est délibéré : c'est la clé sous laquelle le choix
    /// de backend est déjà persisté (`ai.backend.insights`). La renommer
    /// remettrait tous les utilisateurs en « Automatique » sans le leur dire.
    case insights
    /// Coach investissement : analyse du portefeuille.
    case investmentCoach
    /// Assistant de rédaction SQL de la console.
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

    /// Ce que l'IA apporte ici, et ce qui se passe sans elle.
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

    /// Capacités INDISPENSABLES : un backend qui ne les a pas est inutilisable ici.
    var requiredCapabilities: AICapabilities {
        switch self {
        case .sqlAssistant: return [.text, .multiTurn]
        default:            return [.text]
        }
    }

    /// Capacités qui AMÉLIORENT le résultat sans être nécessaires.
    ///
    /// ⚠️ La distinction n'est pas cosmétique : l'import de documents marche
    /// sans lecture d'image (il océrise alors la capture), donc exiger `.image`
    /// priverait d'IA les appareils en iOS 26 alors qu'ils font très bien le
    /// travail sur du texte. C'est exactement le compromis que le réglage
    /// global ne savait pas exprimer.
    var optionalCapabilities: AICapabilities {
        switch self {
        case .transactionImport, .investmentImport: return [.image, .structured]
        default:                                    return []
        }
    }

    /// Vrai si cette fonctionnalité tire un vrai bénéfice de la lecture d'image.
    var benefitsFromImage: Bool { optionalCapabilities.contains(.image) }

    /// Budget de SORTIE, en tokens.
    ///
    /// ⚠️ Indispensable, et longtemps absent côté serveur local : sans
    /// `max_tokens` dans la requête, un serveur compatible OpenAI (LM Studio,
    /// Ollama) applique SA propre limite par défaut, souvent quelques
    /// centaines de tokens. La réponse est alors coupée net quelle que soit la
    /// taille du contexte — c'est ce qui tronquait les analyses du coach en
    /// plein milieu de leur préambule (retour d'usage 2026-08-28).
    ///
    /// Les valeurs ne sont pas uniformes parce que les besoins ne le sont pas :
    /// identifier un marchand tient en trois lignes, une analyse de coach
    /// développe N recommandations argumentées.
    var maxOutputTokens: Int {
        switch self {
        case .merchantEnrichment:                 return 512
        case .transactionImport, .investmentImport: return 4_096
        // ⚠️ Un modèle "thinking" (Qwen3, DeepSeek-R1…) consomme une partie de
        // CE budget pour son raisonnement interne AVANT d'écrire la réponse
        // finale — vu en usage réel : 3 527 tokens dépensés en réflexion sur un
        // budget de 4 096, `content` resté vide. Une valeur plus large ne
        // corrige pas un modèle qui s'arrête sans avoir conclu (ça reste un
        // défaut du modèle/serveur, cf. `LocalLLMService.reasoning_content`),
        // mais réduit le risque qu'un dossier plus volumineux fasse déborder
        // un raisonnement par ailleurs complet sur le budget lui-même.
        case .insights, .investmentCoach:         return 8_192
        case .sqlAssistant:                       return 2_048
        }
    }

    /// Ordre de grandeur de ce qui part au modèle, affiché dans les Réglages
    /// quand le backend résolu n'est PAS 100 % sur l'appareil (serveur local ou
    /// cloud) — pour que l'utilisateur sache à quoi s'attendre avant que ça
    /// consomme du réseau, du temps de calcul, ou une facture API. Volontairement
    /// SANS chiffre de coût en euros (les tarifs des fournisseurs bougent plus
    /// vite que l'app) : un ordre de grandeur en tokens reste vrai plus longtemps.
    var consumptionHint: String {
        switch self {
        case .merchantEnrichment:
            return "Prompt court par marchand inconnu — quelques centaines de tokens."
        case .transactionImport, .investmentImport:
            return "Le document entier part au modèle : plusieurs milliers de tokens par page, davantage encore si elle est transmise en image plutôt qu'en texte."
        case .insights, .investmentCoach:
            // ⚠️ Corrigé : ce n'était plus vrai. Le coach n'envoie plus « un
            // prompt court à chaque ouverture du tableau de bord » — il envoie
            // un DOSSIER agrégé (~1 000 tokens) et n'est relancé qu'à la
            // demande, ou automatiquement une fois l'analyse périmée (7 jours).
            return "Un dossier agrégé de ta situation, environ un millier de tokens, à chaque analyse — à la demande ou une fois par semaine au plus."
        case .sqlAssistant:
            return "Conversation multi-tours : le contexte s'accumule au fil des questions, donc la consommation augmente avec l'échange."
        }
    }
}

// MARK: - Choix de backend

/// Fournisseurs cloud proposés.
///
/// ⚠️ Les données de la fonctionnalité concernée QUITTENT l'appareil. C'est le
/// seul backend dans ce cas, et l'UI doit le dire explicitement — le reste de
/// l'app (Sirene mis à part) est conçu pour rester local.
enum AICloudProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case openAI

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openAI: return "OpenAI"
        }
    }

    /// Modèle proposé par défaut. Modifiable par l'utilisateur : les catalogues
    /// évoluent plus vite que l'app.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-5"
        case .openAI: return "gpt-4o"
        }
    }

    var supportsImages: Bool { true }
}

/// Ce que l'utilisateur a choisi pour UNE fonctionnalité.
enum AIBackendChoice: Codable, Hashable, Sendable {
    /// Foundation Models si la capacité requise est là, sinon le premier
    /// backend configuré qui l'a, sinon rien — silencieusement.
    case automatic
    /// Foundation Models imposé. Erreur explicite si la capacité manque, plutôt
    /// qu'un repli muet : c'est ce qui permet de diagnostiquer.
    case foundationModels
    /// Serveur HTTP compatible OpenAI (LM Studio, Ollama…).
    case localServer
    /// Modèle GGUF téléchargé depuis Hugging Face et exécuté DANS l'app
    /// (`SwiftLlama`/llama.cpp) — aucun serveur externe, aucune dépendance à
    /// Apple Intelligence. Cf. `EmbeddedModelService`.
    case embeddedModel
    case cloud(AICloudProvider)
    /// Aucun appel, jamais.
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

    /// Vrai si ce choix fait sortir les données de l'appareil.
    var leavesDevice: Bool {
        if case .cloud = self { return true }
        return false
    }

    /// Options proposées dans le sélecteur, dans l'ordre d'affichage.
    static var allChoices: [AIBackendChoice] {
        [.automatic, .foundationModels, .embeddedModel, .localServer]
            + AICloudProvider.allCases.map { .cloud($0) }
            + [.off]
    }
}

// MARK: - Résolution du backend effectif

/// Ce qu'un appareil sait faire, à un instant donné.
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

/// Confronte le choix de l'utilisateur à ce que l'appareil sait réellement faire.
///
/// Moteur PUR — il ne connaît ni Foundation Models, ni le réseau, ni les
/// Réglages : on lui DONNE l'état. C'est ce qui le rend testable
/// (`run_ai_backend_tests.sh`), là où la vraie résolution dépend d'APIs
/// disponibles seulement à partir d'iOS 26 et d'un trousseau.
enum AIBackendResolver {

    /// Le backend à utiliser, ou `nil` s'il n'y en a aucun.
    static func resolve(choice: AIBackendChoice,
                        feature: AIFeature,
                        availability: AIBackendAvailability) -> AIBackendChoice? {
        switch choice {
        case .off:
            return nil

        case .foundationModels:
            // Imposé : AUCUN repli. C'est tout l'intérêt de ce choix — voir que
            // ça ne marche pas, plutôt que d'être basculé en silence ailleurs.
            return supportsFoundationModels(feature, availability) ? .foundationModels : nil

        case .localServer:
            return availability.localServer ? .localServer : nil

        case .embeddedModel:
            return availability.embeddedModel ? .embeddedModel : nil

        case .cloud(let provider):
            return availability.configuredCloudProviders.contains(provider) ? .cloud(provider) : nil

        case .automatic:
            // Ordre de préférence : le plus privé d'abord. Le modèle embarqué
            // passe AVANT le serveur local : il ne dépend d'aucune autre
            // machine et ne quitte jamais l'appareil, alors qu'un serveur
            // externe suppose une IP à joindre. On ne bascule vers le réseau
            // que faute de mieux, et vers le cloud qu'en dernier.
            if supportsFoundationModels(feature, availability) { return .foundationModels }
            if availability.embeddedModel { return .embeddedModel }
            if availability.localServer { return .localServer }
            if let provider = availability.configuredCloudProviders.first { return .cloud(provider) }
            return nil
        }
    }

    /// ⚠️ Sur les capacités REQUISES seulement. L'import de documents gagne à
    /// lire les images mais s'en passe (il océrise) : exiger `.image` le
    /// priverait d'Apple Intelligence sur tout appareil en iOS 26, alors qu'il
    /// y travaille très bien sur du texte.
    private static func supportsFoundationModels(_ feature: AIFeature,
                                                 _ availability: AIBackendAvailability) -> Bool {
        guard availability.foundationModels else { return false }
        if feature.requiredCapabilities.contains(.image),
           !availability.foundationModelsReadsImages { return false }
        return true
    }

    /// Le backend retenu sait-il lire une image ?
    static func readsImages(_ resolved: AIBackendChoice?,
                            availability: AIBackendAvailability) -> Bool {
        switch resolved {
        case .foundationModels: return availability.foundationModelsReadsImages
        // Le modèle chargé décide : un modèle purement textuel répondra une
        // erreur, et l'appelant retombera sur l'OCR.
        case .localServer:      return true
        // Scope v1 : texte seulement. Un GGUF multimodal (mmproj séparé) est
        // un pipeline distinct, non couvert — cf. `EmbeddedModelService`.
        case .embeddedModel:    return false
        case .cloud(let p):     return p.supportsImages
        case .automatic, .off, .none: return false
        }
    }
}

// MARK: - Persistance

/// Le choix de backend de chaque fonctionnalité.
///
/// ⚠️ `UserDefaults.standard`, donc PROPRE À L'APPAREIL par construction :
/// jamais touché par la sync CloudKit (`SyncSchema.syncedTables` ne liste
/// aucune table de réglages) ni par le magasin clé-valeur iCloud (jamais
/// utilisé dans ce projet, entitlement absent). Un Mac peut donc rester sur
/// Apple Intelligence pendant qu'un iPhone pointe vers un serveur local — c'est
/// le but.
enum AIFeatureSettings {

    private static func key(_ feature: AIFeature) -> String { "ai.backend.\(feature.rawValue)" }

    /// Ancienne clé globale, lue une seule fois pour reprendre le choix
    /// existant plutôt que de le perdre silencieusement à la mise à jour.
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

    /// Reprend le réglage global antérieur sur TOUTES les fonctionnalités.
    ///
    /// Un utilisateur qui avait configuré un serveur local doit le retrouver
    /// partout après la mise à jour, pas revenir à « Automatique » sans le
    /// savoir.
    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDoneKey) else { return }
        defaults.set(true, forKey: migrationDoneKey)

        guard let legacy = defaults.string(forKey: legacyGlobalKey) else { return }
        let migrated: AIBackendChoice
        switch legacy {
        case "localServer": migrated = .localServer
        case "off":         migrated = .off
        default:            return          // « automatic » = déjà le défaut
        }
        guard let data = try? JSONEncoder().encode(migrated) else { return }
        for feature in AIFeature.allCases {
            defaults.set(data, forKey: key(feature))
        }
    }
}
