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
    case localLLM   // serveur HTTP compatible OpenAI configuré par l'utilisateur (LM Studio, Ollama…)
    /// Fournisseur cloud avec la clé API de l'utilisateur (Claude, OpenAI).
    /// ⚠️ Le SEUL cas où le libellé a quitté l'appareil — d'où un cas distinct
    /// plutôt qu'un partage avec `.llm` : `enrichment_cache.source` doit rester
    /// honnête sur la provenance, et le compilateur force la mise à jour de
    /// tous les affichages.
    case cloudLLM
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

    // Champs additifs (AXE S). Tous `var x: T? = nil` → `decodeIfPresent` synthétisé,
    // donc les fichiers de cache écrits par les versions précédentes se décodent inchangés.
    // Ne jamais transformer l'un d'eux en non-optionnel sans versionner le cache.

    /// SIREN de l'entreprise (9 chiffres). Le `siret` identifie l'établissement,
    /// le `siren` identifie la personne morale qui le porte — c'est lui qui permet
    /// de retrouver les autres établissements de la même enseigne.
    var siren: String? = nil
    /// Code postal de l'établissement, extrait séparément de `address` pour servir
    /// de filtre de recherche (`code_postal`) et de signal de tri.
    var postalCode: String? = nil
    /// Nom de catégorie proposé par une source qui ne connaît pas les ids Nemoris
    /// (le LLM renvoie "Alimentation", pas `category_id = 7`). Résolu en `categoryId`
    /// par `EnrichmentOrchestrator.findCategoryId(byName:)`, qui a accès au référentiel.
    var categoryHint: String? = nil

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
