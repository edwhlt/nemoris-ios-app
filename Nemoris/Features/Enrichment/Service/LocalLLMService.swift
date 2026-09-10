import Foundation
import Security

/// Client HTTP pour un serveur compatible OpenAI (`/v1/chat/completions`) — LM Studio,
/// Ollama, ou toute app exposant ce même contrat, tournant sur le Mac de l'utilisateur
/// (même réseau local) ou sur l'iPhone lui-même (loopback, si l'utilisateur a installé
/// une app d'inférence locale qui expose un serveur). Réutilise le prompt et le parsing
/// JSON de `EnrichmentLLMService` — le format de réponse attendu (JSON strict, même
/// schéma) est identique quel que soit le moteur d'inférence derrière.
///
/// Volontairement PAS bâti sur `ResilientHTTP`/`ProviderRateLimiter`
/// (`Services/MarketDataReliability.swift`) : ces briques sont taillées pour des APIs
/// publiques rate-limitées avec un timeout de 15s et un retry avec backoff sur 429/5xx.
/// Un serveur local n'a pas de rate limit, mais une inférence peut légitimement prendre
/// 60-90s+ — retenter après un timeout court serait à la fois une fausse erreur (le
/// modèle réfléchit encore) et une UX pire (3x l'attente pour apprendre la même chose :
/// le serveur ne répond pas).
struct LocalLLMService: Sendable {

    static let shared = LocalLLMService()

    private static let baseURLKey = "ai.localServer.baseURL"
    private static let modelKey = "ai.localServer.model"
    private static let timeout: TimeInterval = 90

