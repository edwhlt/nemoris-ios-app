import Foundation

// AXE S — Modèles de la planification de requêtes marchand.
//
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
// Pas de NemorisEngine (c'est un package SwiftPM, le harness swiftc devrait le compiler
// en entier), pas de MapKit, pas de FoundationModels, pas de CoreLocation, pas de SwiftUI.
// Le garde-fou est `Tests/run_query_planner_tests.sh` : un import interdit le casse.
//
// Pourquoi tout ça existe : l'API recherche-entreprises.api.gouv.fr matche `q` contre la
// raison sociale ET les enseignes, JAMAIS contre l'adresse. Mettre la ville dans `q` ne
// restreint pas la recherche, il la fait échouer :
//
//     q=carrefour market flanches  →  0 résultat
//     q=carrefour market           →  1907 résultats
//
// La localité doit donc devenir un FILTRE (`code_commune` / `code_postal` / `departement`)
// ou un SIGNAL DE TRI, jamais un mot de la requête. C'est tout l'objet de ce module.

// MARK: - Localité

/// Nature d'un fragment géographique repéré dans un libellé.
enum LocalityKind: String, Codable, Sendable, Hashable {
    /// Nom de commune, éventuellement TRONQUÉ par la banque ("GIF-SUR-YVETT", "ISSY LES").
    case cityName
    /// Code postal français à 5 chiffres.
    case postalCode
    /// Code département à 2 chiffres, tel que le préfixe "78" dans « 78 VERSAILLES ».
    case departmentCode
    /// Code pays ISO 3166-1 alpha-2.
    case countryCode
}

/// Un fragment géographique extrait du libellé, avant toute résolution.
struct LocalityToken: Hashable, Sendable, Codable {
    /// Valeur normalisée (minuscules, sans diacritiques), telle qu'elle sera envoyée
    /// à l'oracle de communes. Peut être tronquée — c'est justement l'oracle qui sait
    /// résoudre "issy les" → Issy-les-Moulineaux.
    let raw: String
    let kind: LocalityKind
    /// À quel point on croit que c'en est vraiment une.
    /// 1.0 = créneau d'un gabarit bancaire reconnu, ou confirmée par le moteur.
    /// 0.6 = n-gram deviné en fin de libellé, non confirmé.
    let confidence: Double

    init(raw: String, kind: LocalityKind, confidence: Double) {
        self.raw = raw
        self.kind = kind
        self.confidence = min(1, max(0, confidence))
    }
}

/// Localité après résolution par un `LocalityResolver`.
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
        case seedTable       // communes_seed.json embarqué
        case postalCodeOnly  // on n'a que le code postal, pas la commune
        case userProvided    // saisi dans le formulaire
        case foreignTable    // ForeignLocalityTable (hors France)
    }

    /// Le seul code postal, s'il n'y en a qu'un. Une commune à plusieurs codes postaux
    /// (Lyon : 69001…69009) ne peut pas être filtrée par `code_postal` sans arbitraire —
    /// on utilise `code_commune` dans ce cas.
    var unambiguousPostalCode: String? {
        postalCodes.count == 1 ? postalCodes[0] : nil
    }
}

// MARK: - Extraction

/// Pourquoi un token a été retiré du nom. Alimente les puces « Retiré du nom » de l'UI,
/// qui permettent à l'utilisateur de réinjecter un token mal classé.
enum DropReason: String, Codable, Sendable, Hashable {
    case processorPrefix    // PAIEMENT, CB, PSC, VIR, PRLV, SUMUP, VNPAY…
    case cardMarker         // CARTE 5974, PAYWEB5974
    case transactionId      // GIR012607803713662, CG3W26063M200769
    case date               // 1803 (DDMM), 19/05
    case currency           // EUR, VND
    case postalCode         // 75011
    case locality           // GIF SUR YVETT
    case departmentCode     // 78
    case paymentReference   // PAYLI2469, PSC
    case countryCode        // VN, FR
    case noise              // tokens trop courts / purement numériques

    /// Libellé FR affiché dans la puce.
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

/// Résultat de l'analyse d'un libellé brut, avant résolution de la localité.
struct MerchantLabelExtraction: Hashable, Sendable, Codable {
    let rawLabel: String
    /// Identifiant du gabarit bancaire reconnu, nil si repli heuristique.
    let templateId: String?
    /// Processeur de paiement détecté (sumup, vnpay, paypal…).
    let processorId: String?
    /// **La seule chose qui a le droit d'aller dans `q=`.**
    let nameTokens: [String]
    let localityTokens: [LocalityToken]
    /// Code pays ISO-2 en MAJUSCULES.
    let countryHint: String?
    /// Code département déduit sans ambiguïté (préfixe « 78 VERSAILLES »).
    let departmentHint: String?
    let droppedTokens: [DroppedToken]
    /// Virement nominatif : on n'interroge JAMAIS un registre d'entreprises pour un
    /// particulier — vie privée, et ça ne donne rien de toute façon.
    let isPersonNotBusiness: Bool
    /// Paiement web (PAYWEB / PAYLI) : pas de localité physique, donc pas de filtre géo
    /// et pas de recherche par proximité.
    let isOnlinePayment: Bool

