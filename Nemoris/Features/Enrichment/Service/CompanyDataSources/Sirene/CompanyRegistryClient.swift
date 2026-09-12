import Foundation

/// Client for the public recherche-entreprises.api.gouv.fr API.
/// No key, no auth, ~7 req/s (paced by `RemoteProvider.sireneGouv`).
///
/// Privacy: only the CLEANED-UP business name leaves the device, plus possibly a
/// geographic filter. Never the raw bank label — it carries transaction
/// references and card numbers. Guaranteed by the type: this client only accepts
/// a `CompanyRegistryQuery`, which only `MerchantQueryPlanner` knows how to build.
///
/// Replaces the old `SireneClient`, which took a free-form string (so the whole
/// label) and only had an in-memory cache with no TTL.
actor CompanyRegistryClient {

    static let shared = CompanyRegistryClient()

    private let baseURL = URL(string: "https://recherche-entreprises.api.gouv.fr/search")!
    private let nearPointURL = URL(string: "https://recherche-entreprises.api.gouv.fr/near_point")!

    /// Results cached to disk. An EMPTY result is cached too, more briefly:
    /// a query that returns nothing is exactly the one at risk of being replayed in a loop.
    /// Same house precedent as `MerchantLogoService.failedDomains`.
    private struct CachedSearch: Codable, Sendable {
        let companies: [CachedCompany]
        let fetchedAt: Date
        var isEmpty: Bool { companies.isEmpty }
    }

    private var memory: [String: CachedSearch] = [:]

    private static let hitTTL: TimeInterval = 14 * 24 * 3600   // 14 jours
    private static let emptyTTL: TimeInterval = 3 * 24 * 3600  //  3 jours

    // MARK: - Search

    /// Runs a typed query. Returns companies with their matched establishments.
    func search(_ query: CompanyRegistryQuery) async throws -> [CompanyMatch] {
        let key = query.canonicalKey
        if let cached = memory[key], !isStale(cached) {
            return cached.companies.map(\.asMatch)
        }

        var items: [URLQueryItem] = [
            .init(name: "q", value: query.q),
            .init(name: "per_page", value: String(min(max(query.perPage, 1), 25))),
            // ⚠️ ORDER MATTERS: `minimal` MUST come before `include`, otherwise the API
            // responds "Please indicate whether you want a minimal response with the
            // minimal=True filter before specifying the fields to include."
            // `URLComponents.queryItems` preserves insertion order: don't sort here.
            .init(name: "minimal", value: "true"),
            .init(name: "include", value: "siege,matching_etablissements"),
            .init(name: "limite_matching_etablissements",
                  value: String(min(max(query.limiteMatchingEtablissements, 1), 100)))
        ]
        if let etat = query.etatAdministratif {
            items.append(.init(name: "etat_administratif", value: etat))
        }
        if let commune = query.codeCommune { items.append(.init(name: "code_commune", value: commune)) }
        if let postal = query.codePostal { items.append(.init(name: "code_postal", value: postal)) }
        if let dep = query.departement { items.append(.init(name: "departement", value: dep)) }

        let companies = try await fetch(url: baseURL, items: items)
        store(key: key, companies: companies)
        return companies
    }

    /// Geographic-proximity search — a last resort when no name-based query
    /// returned anything and the commune's centroid is known.
    func searchNearPoint(latitude: Double, longitude: Double,
                         radiusKm: Double, perPage: Int) async throws -> [CompanyMatch] {
        let key = "near|\(latitude)|\(longitude)|\(radiusKm)|\(perPage)"
        if let cached = memory[key], !isStale(cached) {
            return cached.companies.map(\.asMatch)
        }
        let items: [URLQueryItem] = [
            .init(name: "lat", value: String(latitude)),
            .init(name: "long", value: String(longitude)),
            .init(name: "radius", value: String(radiusKm)),
            .init(name: "per_page", value: String(min(max(perPage, 1), 25))),
            .init(name: "minimal", value: "true"),
            .init(name: "include", value: "siege")
        ]
        let companies = try await fetch(url: nearPointURL, items: items)
        store(key: key, companies: companies)
        return companies
    }

    func clearCache() { memory.removeAll() }

    // MARK: - Interne

    private func fetch(url: URL, items: [URLQueryItem]) async throws -> [CompanyMatch] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let finalURL = components.url else { return [] }

        var request = URLRequest(url: finalURL)
        request.setValue("Nemoris/1.0 (iOS app)", forHTTPHeaderField: "User-Agent")

        // Pacing + 429 circuit breaker + backoff shared with the rest of the app.
        let data = try await ResilientHTTP.send(request, provider: .sireneGouv, timeout: 12)
        let decoded = try JSONDecoder().decode(SireneSearchResponse.self, from: data)
        return decoded.results.compactMap { $0.asCompanyMatch() }
    }

    private func store(key: String, companies: [CompanyMatch]) {
        memory[key] = CachedSearch(companies: companies.map(CachedCompany.init), fetchedAt: Date())
    }

    private func isStale(_ cached: CachedSearch) -> Bool {
        let age = Date().timeIntervalSince(cached.fetchedAt)
        return age > (cached.isEmpty ? Self.emptyTTL : Self.hitTTL)
    }
}

// MARK: - Projection cachable

