import Foundation

/// Client de l'API publique recherche-entreprises.api.gouv.fr.
/// Pas de clé, pas d'auth, ~7 req/sec selon docs gov.
///
/// Privacy : seul le query string (nom du commerce ± code postal) sort de l'appareil.
/// Aucune donnée transaction n'est envoyée.
actor SireneClient {

    static let shared = SireneClient()

    private let baseURL = URL(string: "https://recherche-entreprises.api.gouv.fr/search")!
    private let session: URLSession

    /// Cache en mémoire : query → résultats. Évite les double appels dans une même session.
    /// Pas de persistance disque dans cette V1 — on peut ajouter une table SQLite plus tard.
    private var cache: [String: [SireneEstablishment]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Recherche des entreprises matchant `query`. Optionnellement filtre par code postal.
    /// - Parameters:
    ///   - query: nom du commerce (raison sociale ou enseigne)
    ///   - postalCode: code postal (5 chiffres) pour réduire le nombre de résultats
    ///   - limit: nombre maximum de résultats (1-25, défaut 10)
    /// - Returns: liste de SireneEstablishment ; vide si rien trouvé
    func search(query: String, postalCode: String? = nil, limit: Int = 10) async throws -> [SireneEstablishment] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        guard !normalized.isEmpty else { return [] }

        let cacheKey = "\(normalized)|\(postalCode ?? "")|\(limit)"
        if let cached = cache[cacheKey] { return cached }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "q", value: normalized),
            .init(name: "per_page", value: String(min(max(limit, 1), 25))),
            .init(name: "minimal", value: String(true)),
            // Privilégier les établissements ACTIFS (etat_administratif=A)
            .init(name: "etat_administratif", value: "A"),
            // Inclure les coordonnées GPS dans la réponse (sinon parfois absentes)
            .init(name: "include", value: "siege")
        ]
        if let pc = postalCode, pc.count == 5 {
            items.append(.init(name: "code_postal", value: pc))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Nemoris/1.0 (iOS app)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        print(response)
        guard let http = response as? HTTPURLResponse else {
            throw SireneError.transport("Pas de réponse HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SireneError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SireneSearchResponse.self, from: data)
        let establishments = decoded.results.compactMap { $0.toEstablishment() }

        cache[cacheKey] = establishments
        return establishments
    }

    func clearCache() {
        cache.removeAll()
    }
}

enum SireneError: LocalizedError {
    case transport(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .transport(let s): return "Réseau : \(s)"
        case .httpStatus(let code): return "HTTP \(code)"
        case .decoding(let s): return "Décodage : \(s)"
        }
    }
}
