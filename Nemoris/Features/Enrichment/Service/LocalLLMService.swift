import Foundation
import Security

/// HTTP client for an OpenAI-compatible server (`/v1/chat/completions`) — LM Studio,
/// Ollama, or any app exposing that same contract, running on the user's Mac
/// (same local network) or on the iPhone itself (loopback, if the user installed
/// a local inference app that exposes a server). Reuses `EnrichmentLLMService`'s
/// prompt and JSON parsing — the expected response format (strict JSON, same
/// schema) is identical whatever the inference engine behind it.
///
/// Deliberately NOT built on `ResilientHTTP`/`ProviderRateLimiter`
/// (`Services/MarketDataReliability.swift`): those building blocks are tailored for
/// rate-limited public APIs with a 15s timeout and a retry with backoff on 429/5xx.
/// A local server has no rate limit, but an inference call can legitimately take
/// 60-90s+ — retrying after a short timeout would be both a false error (the
/// model is still thinking) and worse UX (3x the wait to learn the same thing:
/// the server isn't answering).
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

    /// Ask the server to turn off the model's "reasoning" mode.
    ///
    /// ⚠️ **Off by default, and it's deliberate.** A well-fed reasoning
    /// model produces the best results of all backends
    /// tested here (qwen3.5-9b via LM Studio). Turning it off by default would lose
    /// that quality to guard against one case — a model that spends its whole
    /// budget on reasoning without ever concluding — which chunking
    /// into passes (`CoachPassPlanner`) now handles at the source, by reducing
    /// what it's asked all at once.
    ///
    /// The setting stays exposed as a SAFETY VALVE: if a server keeps
    /// returning empty responses with a filled-in `reasoning_content`,
    /// toggling it turns off reasoning without switching models.
    static var disableThinking: Bool {
        get { UserDefaults.standard.bool(forKey: disableThinkingKey) }
        set { UserDefaults.standard.set(newValue, forKey: disableThinkingKey) }
    }

    /// Identifies a merchant. `nil` if not configured or on network/parsing failure —
    /// same silent-failure contract as `EnrichmentLLMService.identify`: the orchestrator and
    /// the manual sheets simply continue without this candidate.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        guard Self.hasConfiguration else { return nil }
        do {
            // EnrichmentLLMService is @MainActor — the `await` handles the actor hop for
            // each of its static members, even the shared prompt/parsing that don't
            // touch Foundation Models directly (isolation is contagious to the
            // whole class, not just the members that actually need it).
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

    /// Tests the connection and THROWS a typed error — unlike `identify`, which
    /// swallows everything silently, the "Test connection" button in Settings wants a
    /// precise, actionable message.
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

    /// Raw text completion. Deliberately `internal` (not `private`):
    /// `AIEnrichmentBackend.completeText` uses it as the local-server path of the
    /// generic completion, used by statement extraction
    /// (`TransactionDocumentParser`) in addition to merchant identification.
    /// `imageDataURL`: a screenshot encoded as a base64 data-URL, for a
    /// multimodal model. The server then receives a message with typed parts
    /// (OpenAI protocol) instead of a plain string.
    /// - Parameter maxTokens: OUTPUT budget. ⚠️ Long omitted, which
    ///   let the server apply its own default limit — often
    ///   a few hundred tokens, hence responses cut off outright with
    ///   no relation to context size at all (observed in real usage, 2026-08-28).
    /// - Parameter forceDirectAnswer: turns off reasoning mode for THIS
    ///   call, whatever the user's setting. Reserved for the automatic
    ///   fallback triggered after a confirmed `reasoningOnly` — the first attempt is
    ///   never throttled, it's the one that gives the best analyses.
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
            // ⚠️ Signature MEASURED on three occurrences of the same issue in real
            // usage (2026-08-29, 09-01, 09-06, qwen3.5-9b via LM Studio):
            // empty `content`, `reasoning_content` filled with thousands of
            // tokens and cut off MID-WORD, `finish_reason` nonetheless "stop".
            // The model spent its entire available budget re-reciting
            // the instructions without ever writing its answer.
            //
            // A TYPED ERROR, not the raw reasoning text handed back as-is:
            // the caller must be able to tell "this server showed its
            // true limit" apart from an out-of-format response, so it can retry in
            // a degraded mode instead of showing a failure (see `CoachService`).
            //
            // The reasoning travels WITH the error: it contains no
            // usable JSON, but it's what feeds the diagnostic panel
            // ("View the model's response") if the fallback fails too.
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

// MARK: - DTOs (a minimal subset of the OpenAI chat-completions schema, shared
// by LM Studio, Ollama, and nearly every local inference server)

private struct ChatCompletionRequest: Encodable {
    /// The OpenAI protocol's `content` field accepts TWO forms: a plain
    /// string, or an array of typed parts when the message carries an image.
    /// Local servers (LM Studio, Ollama…) follow this contract for
    /// multimodal models.
    struct Message: Encodable {
        let role: String
        let text: String
        /// Image encoded as a base64 data-URL, `nil` for a text message.
        var imageDataURL: String?

        enum CodingKeys: String, CodingKey { case role, content }
        private enum PartKeys: String, CodingKey { case type, text, image_url }
        private enum ImageURLKeys: String, CodingKey { case url }

        func encode(to encoder: Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            try root.encode(role, forKey: .role)
            guard let imageDataURL else {
                // Scalar form: compatible with every server, including
                // purely text-only models.
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
    /// Name deliberately in snake_case: it's the OpenAI protocol's
    /// key, which local servers implement as-is.
    let max_tokens: Int
    /// Asks the server to turn off the model's "reasoning" mode, when
    /// it honors this field (a vLLM / recent llama.cpp extension, passed
    /// through as-is to the Jinja chat template).
    ///
    /// ⚠️ `nil` by DEFAULT — so absent from the JSON, so reasoning is KEPT.
    /// An earlier version always sent `false`: that meant giving up the
    /// backend that gives the best results (a well-fed reasoning
    /// model) to guard against a case chunking into
    /// passes handles better. Only set if the user flips the
    /// safety valve (`LocalLLMService.disableThinking`).
    let chat_template_kwargs: [String: Bool]?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable {
            let content: String
            /// Some "thinking" models (Qwen3, DeepSeek-R1…) expose their
            /// reasoning in this separate field rather than in `content` —
            /// an OpenAI protocol extension carried by LM Studio/vLLM/Ollama.
            /// `nil` on any non-reasoning model, so absent with no risk.
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
    /// The model produced REASONING but no final answer — the
    /// associated text is that reasoning, kept for diagnostics.
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

// MARK: - Keychain (optional API key)

/// Same conventions as `BinanceKeychain` (Features/BinanceTax/BinanceTaxView.swift):
/// a minimal helper, a single fixed id since there's only one configuration per
/// device. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced to iCloud,
/// consistent with every other secret in this project (LiveSync, Binance).
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
