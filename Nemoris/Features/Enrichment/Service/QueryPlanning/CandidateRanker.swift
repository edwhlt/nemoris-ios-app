import Foundation

// Ranking candidates (companies, establishments, POIs).
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// This file exists to STRUCTURALLY kill a bug, not to work around it:
// `EnrichmentOrchestrator.enrichViaSirene` used to take `results.first` of a
// `withTaskGroup` concatenation. "First" there meant the COMPLETION order of the network
// tasks, with no check at all that the candidate matched the label's location. With a TOTAL
// order computed on explicit criteria, the result can no longer depend on network
// latency: same input, same output (verified by t10, which shuffles the
// array 20 times).

/// A provider-agnostic candidate. Adapters (Sirene, MapKit, …) build it;
/// the ranker knows nothing about their origin.
struct RankableCandidate: Hashable, Sendable {
    let id: String
    /// Every name this candidate can match under: company name, full name,
    /// trade names, commercial name. The best score wins.
    let names: [String]
    let addressLine: String?
    let postalCode: String?
    let cityLabel: String?
    let inseeCode: String?
    let isHeadquarters: Bool
    let isActive: Bool
    let nafCode: String?
    let hasCoordinates: Bool
    /// sirene 1.0 · googlePlaces 0.85 · mapkit 0.7 · llm 0.6
    let providerWeight: Double
    /// The name matched via a trade name rather than the company name.
    let matchedViaEnseigne: Bool

    init(id: String,
         names: [String],
         addressLine: String? = nil,
         postalCode: String? = nil,
         cityLabel: String? = nil,
         inseeCode: String? = nil,
         isHeadquarters: Bool = false,
         isActive: Bool = true,
         nafCode: String? = nil,
         hasCoordinates: Bool = false,
         providerWeight: Double = 1.0,
         matchedViaEnseigne: Bool = false) {
        self.id = id
        self.names = names
        self.addressLine = addressLine
        self.postalCode = postalCode
        self.cityLabel = cityLabel
        self.inseeCode = inseeCode
        self.isHeadquarters = isHeadquarters
        self.isActive = isActive
        self.nafCode = nafCode
        self.hasCoordinates = hasCoordinates
        self.providerWeight = providerWeight
        self.matchedViaEnseigne = matchedViaEnseigne
    }
}

/// Score breakdown, shown in "Search details" and asserted by the tests.
struct RankBreakdown: Hashable, Sendable {
    var nameSimilarity: Double = 0
    var localityMatch: Double = 0
    var enseigneMatch: Double = 0
    var activeBonus: Double = 0
    var siegeBonus: Double = 0
    var nafKnownBonus: Double = 0

    /// Weighted sum, clamped to 0…1.
    var weightedTotal: Double {
        let raw = nameSimilarity * 0.45
            + localityMatch * 0.30
            + enseigneMatch * 0.10
            + activeBonus * 0.05
            + siegeBonus * 0.05
            + nafKnownBonus * 0.05
        return min(1, max(0, raw))
    }
}

struct RankedCandidate: Hashable, Sendable, Identifiable {
    let candidate: RankableCandidate
    let score: Double
    let breakdown: RankBreakdown
    var id: String { candidate.id }
}

enum CandidateRanker {

