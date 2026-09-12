import Foundation

// A company and its establishments, independent of the registry that provided them.
//
// WHY THESE TYPES AREN'T PART OF `MerchantEnrichment`
//
// `MerchantEnrichment` is a FLAT projection, a single address, mergeable field by
// field. That's the whole semantics of `EnrichmentOrchestrator.merge()` (argmax of
// `confidence × weight` for EACH field) — an argmax over an array of establishments
// means nothing. It's also the `enrichment_cache.json` payload, one entry per
// label: nesting 20 branches in there would bloat a cache that has neither a TTL nor eviction.
//
// The list of establishments only matters during the interactive session, while
// the user picks the right storefront. It therefore lives in `MerchantSearchResult`,
// never in the long-term cache.

/// An establishment: a physical address tied to a legal entity.
struct Establishment: Hashable, Sendable, Identifiable {
    /// SIRET in France, the provider's local identifier elsewhere.
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

    /// Most telling name: the trade name takes priority over everything.
    var displayName: String? {
        enseignes.first(where: { !$0.isEmpty }) ?? nomCommercial
    }

    /// Every name this establishment can match under.
    var searchableNames: [String] {
        var names = enseignes.filter { !$0.isEmpty }
        if let nc = nomCommercial, !nc.isEmpty { names.append(nc) }
        return names
    }

    /// Compact address line for the UI.
    var addressLine: String? {
        let parts = [address, [postalCode, city].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A legal entity and the establishments that match the search.
struct CompanyMatch: Hashable, Sendable, Identifiable {
    let providerId: String        // "sirene_fr"
    let siren: String
    let legalName: String
    let nomComplet: String?
    let nafCode: String?
    let isActive: Bool
    let creationDate: Date?
    /// TOTAL number of the company's establishments, all not returned.
    let establishmentCount: Int?
    let openEstablishmentCount: Int?
    let headquarters: Establishment?
    /// ⚠️ Only the establishments that MATCH the query, not all of the
    /// company's. The UI must phrase it that way ("establishments matching the
    /// searched name"): implying an exhaustive list would be misleading.
    let establishments: [Establishment]

    var id: String { siren }

    var searchableNames: [String] {
        var names = [legalName]
        if let n = nomComplet, !n.isEmpty, n != legalName { names.append(n) }
        names.append(contentsOf: establishments.flatMap(\.searchableNames))
        if let hq = headquarters { names.append(contentsOf: hq.searchableNames) }
        return names.filter { !$0.isEmpty }
    }

    /// True if the query matched a TRADE NAME rather than the company name. This is the
    /// common case with franchises: "CARREFOUR MARKET" is the trade name, the legal
    /// entity is called "CSF" or "OULLIDIS". Verified against the API: `q=carrefour market`
    /// surfaces the LIDL legal entity because one of its establishments carries that trade name.
    func matchedViaEnseigne(query: [String]) -> Bool {
        let legalScore = MerchantTokenSimilarity.bestScore(
            query: query, against: [legalName, nomComplet].compactMap { $0 }
        )
        let enseigneNames = establishments.flatMap(\.searchableNames)
            + (headquarters?.searchableNames ?? [])
        guard !enseigneNames.isEmpty else { return false }
        let enseigneScore = MerchantTokenSimilarity.bestScore(query: query, against: enseigneNames)
        return enseigneScore > legalScore
    }

    /// Every establishment worth showing: those that match, plus the headquarters
    /// if it isn't already among them (it often carries the only known address).
    var allEstablishments: [Establishment] {
        var out = establishments
        if let hq = headquarters, !out.contains(where: { $0.id == hq.id }) {
            out.append(hq)
        }
        return out
    }
}

// MARK: - Projection to the flat enrichment model

extension CompanyMatch {

    /// Projects this company and the chosen establishment into `MerchantEnrichment`.
    ///
    /// ⚠️ SINGLE conversion path, shared by the orchestrator (batch import) and by
    /// the UI (manual choice in the list). Duplicating them would make them diverge: it's
    /// exactly the bug class `EnvelopeSpendingCalculator` was built to eliminate
    /// elsewhere in the project.
    ///
    /// `establishment` is the key to the drill-down: a chain's headquarters is often
    /// on the other side of the country while the billed storefront is a branch. So we
    /// take the chosen establishment's address, never the headquarters' default one.
    func enrichment(for establishment: Establishment?,
                    confidence: Double,
                    fallbackCity: String? = nil,
                    resolveCategory: (String) -> Int? = { _ in nil }) -> MerchantEnrichment {
        let name = establishment?.displayName ?? legalName
        let naf = establishment?.nafCode ?? nafCode

        var result = MerchantEnrichment(
            displayName: name.titleCased,
            domain: nil,
            categoryId: naf.flatMap(resolveCategory),
            address: establishment?.address,
            city: establishment?.city ?? fallbackCity,
            country: "FR",
            latitude: establishment?.latitude,
            longitude: establishment?.longitude,
            phone: nil,
            siret: establishment?.id,
            nafCode: naf,
            source: .sirene,
            confidence: min(1, max(0, confidence)),
            enrichedAt: Date()
        )
        result.siren = siren
        result.postalCode = establishment?.postalCode
        return result
    }
}

extension RankedCompany {
    /// Variant for the best establishment — the ranking score IS the confidence,
    /// since it already aggregates name similarity, geographic match, business activity, and
    /// headquarters status.
    func enrichment(fallbackCity: String? = nil,
                    resolveCategory: (String) -> Int? = { _ in nil }) -> MerchantEnrichment {
        match.enrichment(for: bestEstablishment, confidence: score,
                         fallbackCity: fallbackCity, resolveCategory: resolveCategory)
    }
}

// MARK: - Adapting to the ranker's pure types

extension Establishment {
    /// Projects to the provider-agnostic candidate `CandidateRanker` expects.
    ///
    /// ⚠️ `companyNames` isn't optional in practice: most small
    /// companies have no declared trade name at all (`liste_enseignes` empty), so
    /// `searchableNames` is empty and the establishment would have NO name to compare against —
    /// a similarity score of 0, whatever the label. Bug observed in
    /// real conditions: "CB SROM FLANCHES" ranked "COMMUNE DE POMMEVIC" ahead of "SROM",
    /// both scoring 0 on the name and tied by their id alone.
    /// The company's own name is therefore always joined in.
    func rankable(providerWeight: Double,
                  matchedViaEnseigne: Bool,
                  companyNames: [String] = []) -> RankableCandidate {
        RankableCandidate(
            id: id,
            names: searchableNames + companyNames,
            addressLine: address,
            postalCode: postalCode,
            cityLabel: city,
            inseeCode: nil,   // the API returns the INSEE commune code in `commune`
            isHeadquarters: isHeadquarters,
            isActive: isActive,
            nafCode: nafCode,
            hasCoordinates: latitude != nil && longitude != nil,
            providerWeight: providerWeight,
            matchedViaEnseigne: matchedViaEnseigne
        )
    }
}
