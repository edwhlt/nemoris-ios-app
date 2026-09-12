import Foundation

/// Maps a NAF code (e.g. "10.71C") to a displayable Nemoris category.
/// Tolerates format variations (with or without a dot: "1071C" / "10.71C").
struct NAFCategory: Codable, Hashable {
    let label: String     // ex "Cuisson de produits de boulangerie"
    let category: String  // e.g. "Groceries" — matches Nemoris categories
    let icon: String      // SF Symbol
}

final class NAFCategoryMapper: Sendable {

    static let shared = NAFCategoryMapper()

    private let mapping: [String: NAFCategory]

    private init() {
        guard let url = Bundle.main.url(forResource: "naf_categories", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: NAFCategory].self, from: data) else {
            self.mapping = [:]
            return
        }
        self.mapping = parsed
    }

    /// Returns the category associated with a NAF code, trying several formats.
    /// E.g.: "1071C", "10.71C", "10.71 C" → all match the same entry.
    /// Every NAF code known to the reference data.
    ///
    /// Exposed so `CandidateRanker` stays PURE: it needs to know whether a NAF code
    /// is recognized (a small score bonus), but it must not read the bundle. So we
    /// pass it the set as plain data rather than this mapper as a dependency.
    var knownPrefixes: Set<String> { Set(mapping.keys) }

    func lookup(_ nafCode: String?) -> NAFCategory? {
        guard let raw = nafCode?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        // Essai 1 : tel quel
        if let direct = mapping[raw] { return direct }

        // Attempt 2: insert a dot after the first 2 digits if missing
        let digitsAndLetters = raw.filter { $0.isLetter || $0.isNumber }
        if digitsAndLetters.count >= 5 {
            let idx = digitsAndLetters.index(digitsAndLetters.startIndex, offsetBy: 2)
            let dotted = digitsAndLetters[..<idx] + "." + digitsAndLetters[idx...]
            if let viaDot = mapping[String(dotted)] { return viaDot }
        }

        // Attempt 3: strip every dot
        let stripped = raw.replacingOccurrences(of: ".", with: "")
        if let viaStripped = mapping[stripped] { return viaStripped }

        return nil
    }

    /// Default category when there's no NAF or no known mapping.
    func fallback() -> NAFCategory {
        NAFCategory(label: "Non classé", category: "Autre", icon: "questionmark.circle")
    }
}