    /// Ranks candidates by a TOTAL ORDER, so reproducibly.
    ///
    /// Tiebreaks, in order: score ↓ · active ↓ · headquarters ↓ · id ↑.
    /// The last criterion (`id`, always unique) guarantees no tie ever survives,
    /// so the input order has NO influence on the output order.
    static func rank(_ candidates: [RankableCandidate], context: RankingContext) -> [RankedCandidate] {
        candidates
            .map { candidate in
                let breakdown = score(candidate, context: context)
                return RankedCandidate(
                    candidate: candidate,
                    score: breakdown.weightedTotal * candidate.providerWeight,
                    breakdown: breakdown
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.candidate.isActive != rhs.candidate.isActive { return lhs.candidate.isActive }
                if lhs.candidate.isHeadquarters != rhs.candidate.isHeadquarters {
                    return lhs.candidate.isHeadquarters
                }
                return lhs.candidate.id < rhs.candidate.id
            }
    }

    // MARK: - Score

    static func score(_ candidate: RankableCandidate, context: RankingContext) -> RankBreakdown {
        var breakdown = RankBreakdown()
        breakdown.nameSimilarity = MerchantTokenSimilarity.bestScore(
            query: context.nameTokens, against: candidate.names
        )
        breakdown.localityMatch = localityScore(candidate, context: context)
        breakdown.enseigneMatch = candidate.matchedViaEnseigne ? 1 : 0
        breakdown.activeBonus = candidate.isActive ? 1 : 0
        breakdown.siegeBonus = candidate.isHeadquarters ? 1 : 0
        breakdown.nafKnownBonus = isKnownNaf(candidate.nafCode, in: context.knownNafPrefixes) ? 1 : 0
        return breakdown
    }

    /// 0…1. **0.5 is neutral**: when the label carried no location information at
    /// all, a candidate can't be rewarded or punished for its geography. Without this
    /// neutral value, every candidate would be penalized for information the label never had.
    private static func localityScore(_ candidate: RankableCandidate,
                                      context: RankingContext) -> Double {
        if context.hasNoLocalityInfo { return 0.5 }

        // INSEE code: exact commune identity.
        if let wanted = context.inseeCode, let got = candidate.inseeCode {
            return wanted == got ? 1.0 : 0.0
        }
        // Code postal.
        if !context.postalCodes.isEmpty, let got = candidate.postalCode {
            if context.postalCodes.contains(got) { return 1.0 }
            // Same department inferred from the first two digits.
            if let wantedDep = context.postalCodes.first?.prefix(2), got.hasPrefix(wantedDep) {
                return 0.6
            }
            return 0.0
        }
        // Commune name.
        if let wanted = context.cityLabel, let got = candidate.cityLabel {
            let a = MerchantTokenSimilarity.tokenize(wanted)
            let b = MerchantTokenSimilarity.tokenize(got)
            if !a.isEmpty, a == b { return 0.9 }
            let similarity = MerchantTokenSimilarity.score(a, b)
            if similarity >= 0.7 { return 0.8 }
        }
        // Department alone.
        if let wantedDep = context.departmentCode, let got = candidate.postalCode {
            return got.hasPrefix(wantedDep) ? 0.6 : 0.0
        }
        // UNRESOLVED locality: we look for it as-is in the address.
        // This is what keeps the SROM/FLANCHES case working even when geo.api.gouv.fr
        // doesn't know "Flanches": a place name shows up in the establishment's address.
        if let free = context.freeLocalityText, !free.isEmpty {
            let haystack = [candidate.addressLine, candidate.cityLabel]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
                .lowercased()
            guard !haystack.isEmpty else { return 0.5 }
            let needle = free.folding(options: .diacriticInsensitive,
                                      locale: Locale(identifier: "fr_FR")).lowercased()
            if haystack.contains(needle) { return 0.7 }
            // Partial match: the label truncates place names.
            let needleTokens = MerchantTokenSimilarity.tokenize(needle).filter { $0.count >= 3 }
            if !needleTokens.isEmpty, needleTokens.allSatisfy({ haystack.contains($0) }) {
                return 0.65
            }
            return 0.2
        }
        return 0.5
    }

    /// The ranker has no access to `NAFCategoryMapper` (which reads the bundle): known
    /// prefixes are passed in as data, which keeps it pure.
    private static func isKnownNaf(_ code: String?, in prefixes: Set<String>) -> Bool {
        guard let code, !prefixes.isEmpty else { return false }
        if prefixes.contains(code) { return true }
        // NAF codes are hierarchical: "10.71C" falls under "10.71" then "10".
        var trimmed = code
        while trimmed.count > 2 {
            trimmed = String(trimmed.dropLast())
            if prefixes.contains(trimmed) { return true }
        }
        return false
    }
}
