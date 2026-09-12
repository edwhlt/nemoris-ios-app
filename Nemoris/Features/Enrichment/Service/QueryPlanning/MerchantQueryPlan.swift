import Foundation

// Models for merchant query planning.
//
// ⚠️ PURE FILE: `import Foundation` ONLY.
// No NemorisEngine (it's a SwiftPM package, the swiftc harness would have to compile it
// in full), no MapKit, no FoundationModels, no CoreLocation, no SwiftUI.
// The safety net is `Tests/run_query_planner_tests.sh`: a forbidden import breaks it.
//
// Why all of this exists: the recherche-entreprises.api.gouv.fr API matches `q` against the
// company name AND trade names, NEVER against the address. Putting the city in `q`
// doesn't restrict the search, it makes it fail:
//
//     q=carrefour market flanches  →  0 results
//     q=carrefour market           →  1907 results
//
// The locality must therefore become a FILTER (`code_commune` / `code_postal` / `departement`)
// or a SORT SIGNAL, never a word in the query. That's the whole point of this module.

// MARK: - Locality

/// Nature of a geographic fragment spotted in a label.
enum LocalityKind: String, Codable, Sendable, Hashable {
    /// Commune name, possibly TRUNCATED by the bank ("GIF-SUR-YVETT", "ISSY LES").
    case cityName
    /// French 5-digit postal code.
    case postalCode
    /// 2-digit department code, like the "78" prefix in "35 RENNES".
    case departmentCode
    /// Code pays ISO 3166-1 alpha-2.
    case countryCode
}

/// A geographic fragment extracted from the label, before any resolution.
struct LocalityToken: Hashable, Sendable, Codable {
    /// Normalized value (lowercase, no diacritics), as it will be sent
    /// to the commune oracle. May be truncated — that's exactly what the oracle
    /// can resolve, "issy les" → Issy-les-Moulineaux.
    let raw: String
    let kind: LocalityKind
    /// How much we believe it really is one.
    /// 1.0 = a recognized bank template's slot, or confirmed by the engine.
    /// 0.6 = a guessed trailing n-gram, unconfirmed.
    let confidence: Double

    init(raw: String, kind: LocalityKind, confidence: Double) {
        self.raw = raw
        self.kind = kind
        self.confidence = min(1, max(0, confidence))
    }
}

/// A locality after resolution by a `LocalityResolver`.
struct ResolvedLocality: Hashable, Sendable, Codable {
    let displayName: String        // "Gif-sur-Yvette"
    let inseeCode: String?         // "91272"
    let postalCodes: [String]      // ["91190"]
    let departmentCode: String?    // "91"
    let countryCode: String        // "FR"
    let latitude: Double?
    let longitude: Double?
    let population: Int?
    let source: Source

    enum Source: String, Codable, Sendable {
        case geoAPI          // geo.api.gouv.fr
        case seedTable       // embedded communes_seed.json
        case postalCodeOnly  // we only have the postal code, not the commune
        case userProvided    // entered in the form
        case foreignTable    // ForeignLocalityTable (hors France)
    }

    /// The single postal code, if there's only one. A commune with several postal
    /// codes (Lyon: 69001…69009) can't be filtered by `code_postal` without an
    /// arbitrary choice — we use `code_commune` in that case.
    var unambiguousPostalCode: String? {
        postalCodes.count == 1 ? postalCodes[0] : nil
    }
}

// MARK: - Extraction

/// Why a token was removed from the name. Feeds the UI's "Removed from name"
/// chips, which let the user re-inject a misclassified token.
enum DropReason: String, Codable, Sendable, Hashable {
    case processorPrefix    // PAIEMENT, CB, PSC, VIR, PRLV, SUMUP, VNPAY…
    case cardMarker         // CARTE 1042, PAYWEB1042
    case transactionId      // GIR012607803713662, CG3W26063M200769
    case date               // 1803 (DDMM), 19/05
    case currency           // EUR, VND
    case postalCode         // 75011
    case locality           // MONT SUR LOIR
    case departmentCode     // 78
    case paymentReference   // PAYLI2469, PSC
    case countryCode        // VN, FR
    case noise              // tokens too short / purely numeric

