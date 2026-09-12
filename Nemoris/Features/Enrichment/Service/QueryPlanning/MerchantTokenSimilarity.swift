import Foundation

// Similarity between two business names.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// ⚠️ This is NOT a duplicate of `NemorisEngine.JaroWinkler`, and they must not be merged:
// the two answer different questions.
//   • Jaro-Winkler  : "is this a typo of the other?" (edit distance)
//   • Set F1        : "do these two multi-word company names overlap?"
//
// Here the question is the second one. "BOULANGERIE PRALUS" vs "PRALUS LA BOULANGERIE" are
// the same shop in a different word order — their set F1 is 0.8, their Jaro-Winkler is
// mediocre because the strings start differently. Conversely "SROM" and "SRAM"
// have an excellent Jaro-Winkler and share no token at all: they're two companies.
//
// If typo tolerance is ever needed HERE, the right move is to
// promote the engine's implementation, not to copy a second one.

enum MerchantTokenSimilarity {

    /// F1 over token sets, with a prefix bonus.
    /// Returns 0…1. Symmetric.
    ///
    /// The prefix bonus (up to +15%) handles the central case of bank statements:
    /// names there are TRUNCATED at a fixed width (`SC-PHIE NIMES V`, `APPLE COM/BILL`,
    /// `SOUNDCLOUD MONTH`). A label token that is a prefix of a candidate token
    /// counts as a partial match, otherwise any chain name cut in half
    /// would be mechanically misranked.
    static func score(_ a: [String], _ b: [String]) -> Double {
        let left = normalize(a)
        let right = normalize(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let leftSet = Set(left)
        let rightSet = Set(right)
        let exact = leftSet.intersection(rightSet)

        // Prefix matches, on tokens not exactly matched.
        // Each side is matched at most once (no double counting).
        var remainingLeft = leftSet.subtracting(exact)
        var remainingRight = rightSet.subtracting(exact)
        var prefixMatches = 0.0
        for l in remainingLeft.sorted() {
            guard let hit = remainingRight.sorted().first(where: { isPrefixMatch(l, $0) }) else { continue }
            remainingRight.remove(hit)
            remainingLeft.remove(l)
            prefixMatches += 1
        }

        // A prefix match is worth less than an exact match.
        let matched = Double(exact.count) + prefixMatches * 0.75
        guard matched > 0 else { return 0 }

        let precision = matched / Double(leftSet.count)
        let recall = matched / Double(rightSet.count)
        let f1 = 2 * precision * recall / (precision + recall)

        // A bonus if both strings start the same way (chain name up front).
        let bonus = (left[0] == right[0] || isPrefixMatch(left[0], right[0])) ? 0.15 : 0.0
        return min(1, f1 * (1 + bonus))
    }

    /// Meilleur score de `query` contre plusieurs noms candidats (raison sociale,
    /// nom complet, enseignes, nom commercial…).
    static func bestScore(query: [String], against names: [String]) -> Double {
        var best = 0.0
        for name in names {
            let s = score(query, tokenize(name))
            if s > best { best = s }
        }
        return best
    }

    /// Splitting + normalization, identical everywhere in the module.
    static func tokenize(_ s: String) -> [String] {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Interne

    private static func normalize(_ tokens: [String]) -> [String] {
        tokens
            .map { $0.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR")).lowercased() }
            .filter { !$0.isEmpty && !StopWords.all.contains($0) }
    }

    /// A truncated token matches if it's a prefix of at least 3 characters of the other.
    /// The threshold of 3 keeps "de"/"la" from matching anything at all.
    private static func isPrefixMatch(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 3, short.count < long.count else { return false }
        return long.hasPrefix(short)
    }

    /// Stop words of French company names. Keeping them would match
    /// "SARL DUPONT" and "SARL MARTIN" on "sarl" alone.
    enum StopWords {
        static let all: Set<String> = [
            "sarl", "sas", "sasu", "eurl", "sa", "sci", "snc", "scop", "scm", "selarl",
            "ei", "eirl", "gie", "association", "sté", "ste", "societe",
            "de", "du", "des", "la", "le", "les", "l", "d", "et", "aux", "au", "a"
        ]
    }
}
