import Foundation

/// Mappe un code NAF (ex "10.71C") vers une catégorie Nemoris affichable.
/// Tolère les variations de format (avec ou sans point : "1071C" / "10.71C").
struct NAFCategory: Codable, Hashable {
    let label: String     // ex "Cuisson de produits de boulangerie"
    let category: String  // ex "Alimentation" — match les catégories Nemoris
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

    /// Retourne la catégorie associée à un code NAF, en essayant plusieurs formats.
    /// Ex: "1071C", "10.71C", "10.71 C" → toutes matchent la même entrée.
    func lookup(_ nafCode: String?) -> NAFCategory? {
        guard let raw = nafCode?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        // Essai 1 : tel quel
        if let direct = mapping[raw] { return direct }

        // Essai 2 : insérer un point après les 2 premiers chiffres si absent
        let digitsAndLetters = raw.filter { $0.isLetter || $0.isNumber }
        if digitsAndLetters.count >= 5 {
            let idx = digitsAndLetters.index(digitsAndLetters.startIndex, offsetBy: 2)
            let dotted = digitsAndLetters[..<idx] + "." + digitsAndLetters[idx...]
            if let viaDot = mapping[String(dotted)] { return viaDot }
        }

        // Essai 3 : retirer tout point
        let stripped = raw.replacingOccurrences(of: ".", with: "")
        if let viaStripped = mapping[stripped] { return viaStripped }

        return nil
    }

    /// Catégorie par défaut quand on n'a pas de NAF ou pas de mapping connu.
    func fallback() -> NAFCategory {
        NAFCategory(label: "Non classé", category: "Autre", icon: "questionmark.circle")
    }
}