    /// FR wording shown in the chip.
    var displayLabel: String {
        switch self {
        case .processorPrefix:  return "préfixe"
        case .cardMarker:       return "carte"
        case .transactionId:    return "référence"
        case .date:             return "date"
        case .currency:         return "devise"
        case .postalCode:       return "code postal"
        case .locality:         return "lieu"
        case .departmentCode:   return "département"
        case .paymentReference: return "référence"
        case .countryCode:      return "pays"
        case .noise:            return "bruit"
        }
    }
}

struct DroppedToken: Hashable, Sendable, Codable {
    let value: String
    let reason: DropReason
}

/// Result of parsing a raw label, before resolving the locality.
struct MerchantLabelExtraction: Hashable, Sendable, Codable {
    let rawLabel: String
    /// Id of the recognized bank template, nil on a heuristic fallback.
    let templateId: String?
    /// Detected payment processor (sumup, vnpay, paypal…).
    let processorId: String?
    /// **The only thing allowed to go into `q=`.**
    let nameTokens: [String]
    let localityTokens: [LocalityToken]
    /// Code pays ISO-2 en MAJUSCULES.
    let countryHint: String?
    /// Department code inferred unambiguously (the "35 RENNES" prefix).
    let departmentHint: String?
    let droppedTokens: [DroppedToken]
    /// A named transfer: we NEVER query a company registry for a
    /// private individual — privacy, and it wouldn't return anything anyway.
    let isPersonNotBusiness: Bool
    /// A web payment (PAYWEB / PAYLI): no physical locality, so no geo filter
    /// and no proximity search.
    let isOnlinePayment: Bool

    var nameQuery: String { nameTokens.joined(separator: " ") }

    /// Nothing usable: an empty `q`, only digits, or a single token too short
    /// to discriminate. A degenerate plan produces NO attempt at all — we don't
    /// fire a network request for "***", "A" or "0000000".
    var degenerate: Bool {
        let joined = nameQuery.trimmingCharacters(in: .whitespaces)
        if joined.isEmpty { return true }
        // A name with not a single letter identifies nothing: `q=0000000` queries
        // the registry for nothing. Residual identifiers all fall into this case.
        if !joined.contains(where: \.isLetter) { return true }
        if nameTokens.count == 1 && joined.count < 3 { return true }
        return false
    }

    /// The first locality fragment usable as text (for resolution
    /// and, failing that, for sorting on addresses).
    var primaryLocalityText: String? {
        localityTokens.first(where: { $0.kind == .cityName })?.raw
    }

    var postalCodeToken: String? {
        localityTokens.first(where: { $0.kind == .postalCode })?.raw
    }
}

// MARK: - Requests

/// A request to a company registry (Sirene and the like).
///
/// `minimal=true` and `include=siege,matching_etablissements` are NOT options:
/// they are invariants of every call, set by the client. Verified against the API:
/// `include` without `minimal=true` returns an error.
struct CompanyRegistryQuery: Hashable, Sendable, Codable {
    /// Merchant name ONLY. Never a city, never a postal code, never a reference.
    let q: String
    let codeCommune: String?
    let codePostal: String?
    let departement: String?
    let perPage: Int
    /// "A" = active establishments only. nil = include closed ones (last resort).
    let etatAdministratif: String?
    let limiteMatchingEtablissements: Int

    init(q: String,
         codeCommune: String? = nil,
         codePostal: String? = nil,
         departement: String? = nil,
         perPage: Int = 10,
         etatAdministratif: String? = "A",
         limiteMatchingEtablissements: Int = 20) {
        self.q = q
        self.codeCommune = codeCommune
        self.codePostal = codePostal
        self.departement = departement
        self.perPage = perPage
        self.etatAdministratif = etatAdministratif
        self.limiteMatchingEtablissements = limiteMatchingEtablissements
    }

    /// Canonical serialization (sorted parameters) — a stable cache key.
    /// Deliberately NOT free text: two identical requests that only differ
    /// in parameter order must share their cache entry.
    var canonicalKey: String {
        var parts = ["q=\(q)", "per_page=\(perPage)", "lme=\(limiteMatchingEtablissements)"]
        if let c = codeCommune { parts.append("code_commune=\(c)") }
        if let c = codePostal { parts.append("code_postal=\(c)") }
        if let d = departement { parts.append("departement=\(d)") }
        if let e = etatAdministratif { parts.append("etat=\(e)") }
        return parts.sorted().joined(separator: "&")
    }

