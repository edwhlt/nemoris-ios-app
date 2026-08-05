import Foundation
import Security

/// Client HTTP vers un fournisseur cloud — Claude (Anthropic) ou OpenAI —, avec
/// la clé API de l'utilisateur.
///
/// ⚠️ **Seul backend qui fait sortir les données de l'appareil.** Le libellé
/// bancaire, le relevé ou la capture concernés sont transmis au fournisseur. Ce
/// n'est proposé que fonctionnalité par fonctionnalité, jamais globalement, et
/// l'UI l'affiche explicitement. Le reste de l'app est conçu pour rester local.
///
/// Volontairement bâti sur le même modèle que `LocalLLMService` (et pas sur
/// `ResilientHTTP`, taillé pour les APIs de cours de bourse rate-limitées) :
/// timeout long, aucun retry automatique. Une inférence lente n'est pas une
/// erreur, et retenter triplerait l'attente pour apprendre la même chose.
///
/// Les deux fournisseurs ont des contrats DIFFÉRENTS, d'où deux encodages :
///   • OpenAI  → `/v1/chat/completions`, messages à rôles, `Authorization: Bearer`
///   • Claude  → `/v1/messages`, `system` hors du tableau de messages,
///               en-têtes `x-api-key` + `anthropic-version`
struct CloudLLMService: Sendable {

    let provider: AICloudProvider

    private static let timeout: TimeInterval = 120

    // MARK: - Configuration

    private static func modelKey(_ provider: AICloudProvider) -> String {
        "ai.cloud.\(provider.rawValue).model"
    }

    static func model(for provider: AICloudProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(provider))?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    static func setModel(_ value: String, for provider: AICloudProvider) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces),
                                  forKey: modelKey(provider))
    }

    /// Une clé API est-elle enregistrée ? C'est la seule condition d'usage —
    /// pas d'URL à saisir, contrairement au serveur local.
    static func hasConfiguration(_ provider: AICloudProvider) -> Bool {
        !(CloudLLMKeychain.load(provider) ?? "").isEmpty
    }

    // MARK: - Identification de marchand

    /// Même contrat de silence que les autres backends : `nil` en cas d'échec,
    /// l'appelant continue sans ce candidat.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        do {
            let userPrompt = await EnrichmentLLMService.buildPrompt(context: context)
            let content = try await complete(
                systemPrompt: EnrichmentLLMService.instructions,
                userPrompt: userPrompt)
            guard var result = await EnrichmentLLMService.parseJSONResponse(content, context: context) else {
                return nil
            }
            result.source = .cloudLLM
            return result
        } catch {
            print("[CloudLLMService] identify error: \(error)")
            return nil
        }
    }

    /// Teste la clé et JETTE une erreur typée — le bouton « Tester » des
    /// Réglages a besoin d'un message actionnable, pas d'un silence.
    func testConnection() async throws -> String {
        let content = try await complete(systemPrompt: "Réponds uniquement par le mot OK.",
                                         userPrompt: "Ping de test depuis Nemoris.")
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        return "« \(Self.model(for: provider)) » a répondu : \(preview)"
    }

    // MARK: - Complétion

    func complete(systemPrompt: String,
                  userPrompt: String,
                  imageDataURL: String? = nil) async throws -> String {
        guard let apiKey = CloudLLMKeychain.load(provider), !apiKey.isEmpty else {
            throw CloudLLMError.missingAPIKey(provider.displayName)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider {
        case .claude:
            // ⚠️ Anthropic n'utilise PAS `Authorization: Bearer`, et
            // `anthropic-version` est OBLIGATOIRE — sans lui la requête est
            // rejetée avec un 400 peu parlant.
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(
                ClaudeRequest(model: Self.model(for: provider),
                              system: systemPrompt,
                              userText: userPrompt,
                              imageDataURL: imageDataURL))
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                OpenAIRequest(model: Self.model(for: provider),
                              systemPrompt: systemPrompt,
                              userText: userPrompt,
                              imageDataURL: imageDataURL))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw urlError.code == .timedOut
                ? CloudLLMError.timedOut
                : CloudLLMError.unreachable(urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudLLMError.unreachable("Réponse HTTP invalide")
        }
        guard 200..<300 ~= http.statusCode else {
            // Le corps d'erreur porte le vrai motif (clé invalide, quota,
            // modèle inconnu) : le remonter évite un « HTTP 400 » opaque.
            throw CloudLLMError.badStatus(http.statusCode, Self.errorMessage(from: data))
        }

        let content: String?
        switch provider {
        case .claude: content = try? JSONDecoder().decode(ClaudeResponse.self, from: data).text
        case .openAI: content = try? JSONDecoder().decode(OpenAIResponse.self, from: data).text
        }
        guard let content, !content.isEmpty else { throw CloudLLMError.emptyResponse }
        return content
    }

    private var endpoint: URL {
        switch provider {
        case .claude: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    /// Extrait `error.message`, présent chez les deux fournisseurs.
    private static func errorMessage(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
    }
}

// MARK: - DTO Claude (Messages API)

private struct ClaudeRequest: Encodable {
    let model: String
    let system: String
    let userText: String
    let imageDataURL: String?

    enum CodingKeys: String, CodingKey { case model, system, messages, max_tokens, temperature }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode(model, forKey: .model)
        // Chez Anthropic, les instructions système sont un champ de premier
        // niveau — pas un message de rôle « system » comme chez OpenAI.
        try root.encode(system, forKey: .system)
        try root.encode(4096, forKey: .max_tokens)
        try root.encode(0.2, forKey: .temperature)

        var messages = root.nestedUnkeyedContainer(forKey: .messages)
        var message = messages.nestedContainer(keyedBy: MessageKeys.self)
        try message.encode("user", forKey: .role)
        var parts = message.nestedUnkeyedContainer(forKey: .content)

        if let imageDataURL, let payload = Self.base64Payload(from: imageDataURL) {
            // ⚠️ Anthropic veut les octets base64 NUS plus un `media_type`
            // séparé — pas la data-URL complète attendue par OpenAI.
            var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
            try imagePart.encode("image", forKey: .type)
            var source = imagePart.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(payload.mediaType, forKey: .media_type)
            try source.encode(payload.base64, forKey: .data)
        }
        var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
        try textPart.encode("text", forKey: .type)
        try textPart.encode(userText, forKey: .text)
    }

    private enum MessageKeys: String, CodingKey { case role, content }
    private enum PartKeys: String, CodingKey { case type, text, source }
    private enum SourceKeys: String, CodingKey { case type, media_type, data }

    /// `data:image/png;base64,XXXX` → (`image/png`, `XXXX`).
    static func base64Payload(from dataURL: String) -> (mediaType: String, base64: String)? {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ","),
              let semicolon = dataURL.firstIndex(of: ";") else { return nil }
        let mediaType = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<semicolon])
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        return (mediaType, base64)
    }
}

