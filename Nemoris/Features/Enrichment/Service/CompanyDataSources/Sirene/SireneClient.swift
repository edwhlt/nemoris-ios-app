import Foundation

/// Client for the public recherche-entreprises.api.gouv.fr API.
/// No key, no auth, ~7 req/sec per the gov docs.
///
/// Privacy: only the query string (business name ± postal code) leaves the device.
/// No transaction data is sent at all.
actor SireneClient {

    static let shared = SireneClient()

    private let baseURL = URL(string: "https://recherche-entreprises.api.gouv.fr/search")!
    private let session: URLSession

    /// In-memory cache: query → results. Avoids double calls within the same session.
    /// No disk persistence in this V1 — a SQLite table could be added later.
    private var cache: [String: [SireneEstablishment]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Searches for companies matching `query`. Optionally filters by postal code.
    /// - Parameters:
    ///   - query: business name (legal or trade name)
    ///   - postalCode: postal code (5 digits) to reduce the number of results
    ///   - limit: max number of results (1-25, default 10)
    /// - Returns: a list of SireneEstablishment; empty if nothing found
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
            // Prefer ACTIVE establishments (etat_administratif=A)
            .init(name: "etat_administratif", value: "A"),
            // Include GPS coordinates in the response (sometimes absent otherwise)
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