    /// Does it have at least one geographic constraint?
    var hasGeoFilter: Bool {
        codeCommune != nil || codePostal != nil || departement != nil
    }
}

/// A map search (MapKit today, possibly others tomorrow).
///
/// ⚠️ `text` is built from `MerchantLabelExtraction.nameQuery` + the locality
/// text, NEVER from the raw bank label: the latter carries transaction
/// references and card numbers that have no business reaching a third party.
struct PlaceTextQuery: Hashable, Sendable, Codable {
    let text: String
    let localityLabel: String?
    let countryCode: String?
    let latitude: Double?
    let longitude: Double?
    let limit: Int

    var canonicalKey: String {
        "\(text)|\(localityLabel ?? "")|\(countryCode ?? "")|\(limit)"
    }
}

// MARK: - Tentatives

enum SearchAttemptKind: Hashable, Sendable, Codable {
    case companyRegistry(CompanyRegistryQuery)
    case companyRegistryNearPoint(latitude: Double, longitude: Double, radiusKm: Double, perPage: Int)
    case placeText(PlaceTextQuery)

    /// Short, stable identifier, used by the corpus assertions.
    var shortName: String {
        switch self {
        case .companyRegistry(let q):
            if q.codeCommune != nil { return "registry_commune" }
            if q.codePostal != nil { return "registry_postal" }
            if q.departement != nil { return "registry_departement" }
            return "registry_bare_q"
        case .companyRegistryNearPoint:
            return "registry_near_point"
        case .placeText:
            return "place_text"
        }
    }
}

struct SearchAttempt: Hashable, Sendable, Codable, Identifiable {
    /// 1-based ordinal, stable → tests assert by index.
    let id: Int
    let kind: SearchAttemptKind
    /// FR justification, shown in "Search details".
    let rationale: String
    /// A priori expected precision (used for ordering, not filtering).
    let expectedPrecision: Double
}

// MARK: - Ranking context

/// Everything `CandidateRanker` needs, with no network or database dependency at all.
struct RankingContext: Hashable, Sendable, Codable {
    let nameTokens: [String]
    /// UNRESOLVED locality text (the oracle didn't recognize a commune).
    /// We then look for it directly in candidates' addresses: a place name or
    /// hamlet unknown to geo.api.gouv.fr very often shows up as-is in the
    /// right establishment's `adresse`. That's what keeps the SROM/FLANCHES
    /// fix from depending on the oracle succeeding.
    let freeLocalityText: String?
    let inseeCode: String?
    let postalCodes: [String]
    let departmentCode: String?
    let cityLabel: String?
    /// NAF prefixes known to the reference data, passed in as plain data so the
    /// ranker stays pure (no access to NAFCategoryMapper, which reads the bundle).
    let knownNafPrefixes: Set<String>

    init(nameTokens: [String],
         freeLocalityText: String? = nil,
         inseeCode: String? = nil,
         postalCodes: [String] = [],
         departmentCode: String? = nil,
         cityLabel: String? = nil,
         knownNafPrefixes: Set<String> = []) {
        self.nameTokens = nameTokens
        self.freeLocalityText = freeLocalityText
        self.inseeCode = inseeCode
        self.postalCodes = postalCodes
        self.departmentCode = departmentCode
        self.cityLabel = cityLabel
        self.knownNafPrefixes = knownNafPrefixes
    }

    /// No location information at all: the locality score must be NEUTRAL (0.5),
    /// neither a reward nor a penalty. Without this, every candidate would be
    /// punished for information the label never carried.
    var hasNoLocalityInfo: Bool {
        freeLocalityText == nil && inseeCode == nil && postalCodes.isEmpty
            && departmentCode == nil && cityLabel == nil
    }
}

// MARK: - Plan

struct MerchantQueryPlan: Hashable, Sendable, Codable {
    let extraction: MerchantLabelExtraction
    let locality: ResolvedLocality?
    let attempts: [SearchAttempt]
    let ranking: RankingContext

    /// Deduplication key for batch import. Two labels that only differ by their
    /// transaction identifier produce the SAME plan, so a single request.
    var cacheKey: String {
        let name = extraction.nameQuery
        let loc = locality?.inseeCode
            ?? locality?.displayName
            ?? extraction.primaryLocalityText
            ?? ""
        return "\(name)|\(loc)|\(extraction.countryHint ?? "")"
    }
}
