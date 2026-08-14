import Foundation

// Classement des candidats (entreprises, établissements, POI).
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Ce fichier existe pour tuer STRUCTURELLEMENT un bug, pas pour le contourner :
// `EnrichmentOrchestrator.enrichViaSirene` prenait `results.first` d'une concaténation de
// `withTaskGroup`. « Premier » y désignait l'ordre d'ACHÈVEMENT des tâches réseau, sans la
// moindre vérification que le candidat correspondait au lieu du libellé. Avec un ordre
// TOTAL calculé sur des critères explicites, le résultat ne peut plus dépendre de la
// latence réseau : à entrée identique, sortie identique (vérifié par t10, qui mélange le
// tableau 20 fois).

/// Candidat agnostique du fournisseur. Les adaptateurs (Sirene, MapKit, …) le construisent ;
/// le ranker ignore tout de leur provenance.
struct RankableCandidate: Hashable, Sendable {
    let id: String
    /// Tous les noms sous lesquels ce candidat peut matcher : raison sociale, nom complet,
    /// enseignes, nom commercial. Le meilleur score l'emporte.
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
    /// Le nom a matché via une enseigne plutôt que la raison sociale.
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

/// Décomposition du score, affichée dans « Détails de la recherche » et assertée par les tests.
struct RankBreakdown: Hashable, Sendable {
    var nameSimilarity: Double = 0
    var localityMatch: Double = 0
    var enseigneMatch: Double = 0
    var activeBonus: Double = 0
    var siegeBonus: Double = 0
    var nafKnownBonus: Double = 0

    /// Somme pondérée, bornée 0…1.
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

    /// Classe les candidats selon un ORDRE TOTAL, donc de façon reproductible.
    ///
    /// Départage, dans l'ordre : score ↓ · actif ↓ · siège ↓ · id ↑.
    /// Le dernier critère (`id`, toujours unique) garantit qu'aucune égalité ne subsiste,
    /// donc que l'ordre d'entrée n'a AUCUNE influence sur l'ordre de sortie.
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

    /// 0…1. **0.5 est le neutre** : quand le libellé ne portait aucune information de lieu,
    /// on ne peut ni récompenser ni punir un candidat pour sa géographie. Sans ce neutre,
    /// tout candidat serait pénalisé pour une information que le libellé n'avait pas.
    private static func localityScore(_ candidate: RankableCandidate,
                                      context: RankingContext) -> Double {
        if context.hasNoLocalityInfo { return 0.5 }

        // Code INSEE : identité exacte de commune.
        if let wanted = context.inseeCode, let got = candidate.inseeCode {
            return wanted == got ? 1.0 : 0.0
        }
        // Code postal.
        if !context.postalCodes.isEmpty, let got = candidate.postalCode {
            if context.postalCodes.contains(got) { return 1.0 }
            // Même département déduit des deux premiers chiffres.
            if let wantedDep = context.postalCodes.first?.prefix(2), got.hasPrefix(wantedDep) {
                return 0.6
            }
            return 0.0
        }
        // Libellé de commune.
        if let wanted = context.cityLabel, let got = candidate.cityLabel {
            let a = MerchantTokenSimilarity.tokenize(wanted)
            let b = MerchantTokenSimilarity.tokenize(got)
            if !a.isEmpty, a == b { return 0.9 }
            let similarity = MerchantTokenSimilarity.score(a, b)
            if similarity >= 0.7 { return 0.8 }
        }
        // Département seul.
        if let wantedDep = context.departmentCode, let got = candidate.postalCode {
            return got.hasPrefix(wantedDep) ? 0.6 : 0.0
        }
        // Localité NON RÉSOLUE : on la cherche telle quelle dans l'adresse.
        // C'est ce qui fait vivre le cas SROM/FLANCHES même quand geo.api.gouv.fr ne
        // connaît pas « Flanches » : un lieu-dit apparaît dans l'adresse de l'établissement.
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
            // Correspondance partielle : le libellé tronque les noms de lieux.
            let needleTokens = MerchantTokenSimilarity.tokenize(needle).filter { $0.count >= 3 }
            if !needleTokens.isEmpty, needleTokens.allSatisfy({ haystack.contains($0) }) {
                return 0.65
            }
            return 0.2
        }
        return 0.5
    }

    /// Le ranker n'a pas accès à `NAFCategoryMapper` (qui lit le bundle) : les préfixes
    /// connus lui sont passés en donnée, ce qui le garde pur.
    private static func isKnownNaf(_ code: String?, in prefixes: Set<String>) -> Bool {
        guard let code, !prefixes.isEmpty else { return false }
        if prefixes.contains(code) { return true }
        // Les codes NAF sont hiérarchiques : « 10.71C » relève de « 10.71 » puis « 10 ».
        var trimmed = code
        while trimmed.count > 2 {
            trimmed = String(trimmed.dropLast())
            if prefixes.contains(trimmed) { return true }
        }
        return false
    }
}
