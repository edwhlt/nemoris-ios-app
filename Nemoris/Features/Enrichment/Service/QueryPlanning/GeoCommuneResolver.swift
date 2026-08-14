import Foundation

/// Résout un fragment de libellé en commune française via `geo.api.gouv.fr`.
/// Sans clé, sans compte.
///
/// POURQUOI UNE API PLUTÔT QU'UNE LISTE EN DUR
///
/// Le champ localité des relevés bancaires est TRONQUÉ en largeur fixe (~13 caractères).
/// Aucune correspondance exacte sur un dictionnaire ne peut le reconnaître. L'API, si —
/// vérifié :
///
///     GIF-SUR-YVETT → Gif-sur-Yvette          insee 91272 · dep 91 · cp 91190
///     MONT SUR LOIR → Gif-sur-Yvette          (tirets ou espaces indifférents)
///     ISSY LES      → Issy-les-Moulineaux     insee 92040 · dep 92 · cp 92130
///     CORMEILLES EN → Cormeilles-en-Parisis   insee 95176 · dep 95
///     PERROGNEY LES → Perrogney-les-Fontaines insee 52384 · dep 52
///     ROSIERES PRES → Rosières-près-Troyes    insee 10325 · dep 10
///     FLANCHES      → []   ← oracle NÉGATIF, tout aussi utile
///
/// Elle désambiguïse aussi par population (`boost=population`) : « NIMES » existe en
/// Essonne et en Seine-Maritime, on veut la première.
///
/// Un échec de résolution n'est PAS un échec de la recherche : le fragment reste utilisé
/// comme texte de tri sur les adresses des candidats (`RankingContext.freeLocalityText`).
/// C'est ce qui rend le correctif SROM/FLANCHES indépendant de cet oracle.
actor GeoCommuneResolver: LocalityResolver {

    static let shared = GeoCommuneResolver()

    private let baseURL = URL(string: "https://geo.api.gouv.fr/communes")!

    /// `nil` en valeur = réponse négative mémorisée (« ce n'est pas une commune »).
    private var cache: [String: ResolvedLocality?] = [:]
    private var negativeTimestamps: [String: Date] = [:]

    /// Les réponses positives ne périment pas : les communes ne bougent quasiment jamais.
    /// Les négatives, si — une graphie tronquée peut devenir résoluble si l'API s'améliore.
    private static let negativeTTL: TimeInterval = 30 * 24 * 3600

    // MARK: - LocalityResolver

    func resolve(_ tokens: [LocalityToken], countryHint: String?) async -> ResolvedLocality? {
        // Hors de France, cet oracle n'a rien à dire.
        if let countryHint, countryHint != "FR" { return nil }

        // 1) Un code postal explicite suffit à contraindre la recherche, même sans commune.
        if let postal = tokens.first(where: { $0.kind == .postalCode })?.raw {
            if let hit = await lookupPostalCode(postal) { return hit }
            return ResolvedLocality(
                displayName: postal, inseeCode: nil, postalCodes: [postal],
                departmentCode: String(postal.prefix(2)), countryCode: "FR",
                latitude: nil, longitude: nil, population: nil, source: .postalCodeOnly
            )
        }

        // 2) Fragments de ville, par confiance décroissante (le créneau d'un gabarit
        //    bancaire vaut mieux qu'une devinette de fin de libellé).
        let cityTokens = tokens
            .filter { $0.kind == .cityName }
            .sorted { $0.confidence > $1.confidence }
        for token in cityTokens {
            if let hit = await lookupCommune(token.raw) { return hit }
        }
        return nil
    }

    func clearCache() {
        cache.removeAll()
        negativeTimestamps.removeAll()
    }

    // MARK: - Interne

    private func lookupCommune(_ raw: String) async -> ResolvedLocality? {
        let key = normalize(raw)
        guard !key.isEmpty, key.count >= 3 else { return nil }

        if let cached = cache[key] {
            if let hit = cached { return hit }
            // Négatif mémorisé : on ne réinterroge qu'après expiration.
            if let at = negativeTimestamps[key], Date().timeIntervalSince(at) < Self.negativeTTL {
                return nil
            }
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "nom", value: key),
            .init(name: "fields", value: "nom,code,codeDepartement,codesPostaux,population,centre"),
            .init(name: "limit", value: "3"),
            // Départage « Massy » (Essonne, 91 377 hab.) de « Massy » (Seine-Maritime).
            .init(name: "boost", value: "population")
        ]
        guard let url = components.url else { return nil }

        do {
            let data = try await ResilientHTTP.get(url, provider: .geoGouv, timeout: 8)
            let communes = try JSONDecoder().decode([GeoCommune].self, from: data)
            guard let best = communes.first else {
                cache[key] = ResolvedLocality?.none
                negativeTimestamps[key] = Date()
                return nil
            }
            let resolved = best.asResolvedLocality()
            cache[key] = resolved
            return resolved
        } catch {
            // Panne réseau : ne RIEN mémoriser. Cacher un négatif ici gèlerait une
            // commune parfaitement valide pendant 30 jours à cause d'un métro sans réseau.
            print("[GeoCommuneResolver] « \(key) » : \(error.localizedDescription)")
            return nil
        }
    }

    private func lookupPostalCode(_ postal: String) async -> ResolvedLocality? {
        let key = "cp:\(postal)"
        if let cached = cache[key] { return cached }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "codePostal", value: postal),
            .init(name: "fields", value: "nom,code,codeDepartement,codesPostaux,population,centre"),
            .init(name: "limit", value: "1"),
            .init(name: "boost", value: "population")
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await ResilientHTTP.get(url, provider: .geoGouv, timeout: 8)
            let communes = try JSONDecoder().decode([GeoCommune].self, from: data)
            guard let best = communes.first else { return nil }
            // On garde le code postal du libellé : c'est LUI qui filtrera, pas la liste
            // complète de la commune (Paris en a vingt).
            var resolved = best.asResolvedLocality()
            resolved = ResolvedLocality(
                displayName: resolved.displayName, inseeCode: resolved.inseeCode,
                postalCodes: [postal], departmentCode: resolved.departmentCode,
                countryCode: "FR", latitude: resolved.latitude, longitude: resolved.longitude,
                population: resolved.population, source: .geoAPI
            )
            cache[key] = resolved
            return resolved
        } catch {
            return nil
        }
    }

    /// Les fragments arrivent en minuscules sans diacritiques, séparateurs variables
    /// (« GIF-SUR-YVETT » ou « MONT SUR LOIR »). L'API accepte les deux : on normalise
    /// simplement les espaces.
    private func normalize(_ raw: String) -> String {
        raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "'" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Décodage

private struct GeoCommune: Decodable {
    let nom: String
    let code: String
    let codeDepartement: String?
    let codesPostaux: [String]?
    let population: Int?
    let centre: GeoPoint?

    struct GeoPoint: Decodable {
        let coordinates: [Double]?  // [longitude, latitude] — ordre GeoJSON
    }

    func asResolvedLocality() -> ResolvedLocality {
        // ⚠️ GeoJSON ordonne [longitude, latitude], pas l'inverse.
        let lon = centre?.coordinates?.first
        let lat = centre?.coordinates?.dropFirst().first
        return ResolvedLocality(
            displayName: nom,
            inseeCode: code,
            postalCodes: codesPostaux ?? [],
            departmentCode: codeDepartement,
            countryCode: "FR",
            latitude: lat,
            longitude: lon,
            population: population,
            source: .geoAPI
        )
    }
}
