import Foundation

extension String {
    /// "carrefour market" → "Carrefour Market". Quelques acronymes connus restent
    /// tout en majuscules (SNCF, RATP, BNP, AWS, KFC…).
    /// Utilisé pour normaliser les `canonicalName` du moteur avant affichage.
    var titleCased: String {
        let known: Set<String> = [
            "sncf", "ratp", "ratpc", "ratpd", "bnp", "lcl", "cic",
            "fnac", "aws", "kfc", "edf", "gdf", "rte", "ovh", "sfr",
            "rmc", "tf1", "m6", "bfm", "rer", "tgv", "ter", "tcl",
            "vtc", "btp", "ag2r", "macif", "maif", "mma", "axa",
            "ups", "fedex", "dhl", "chu", "ehpad"
        ]
        return self
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "'" })
            .map { word -> String in
                let s = String(word)
                if known.contains(s) { return s.uppercased() }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }
}

/// AXE B — Résultat d'un enrichissement (Sirene + Apple Foundation Models + MapKit).
///
/// Un seul `MerchantEnrichment` représente la fusion (ou la sortie d'une source unique)
/// des signaux collectés pour un libellé bancaire ou un merchant_id donné.

enum MerchantEnrichmentSource: String, Codable, CaseIterable {
    case sirene
    case llm        // Apple Foundation Models
    case mapkit
    case merged     // vote pondéré entre plusieurs sources
    case manual     // saisi par l'utilisateur
}

struct MerchantEnrichment: Codable, Hashable {
    var displayName: String?
    var domain: String?
    var categoryId: Int?
    var address: String?
    var city: String?
    var country: String?       // ISO 3166-1 alpha-2
    var latitude: Double?
    var longitude: Double?
    var phone: String?
    var siret: String?
    var nafCode: String?
    var source: MerchantEnrichmentSource
    /// 0..1. Mélange "qualité de match" × "confiance source". Voir EnrichmentOrchestrator.
    var confidence: Double
    var enrichedAt: Date
    /// Requête nettoyée que le LLM propose pour relancer une recherche Maps/Sirene
    /// (ex. "Hung Restaurant Ha Giang" extrait depuis "VNPAY HUNG RES PSC VN P HA GIANG").
    /// Nil pour les sources non-LLM.
    var searchHint: String? = nil

    static let empty = MerchantEnrichment(source: .merged, confidence: 0, enrichedAt: Date())

    /// Vérifie qu'on a au moins un signal exploitable.
    var hasContent: Bool {
        displayName != nil || domain != nil || siret != nil ||
        (latitude != nil && longitude != nil)
    }
}

/// Contexte passé à l'orchestrateur pour enrichir une transaction.
struct MerchantEnrichmentContext: Hashable {
    let rawLabel: String
    let canonicalName: String?
    let amount: Double?
    let city: String?
    let country: String?
    /// Pour cache uniquement : merchant_id canonique si déjà connu (ex via engine).
    let engineMerchantId: String?

    /// Clé de cache stable : engine_merchant_id si dispo, sinon canonical name lowercased + city.
    var cacheKey: String {
        if let id = engineMerchantId, !id.isEmpty { return id }
        let name = (canonicalName ?? rawLabel)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        if let city, !city.isEmpty {
            let c = city.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            return "\(name)|\(c)"
        }
        return name
    }
}