private struct ClaudeResponse: Decodable {
    struct Block: Decodable { let type: String; let text: String? }
    let content: [Block]
    /// Une réponse peut contenir plusieurs blocs : on concatène le texte.
    var text: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

// MARK: - DTO OpenAI

private struct OpenAIRequest: Encodable {
    let model: String
    let systemPrompt: String
    let userText: String
    let imageDataURL: String?

    enum CodingKeys: String, CodingKey { case model, messages, temperature }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode(model, forKey: .model)
        try root.encode(0.2, forKey: .temperature)

        var messages = root.nestedUnkeyedContainer(forKey: .messages)
        var system = messages.nestedContainer(keyedBy: MessageKeys.self)
        try system.encode("system", forKey: .role)
        try system.encode(systemPrompt, forKey: .content)

        var user = messages.nestedContainer(keyedBy: MessageKeys.self)
        try user.encode("user", forKey: .role)
        guard let imageDataURL else {
            try user.encode(userText, forKey: .content)
            return
        }
        var parts = user.nestedUnkeyedContainer(forKey: .content)
        var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
        try textPart.encode("text", forKey: .type)
        try textPart.encode(userText, forKey: .text)
        var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
        try imagePart.encode("image_url", forKey: .type)
        var urlBox = imagePart.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .image_url)
        try urlBox.encode(imageDataURL, forKey: .url)
    }

    private enum MessageKeys: String, CodingKey { case role, content }
    private enum PartKeys: String, CodingKey { case type, text, image_url }
    private enum ImageURLKeys: String, CodingKey { case url }
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
    var text: String { choices.first?.message.content ?? "" }
}

// MARK: - Erreurs

enum CloudLLMError: Error, LocalizedError {
    case missingAPIKey(String)
    case unreachable(String)
    case timedOut
    case badStatus(Int, String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Aucune clé API enregistrée pour \(provider)."
        case .unreachable(let detail):
            return "Fournisseur injoignable — vérifie ta connexion. (\(detail))"
        case .timedOut:
            return "Délai dépassé — le modèle met trop de temps à répondre."
        case .badStatus(let code, let message):
            if let message, !message.isEmpty { return "Erreur du fournisseur : \(message)" }
            return "Le fournisseur a répondu avec une erreur (HTTP \(code))."
        case .emptyResponse:
            return "Réponse vide — le modèle n'a rien renvoyé."
        }
    }
}

// MARK: - Keychain

/// Une clé par fournisseur. Mêmes conventions que `LocalLLMKeychain` :
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, jamais synchronisé iCloud —
/// cohérent avec tous les autres secrets du projet (LiveSync, Binance).
enum CloudLLMKeychain {
    private static func account(_ provider: AICloudProvider) -> String {
        "cloud_llm_api_key_\(provider.rawValue)"
    }

    static func save(_ value: String, for provider: AICloudProvider) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account(provider)
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData] = Data(value.utf8)
        attrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(_ provider: AICloudProvider) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account(provider),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
