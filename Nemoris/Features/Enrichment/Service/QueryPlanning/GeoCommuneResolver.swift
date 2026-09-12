import Foundation

/// Resolves a label fragment into a French commune via `geo.api.gouv.fr`.
/// No key, no account needed.
///
/// WHY AN API RATHER THAN A HARDCODED LIST
///
/// The locality field of bank statements is TRUNCATED at a fixed width (~13 characters).
/// No exact-match dictionary can recognize it. The API can — verified:
///
///     GIF-SUR-YVETT → Gif-sur-Yvette          insee 91272 · dep 91 · cp 91190
///     MONT SUR LOIR → Gif-sur-Yvette          (dashes or spaces, either works)
///     ISSY LES      → Issy-les-Moulineaux     insee 92040 · dep 92 · cp 92130
///     CORMEILLES EN → Cormeilles-en-Parisis   insee 95176 · dep 95
///     PERROGNEY LES → Perrogney-les-Fontaines insee 52384 · dep 52
///     ROSIERES PRES → Rosières-près-Troyes    insee 10325 · dep 10
///     FLANCHES      → []   ← a NEGATIVE oracle answer, just as useful
///
/// It also disambiguates by population (`boost=population`): "NIMES" exists in
/// Essonne and in Seine-Maritime, we want the first one.
///
/// A resolution failure is NOT a search failure: the fragment is still used
/// as sort text against candidates' addresses (`RankingContext.freeLocalityText`).
/// That's what keeps the SROM/FLANCHES fix independent of this oracle.
actor GeoCommuneResolver: LocalityResolver {

    static let shared = GeoCommuneResolver()

    private let baseURL = URL(string: "https://geo.api.gouv.fr/communes")!

    /// `nil` value = a memoized negative answer ("this isn't a commune").
    private var cache: [String: ResolvedLocality?] = [:]
    private var negativeTimestamps: [String: Date] = [:]

    /// Positive answers never expire: communes almost never change.
    /// Negative ones do — a truncated spelling may become resolvable if the API improves.
    private static let negativeTTL: TimeInterval = 30 * 24 * 3600

    // MARK: - LocalityResolver

    func resolve(_ tokens: [LocalityToken], countryHint: String?) async -> ResolvedLocality? {
        // Outside France, this oracle has nothing to say.
        if let countryHint, countryHint != "FR" { return nil }

        // 1) An explicit postal code alone is enough to constrain the search, even with no commune.
        if let postal = tokens.first(where: { $0.kind == .postalCode })?.raw {
            if let hit = await lookupPostalCode(postal) { return hit }
            return ResolvedLocality(
                displayName: postal, inseeCode: nil, postalCodes: [postal],
                departmentCode: String(postal.prefix(2)), countryCode: "FR",
                latitude: nil, longitude: nil, population: nil, source: .postalCodeOnly
            )
        }

        // 2) City fragments, in decreasing confidence order (a bank template's
        //    slot is worth more than a trailing-label guess).
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
            // A memoized negative: only re-query once it has expired.
            if let at = negativeTimestamps[key], Date().timeIntervalSince(at) < Self.negativeTTL {
                return nil
            }
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "nom", value: key),
            .init(name: "fields", value: "nom,code,codeDepartement,codesPostaux,population,centre"),
            .init(name: "limit", value: "3"),
            // Disambiguates "Massy" (Essonne, 91,377 inhabitants) from "Massy" (Seine-Maritime).
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
            // Network failure: memoize NOTHING. Caching a negative here would freeze a
            // perfectly valid commune for 30 days because of a subway with no network.
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
            // We keep the label's postal code: it's what will filter, not the
            // full list of the commune's codes (Paris has twenty of them).
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

    /// Fragments arrive lowercase with no diacritics, with varying separators
    /// ("GIF-SUR-YVETT" or "MONT SUR LOIR"). The API accepts both: we simply
    /// normalize the spaces.
    private func normalize(_ raw: String) -> String {
        raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "'" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Decoding

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
