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
    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
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
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.2,
            stream: false
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
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                throw LocalLLMError.emptyResponse
            }
            return content
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
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { let content: String }
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