    var nameQuery: String { nameTokens.joined(separator: " ") }

    /// Rien d'exploitable : `q` vide, uniquement des chiffres, ou un seul token trop court
    /// pour discriminer. Un plan dégénéré ne produit AUCUNE tentative — on ne lance pas de
    /// requête réseau pour « *** », « A » ou « 0000000 ».
    var degenerate: Bool {
        let joined = nameQuery.trimmingCharacters(in: .whitespaces)
        if joined.isEmpty { return true }
        // Un nom sans la moindre lettre n'identifie rien : `q=0000000` interroge le
        // registre pour rien. Les identifiants résiduels tombent tous dans ce cas.
        if !joined.contains(where: \.isLetter) { return true }
        if nameTokens.count == 1 && joined.count < 3 { return true }
        return false
    }

    /// Le premier fragment de localité exploitable comme texte (pour la résolution
    /// et, à défaut, pour le tri sur les adresses).
    var primaryLocalityText: String? {
        localityTokens.first(where: { $0.kind == .cityName })?.raw
    }

    var postalCodeToken: String? {
        localityTokens.first(where: { $0.kind == .postalCode })?.raw
    }
}

// MARK: - Requêtes

/// Une requête vers un registre d'entreprises (Sirene et assimilés).
///
/// `minimal=true` et `include=siege,matching_etablissements` ne sont PAS des options :
/// ce sont des invariants de tout appel, posés par le client. Vérifié à l'API :
/// `include` sans `minimal=true` renvoie une erreur.
struct CompanyRegistryQuery: Hashable, Sendable, Codable {
    /// Nom du marchand SEUL. Jamais de ville, jamais de code postal, jamais de référence.
    let q: String
    let codeCommune: String?
    let codePostal: String?
    let departement: String?
    let perPage: Int
    /// "A" = établissements actifs seulement. nil = inclure les fermés (dernier recours).
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

    /// Sérialisation canonique (paramètres triés) — clé de cache stable.
    /// Volontairement PAS du texte libre : deux requêtes identiques à l'ordre des
    /// paramètres près doivent partager leur entrée de cache.
    var canonicalKey: String {
        var parts = ["q=\(q)", "per_page=\(perPage)", "lme=\(limiteMatchingEtablissements)"]
        if let c = codeCommune { parts.append("code_commune=\(c)") }
        if let c = codePostal { parts.append("code_postal=\(c)") }
        if let d = departement { parts.append("departement=\(d)") }
        if let e = etatAdministratif { parts.append("etat=\(e)") }
        return parts.sorted().joined(separator: "&")
    }

    /// A-t-elle au moins une contrainte géographique ?
    var hasGeoFilter: Bool {
        codeCommune != nil || codePostal != nil || departement != nil
    }
}

/// Requête cartographique (MapKit aujourd'hui, éventuellement d'autres demain).
///
/// ⚠️ `text` est construit depuis `MerchantLabelExtraction.nameQuery` + le libellé de
/// localité, JAMAIS depuis le libellé bancaire brut : celui-ci contient des références
/// de transaction et des numéros de carte qui n'ont rien à faire chez un tiers.
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

    /// Identifiant court et stable, utilisé par les assertions du corpus.
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
    /// Ordinal 1-based, stable → les tests assertent par index.
    let id: Int
    let kind: SearchAttemptKind
    /// Justification en français, affichée dans « Détails de la recherche ».
    let rationale: String
    /// Précision attendue a priori (sert à ordonner, pas à filtrer).
    let expectedPrecision: Double
}

// MARK: - Contexte de classement

/// Tout ce dont `CandidateRanker` a besoin, sans aucune dépendance réseau ni base.
struct RankingContext: Hashable, Sendable, Codable {
    let nameTokens: [String]
    /// Texte de localité NON résolu (l'oracle n'a pas reconnu de commune).
    /// On le cherche alors directement dans l'adresse des candidats : un lieu-dit ou
    /// un hameau inconnu de geo.api.gouv.fr apparaît très souvent tel quel dans
    /// l'`adresse` du bon établissement. C'est ce qui fait que le correctif
    /// SROM/FLANCHES ne dépend PAS de la réussite de l'oracle.
    let freeLocalityText: String?
    let inseeCode: String?
    let postalCodes: [String]
    let departmentCode: String?
    let cityLabel: String?
    /// Préfixes NAF connus du référentiel, passés en donnée pour que le ranker
    /// reste pur (pas d'accès à NAFCategoryMapper, qui lit le bundle).
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

    /// Aucune information de lieu : le score de localité doit être NEUTRE (0.5),
    /// ni récompense ni pénalité. Sans ça, tout candidat serait puni pour une
    /// information que le libellé ne contenait pas.
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

    /// Clé de déduplication pour l'import batch. Deux libellés qui ne diffèrent que par
    /// leur identifiant de transaction produisent le MÊME plan, donc une seule requête.
    var cacheKey: String {
        let name = extraction.nameQuery
        let loc = locality?.inseeCode
            ?? locality?.displayName
            ?? extraction.primaryLocalityText
            ?? ""
        return "\(name)|\(loc)|\(extraction.countryHint ?? "")"
    }
}
