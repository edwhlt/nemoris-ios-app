import Foundation

// Refinement WITHOUT AI.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// Produces the exact same `LLMQueryRefinement` as the `@Generable` path. That's
// what guarantees iOS 18 (no FoundationModels) and iOS 26 take the same
// planning path, and that the test corpus measures the actual production
// path.
//
// It doesn't replace the model: it covers what's decidable by rules
// (processor, country code, known foreign city, named transfer, abbreviations). The
// model, in turn, can read a garbled multilingual string — that's its only real
// advantage.

enum DeterministicQueryRefiner {

    /// Patterns for a named transfer to a private individual.
    /// "VIR DE M DIDIER HELET", "VIR INST WERO M NATHAN LAURENT", "VIR SEPA RECU M DUPONT".
    private static let personTitles: Set<String> = [
        "m", "mr", "mme", "mlle", "mle", "melle", "monsieur", "madame"
    ]

    /// Words that, in a transfer, denote an internal operation and NOT a person
    /// ("VIR LIVRET JEUNE", "VIR EPARGNE SAL") — must not be classified as a private individual.
    /// ⚠️ "remboursement" (refund) does NOT belong here: paying back a friend is the most
    /// common case of a transfer between individuals ("VIR INST WERO M ADAM FOURNIER
    /// REMBOURSEMENT PHILIPPINES"). Putting it here canceled detection on those lines.
    private static let nonPersonTransferMarkers: Set<String> = [
        "livret", "compte", "epargne", "pel", "cel", "ldd", "ldds", "pea", "assurance",
        "loyer", "salaire", "caf", "cpam", "urssaf", "impots", "tresor"
    ]

    static func refine(rawLabel: String, tokens: [String]) -> LLMQueryRefinement {
        guard !tokens.isEmpty else { return .none }

        var refinement = LLMQueryRefinement()
        var working = tokens

        // 1) Processeur de paiement.
        if let processor = working.first(where: { AbbreviationTable.isPaymentProcessor($0) }) {
            refinement.processorName = processor
        }

        // 2) Virement nominatif → personne physique.
        refinement.isPersonNotBusiness = detectPerson(tokens: working)

        // 3) Known foreign city → ALSO gives the country.
        if let hit = ForeignLocalityTable.findCity(in: working) {
            refinement.localityName = hit.name
            refinement.countryCode = hit.countryCode
            working.removeSubrange(hit.range)
        }

        // 4) Isolated country code, ONLY in final or second-to-last position.
        //    Without this position constraint, "CB CARREFOUR" would see "cb" as a
        //    country, and "SC-X2M VERNON" or "JD PARIS" would turn into anything at all.
        if refinement.countryCode == nil {
            for index in working.indices.suffix(2) where index >= 0 {
                let token = working[index]
                guard token.count == 2, token.allSatisfy(\.isLetter),
                      ForeignLocalityTable.countryCodes.contains(token) else { continue }
                refinement.countryCode = ForeignLocalityTable.normalizeCountryCode(token)
                break
            }
        }

        // 5) French postal code: 5 digits anywhere.
        if let pc = working.first(where: { $0.count == 5 && $0.allSatisfy(\.isNumber) }) {
            refinement.postalCode = pc
            if refinement.countryCode == nil { refinement.countryCode = "FR" }
        }

        // 6) Expanded abbreviations, for map search.
        let expanded = AbbreviationTable.expand(working)
        if expanded != working {
            refinement.expandedTokens = zip(working, expanded)
                .filter { $0 != $1 }
                .map(\.1)
        }

        // The deterministic refiner doesn't PROPOSE a name: splitting name/locality is
        // the planner's job (bank template then heuristic), which knows more
        // than these rules. Proposing a `merchantName` here would overwrite a
        // better split.
        refinement.confidence = refinement.isEmpty ? 0 : 0.5
        refinement.rationale = "Règles déterministes (sans IA)"
        return refinement
    }

    /// A transfer to a private individual: a title followed by at least one
    /// alphabetical word, in a transfer-type label, with no internal-operation marker.
    private static func detectPerson(tokens: [String]) -> Bool {
        let isTransfer = tokens.contains { $0 == "vir" || $0 == "virement" }
        guard isTransfer else { return false }
        guard !tokens.contains(where: { nonPersonTransferMarkers.contains($0) }) else { return false }

        for (index, token) in tokens.enumerated() where personTitles.contains(token) {
            // A title right at the end denotes nobody.
            guard index + 1 < tokens.count else { continue }
            // ⚠️ An acronym spelled letter by letter contains "M"s that are NOT
            // titles: "VIR C P A M TROYES" is the CPAM, not Mister Troyes.
            // The distinguishing sign is the PRECEDING token: an isolated letter signals
            // spelling-out, a word signals a real title ("VIR INST WERO **M** ADAM …").
            if index > 0, tokens[index - 1].count == 1, tokens[index - 1].allSatisfy(\.isLetter) {
                continue
            }
            let next = tokens[index + 1]
            // The following word must look like a name, not an initial or an acronym.
            if next.count >= 3, next.allSatisfy(\.isLetter),
               !AbbreviationTable.isBankPrefix(next),
               !AbbreviationTable.isPaymentProcessor(next) {
                return true
            }
        }
        return false
    }
}
