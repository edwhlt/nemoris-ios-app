import Foundation

extension String {
    /// "carrefour market" → "Carrefour Market". A few known acronyms stay
    /// all uppercase (SNCF, RATP, BNP, AWS, KFC…).
    /// Used to normalize the engine's `canonicalName` before display.
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

/// Result of an enrichment (Sirene + Apple Foundation Models + MapKit).
///
/// A single `MerchantEnrichment` represents the merge (or the raw output of a single source)
/// of the signals collected for a given bank label or merchant_id.

enum MerchantEnrichmentSource: String, Codable, CaseIterable {
    case sirene
    case llm        // Apple Foundation Models
    case localLLM   // OpenAI-compatible HTTP server configured by the user (LM Studio, Ollama…)
    /// Cloud provider with the user's own API key (Claude, OpenAI).
    /// ⚠️ The ONLY case where the label left the device — hence a distinct
    /// case rather than sharing one with `.llm`: `enrichment_cache.source` must
    /// stay honest about the provenance, and the compiler forces every
    /// display site to be updated.
    case cloudLLM
    case mapkit
    case merged     // weighted vote among several sources
    case manual     // entered by the user
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
    /// 0..1. A mix of "match quality" × "source confidence". See EnrichmentOrchestrator.
    var confidence: Double
    var enrichedAt: Date
    /// Cleaned-up query the LLM proposes to re-run a Maps/Sirene search
    /// (e.g. "Hung Restaurant Ha Giang" extracted from "VNPAY HUNG RES PSC VN P HA GIANG").
    /// Nil for non-LLM sources.
    var searchHint: String? = nil

    // Additive fields. All `var x: T? = nil` → synthesized `decodeIfPresent`,
    // so cache files written by previous versions decode unchanged.
    // Never turn one of these into a non-optional without versioning the cache.

    /// The company's SIREN (9 digits). The `siret` identifies the establishment,
    /// the `siren` identifies the legal entity behind it — it's what lets us
    /// find the other establishments of the same chain.
    var siren: String? = nil
    /// The establishment's postal code, extracted separately from `address` to serve
    /// as a search filter (`code_postal`) and a ranking signal.
    var postalCode: String? = nil
    /// Category name proposed by a source that doesn't know Nemoris's ids
    /// (the LLM returns "Groceries", not `category_id = 7`). Resolved into `categoryId`
    /// by `EnrichmentOrchestrator.findCategoryId(byName:)`, which has access to the reference data.
    var categoryHint: String? = nil

    static let empty = MerchantEnrichment(source: .merged, confidence: 0, enrichedAt: Date())

    /// Checks that we have at least one usable signal.
    var hasContent: Bool {
        displayName != nil || domain != nil || siret != nil ||
        (latitude != nil && longitude != nil)
    }
}

/// Context passed to the orchestrator to enrich a transaction.
struct MerchantEnrichmentContext: Hashable {
    let rawLabel: String
    let canonicalName: String?
    let amount: Double?
    let city: String?
    let country: String?
    /// For cache purposes only: canonical merchant_id if already known (e.g. via the engine).
    let engineMerchantId: String?

    /// Stable cache key: engine_merchant_id if available, otherwise the lowercased canonical name + city.
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