    static var baseURL: String {
        get { (UserDefaults.standard.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var model: String {
        get { (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var hasConfiguration: Bool { !baseURL.isEmpty }

    private static let disableThinkingKey = "ai.localServer.disableThinking"

    /// Demander au serveur de couper le mode « raisonnement » du modèle.
    ///
    /// ⚠️ **Désactivé par défaut, et c'est délibéré.** Un modèle raisonnement
    /// bien alimenté produit ici les meilleurs résultats de tous les backends
    /// testés (qwen3.5-9b via LM Studio). Le couper d'office ferait perdre
    /// cette qualité pour se prémunir d'un cas — le modèle qui dépense tout
    /// son budget en réflexion sans jamais conclure — que le découpage en
    /// passes (`CoachPassPlanner`) traite désormais à la source, en réduisant
    /// ce qu'on lui demande d'un coup.
    ///
    /// Le réglage reste exposé comme SOUPAPE : si un serveur continue de
    /// rendre des réponses vides avec un `reasoning_content` rempli, le
    /// basculer coupe la réflexion sans changer de modèle.
    static var disableThinking: Bool {
        get { UserDefaults.standard.bool(forKey: disableThinkingKey) }
        set { UserDefaults.standard.set(newValue, forKey: disableThinkingKey) }
    }

    /// Identifie un marchand. `nil` si non configuré ou en cas d'échec réseau/parsing —
    /// même contrat de silence que `EnrichmentLLMService.identify` : l'orchestrateur et
    /// les sheets manuelles continuent simplement sans ce candidat.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        guard Self.hasConfiguration else { return nil }
        do {
            // EnrichmentLLMService est @MainActor — le `await` gère le hop d'actor pour
            // chacun de ses membres statiques, même le prompt/parsing partagés qui ne
            // touchent pas Foundation Models directement (isolation contagieuse à
            // toute la classe, pas seulement aux membres qui en ont vraiment besoin).
            let userPrompt = await EnrichmentLLMService.buildPrompt(context: context)
            let content = try await complete(
                systemPrompt: EnrichmentLLMService.instructions,
                userPrompt: userPrompt
            )
            guard var result = await EnrichmentLLMService.parseJSONResponse(content, context: context) else {
                return nil
            }
            result.source = .localLLM
            return result
        } catch {
            print("[LocalLLMService] identify error: \(error)")
            return nil
        }
    }

    /// Teste la connexion et JETTE une erreur typée — contrairement à `identify`, qui
    /// avale tout en silence, le bouton "Tester la connexion" des Réglages veut un
    /// message précis et actionnable.
    func testConnection() async throws -> String {
        guard Self.hasConfiguration else { throw LocalLLMError.notConfigured }
        let content = try await complete(
            systemPrompt: "Réponds uniquement par le mot OK.",
            userPrompt: "Ping de test de connexion depuis Nemoris."
        )
        let modelLabel = Self.model.isEmpty ? "Le serveur" : "« \(Self.model) »"
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        return "\(modelLabel) a répondu : \(preview)"
    }

    // MARK: - HTTP

    /// Complétion texte brute. Volontairement `internal` (et non `private`) :
    /// `AIEnrichmentBackend.completeText` en fait le chemin serveur local de la
    /// complétion générique, utilisée par l'extraction de relevés
    /// (`TransactionDocumentParser`) en plus de l'identification de marchands.
    /// `imageDataURL` : capture encodée en data-URL base64, pour un modèle
    /// multimodal. Le serveur reçoit alors un message à parties typées
    /// (protocole OpenAI) au lieu d'une simple chaîne.
    /// - Parameter maxTokens: budget de SORTIE. ⚠️ Longtemps omis, ce qui
    ///   laissait le serveur appliquer sa propre limite par défaut — souvent
    ///   quelques centaines de tokens, d'où des réponses coupées net sans
    ///   aucun rapport avec la taille du contexte (retour d'usage 2026-08-28).
    /// - Parameter forceDirectAnswer: coupe le mode raisonnement pour CET
    ///   appel, quel que soit le réglage de l'utilisateur. Réservé au repli
    ///   automatique déclenché après un `reasoningOnly` avéré — on ne bride
    ///   jamais le premier essai, c'est lui qui donne les meilleures analyses.
    func complete(systemPrompt: String,
                  userPrompt: String,
                  imageDataURL: String? = nil,
                  maxTokens: Int = 1_024,
                  forceDirectAnswer: Bool = false) async throws -> String {
        guard let url = URL(string: Self.baseURL + "/v1/chat/completions") else {
            throw LocalLLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = LocalLLMKeychain.load(id: LocalLLMKeychain.apiKeyID), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: Self.model.isEmpty ? "local-model" : Self.model,
            messages: [
                .init(role: "system", text: systemPrompt),
                .init(role: "user", text: userPrompt, imageDataURL: imageDataURL)
            ],
            temperature: 0.2,
            stream: false,
            max_tokens: maxTokens,
            chat_template_kwargs: (Self.disableThinking || forceDirectAnswer) ? ["enable_thinking": false] : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw LocalLLMError.timedOut
            default:
                throw LocalLLMError.serverUnreachable(urlError.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw LocalLLMError.serverUnreachable("Réponse HTTP invalide")
        }
        guard 200..<300 ~= http.statusCode else {
            throw LocalLLMError.badStatus(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let message = decoded.choices.first?.message else {
                throw LocalLLMError.emptyResponse
            }
            if !message.content.isEmpty { return message.content }
            // ⚠️ Signature MESURÉE sur trois retours d'usage (2026-08-29,
            // 09-01, 09-06, qwen3.5-9b via LM Studio) : `content` vide,
            // `reasoning_content` rempli de milliers de tokens et coupé EN
            // PLEIN MOT, `finish_reason` pourtant à "stop". Le modèle a
            // dépensé tout le budget disponible à re-dérouler les consignes
            // sans jamais écrire sa réponse.
            //
            // Une ERREUR TYPÉE, pas le texte du raisonnement rendu tel quel :
            // l'appelant doit pouvoir distinguer « ce serveur a montré sa
            // vraie limite » d'une réponse hors format, pour relancer en mode
            // dégradé au lieu d'afficher un échec (cf. `CoachService`).
            //
            // Le raisonnement voyage AVEC l'erreur : il ne contient aucun JSON
            // exploitable, mais c'est lui qui alimente le dépliant diagnostic
            // (« Voir la réponse du modèle ») si le repli échoue à son tour.
            if let reasoning = message.reasoning_content, !reasoning.isEmpty {
                throw LocalLLMError.reasoningOnly(reasoning)
            }
            throw LocalLLMError.emptyResponse
        } catch let error as LocalLLMError {
            throw error
        } catch {
            throw LocalLLMError.decodingFailed(error.localizedDescription)
        }
    }
}

// MARK: - DTOs (sous-ensemble minimal du schéma OpenAI chat completions, partagé
// par LM Studio, Ollama, et la quasi-totalité des serveurs d'inférence locaux)

private struct ChatCompletionRequest: Encodable {
    /// Le champ `content` du protocole OpenAI accepte DEUX formes : une chaîne
    /// simple, ou un tableau de parties typées quand le message porte une image.
    /// Les serveurs locaux (LM Studio, Ollama…) suivent ce contrat pour les
    /// modèles multimodaux.
    struct Message: Encodable {
        let role: String
        let text: String
        /// Image encodée en data-URL base64, `nil` pour un message texte.
        var imageDataURL: String?

        enum CodingKeys: String, CodingKey { case role, content }
        private enum PartKeys: String, CodingKey { case type, text, image_url }
        private enum ImageURLKeys: String, CodingKey { case url }

        func encode(to encoder: Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            try root.encode(role, forKey: .role)
            guard let imageDataURL else {
                // Forme scalaire : compatible avec tous les serveurs, y compris
                // les modèles purement textuels.
                try root.encode(text, forKey: .content)
                return
            }
            var parts = root.nestedUnkeyedContainer(forKey: .content)
            var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
            try textPart.encode("text", forKey: .type)
            try textPart.encode(text, forKey: .text)
            var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
            try imagePart.encode("image_url", forKey: .type)
            var urlBox = imagePart.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .image_url)
            try urlBox.encode(imageDataURL, forKey: .url)
        }
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
    /// Nom volontairement en snake_case : c'est la clé du protocole OpenAI,
    /// que les serveurs locaux implémentent tel quel.
    let max_tokens: Int
    /// Demande au serveur de couper le mode « raisonnement » du modèle, quand
    /// il honore ce champ (extension vLLM / llama.cpp récents, transmise telle
    /// quelle au template de chat Jinja).
    ///
    /// ⚠️ `nil` par DÉFAUT — donc absent du JSON, donc réflexion CONSERVÉE.
    /// Une version antérieure l'envoyait systématiquement à `false` : c'était
    /// se priver du backend qui donne les meilleurs résultats (un modèle
    /// raisonnement bien alimenté) pour parer un cas que le découpage en
    /// passes règle mieux. N'est renseigné que si l'utilisateur bascule la
    /// soupape (`LocalLLMService.disableThinking`).
    let chat_template_kwargs: [String: Bool]?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable {
            let content: String
            /// Certains modèles "thinking" (Qwen3, DeepSeek-R1…) exposent leur
            /// raisonnement dans ce champ séparé plutôt que dans `content` —
            /// extension du protocole OpenAI portée par LM Studio/vLLM/Ollama.
            /// `nil` chez tout modèle non-reasoning, donc absent sans risque.
            let reasoning_content: String?
        }
        let message: Msg
    }
    let choices: [Choice]
}

// MARK: - Erreurs

enum LocalLLMError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case serverUnreachable(String)
    case timedOut
    case badStatus(Int)
    case emptyResponse
    /// Le modèle a produit du RAISONNEMENT mais aucune réponse finale — le
    /// texte associé est ce raisonnement, conservé pour le diagnostic.
    case reasoningOnly(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Aucune adresse de serveur configurée."
        case .invalidURL:
            return "Adresse invalide — vérifiez l'URL (ex. http://192.168.1.10:1234)."
        case .serverUnreachable(let detail):
            return "Serveur injoignable — vérifiez qu'il tourne et que l'adresse est correcte. (\(detail))"
        case .timedOut:
            return "Délai dépassé — le modèle met peut-être trop de temps à répondre."
        case .badStatus(let code):
            return "Le serveur a répondu avec une erreur (HTTP \(code))."
        case .emptyResponse:
            return "Réponse vide — le modèle n'a rien renvoyé."
        case .reasoningOnly:
            return "Le modèle a réfléchi sans jamais écrire sa réponse : il a dépensé tout son budget en réflexion interne. Réduis la taille du contexte demandé, ou coupe le mode raisonnement de ce modèle."
        case .decodingFailed(let detail):
            return "Réponse illisible — le serveur ne renvoie pas un format compatible OpenAI. (\(detail))"
        }
    }
}

// MARK: - Keychain (clé API optionnelle)

/// Mêmes conventions que `BinanceKeychain` (Features/BinanceTax/BinanceTaxView.swift) :
/// helper minimal, un seul id fixe puisqu'il n'y a qu'une seule configuration par
/// appareil. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — jamais synchronisé iCloud,
/// cohérent avec le reste des secrets de ce projet (LiveSync, Binance).
enum LocalLLMKeychain {
    static let apiKeyID = "local_llm_api_key"

    static func save(_ value: String, for id: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: id]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData] = Data(value.utf8)
        attrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(id: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: id,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