/// `CompanyMatch` is `Sendable` but not `Codable` (it carries business types).
/// This projection lets us persist the cache without constraining the domain model.
private struct CachedCompany: Codable, Sendable {
    let providerId: String
    let siren: String
    let legalName: String
    let nomComplet: String?
    let nafCode: String?
    let isActive: Bool
    let establishmentCount: Int?
    let openEstablishmentCount: Int?
    let headquarters: CachedEstablishment?
    let establishments: [CachedEstablishment]

    init(_ match: CompanyMatch) {
        providerId = match.providerId
        siren = match.siren
        legalName = match.legalName
        nomComplet = match.nomComplet
        nafCode = match.nafCode
        isActive = match.isActive
        establishmentCount = match.establishmentCount
        openEstablishmentCount = match.openEstablishmentCount
        headquarters = match.headquarters.map(CachedEstablishment.init)
        establishments = match.establishments.map(CachedEstablishment.init)
    }

    var asMatch: CompanyMatch {
        CompanyMatch(
            providerId: providerId, siren: siren, legalName: legalName, nomComplet: nomComplet,
            nafCode: nafCode, isActive: isActive, creationDate: nil,
            establishmentCount: establishmentCount, openEstablishmentCount: openEstablishmentCount,
            headquarters: headquarters?.asEstablishment,
            establishments: establishments.map(\.asEstablishment)
        )
    }
}

private struct CachedEstablishment: Codable, Sendable {
    let id: String
    let address: String?
    let postalCode: String?
    let city: String?
    let enseignes: [String]
    let nomCommercial: String?
    let isHeadquarters: Bool
    let isFormerHeadquarters: Bool
    let isActive: Bool
    let nafCode: String?
    let latitude: Double?
    let longitude: Double?

    init(_ e: Establishment) {
        id = e.id; address = e.address; postalCode = e.postalCode; city = e.city
        enseignes = e.enseignes; nomCommercial = e.nomCommercial
        isHeadquarters = e.isHeadquarters; isFormerHeadquarters = e.isFormerHeadquarters
        isActive = e.isActive; nafCode = e.nafCode
        latitude = e.latitude; longitude = e.longitude
    }

    var asEstablishment: Establishment {
        Establishment(
            id: id, address: address, postalCode: postalCode, city: city,
            enseignes: enseignes, nomCommercial: nomCommercial,
            isHeadquarters: isHeadquarters, isFormerHeadquarters: isFormerHeadquarters,
            isActive: isActive, nafCode: nafCode, latitude: latitude, longitude: longitude
        )
    }
}

// MARK: - Decoding → domain

extension SireneCompany {
    /// Converts the raw response into a `CompanyMatch`, establishments included.
    func asCompanyMatch() -> CompanyMatch? {
        guard let siren, !siren.isEmpty,
              let legal = nomRaisonSociale ?? nomComplet, !legal.isEmpty else { return nil }

        let hq = siege?.asEstablishment(fallbackNaf: activitePrincipale, isHeadquarters: true)
        let matched = (matchingEtablissements ?? [])
            .compactMap { $0.asEstablishment(fallbackNaf: activitePrincipale) }

        return CompanyMatch(
            providerId: "sirene_fr",
            siren: siren,
            legalName: legal,
            nomComplet: nomComplet,
            nafCode: activitePrincipale ?? siege?.activitePrincipale,
            isActive: etatAdministratif == "A",
            creationDate: Self.parseDate(dateCreation),
            establishmentCount: nombreEtablissements,
            openEstablishmentCount: nombreEtablissementsOuverts,
            headquarters: hq,
            establishments: matched
        )
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: s)
    }
}

extension SireneEtablissement {
    func asEstablishment(fallbackNaf: String?, isHeadquarters: Bool? = nil) -> Establishment? {
        guard let siret, !siret.isEmpty else { return nil }
        return Establishment(
            id: siret,
            address: adresse,
            postalCode: codePostal,
            city: libelleCommune,
            enseignes: listeEnseignes?.filter { !$0.isEmpty } ?? [],
            nomCommercial: nomCommercial,
            isHeadquarters: isHeadquarters ?? (estSiege ?? false),
            isFormerHeadquarters: ancienSiege ?? false,
            // Absent from a matched establishment's payload ⇒ active (the call already filters
            // on etat_administratif=A on the company side).
            isActive: etatAdministratif.map { $0 == "A" } ?? true,
            nafCode: activitePrincipale ?? fallbackNaf,
            latitude: latitude.flatMap(Double.init),
            longitude: longitude.flatMap(Double.init)
        )
    }
}

extension SireneSiege {
    func asEstablishment(fallbackNaf: String?, isHeadquarters: Bool) -> Establishment? {
        guard let siret, !siret.isEmpty else { return nil }
        return Establishment(
            id: siret,
            address: adresse,
            postalCode: codePostal,
            city: libelleCommune,
            enseignes: listeEnseignes?.filter { !$0.isEmpty } ?? [],
            nomCommercial: nomCommercial,
            isHeadquarters: isHeadquarters,
            isFormerHeadquarters: false,
            isActive: true,
            nafCode: activitePrincipale ?? fallbackNaf,
            latitude: latitude.flatMap(Double.init),
            longitude: longitude.flatMap(Double.init)
        )
    }
}
