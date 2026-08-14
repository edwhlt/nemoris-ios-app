import Foundation

// Similarité entre deux noms commerciaux.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// ⚠️ Ce n'est PAS un doublon de `NemorisEngine.JaroWinkler`, et il ne faut pas les fusionner :
// les deux répondent à des questions différentes.
//   • Jaro-Winkler  : « est-ce une faute de frappe de l'autre ? »  (distance d'édition)
//   • F1 d'ensembles: « ces deux raisons sociales multi-mots se recouvrent-elles ? »
//
// Ici la question est la seconde. « BOULANGERIE PRALUS » vs « PRALUS LA BOULANGERIE » sont
// le même commerce dans le désordre — leur F1 d'ensembles vaut 0,8, leur Jaro-Winkler est
// médiocre parce que les chaînes commencent différemment. Inversement « SROM » et « SRAM »
// ont un excellent Jaro-Winkler et ne partagent aucun token : ce sont deux entreprises.
//
// Si on veut un jour de la tolérance à la faute de frappe ICI, la bonne manœuvre est de
// promouvoir l'implémentation du moteur, pas d'en recopier une seconde.

enum MerchantTokenSimilarity {

    /// F1 sur les ensembles de tokens, avec un bonus de préfixe.
    /// Renvoie 0…1. Symétrique.
    ///
    /// Le bonus de préfixe (jusqu'à +15 %) traite le cas central des relevés bancaires :
    /// les noms y sont TRONQUÉS en largeur fixe (`SC-PHIE MASSY V`, `APPLE COM/BILL`,
    /// `SOUNDCLOUD MONTH`). Un token du libellé qui est un préfixe d'un token du candidat
    /// compte comme une correspondance partielle, sans quoi toute enseigne coupée en deux
    /// serait mécaniquement mal classée.
    static func score(_ a: [String], _ b: [String]) -> Double {
        let left = normalize(a)
        let right = normalize(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let leftSet = Set(left)
        let rightSet = Set(right)
        let exact = leftSet.intersection(rightSet)

        // Correspondances par préfixe, sur les tokens non appariés exactement.
        // On apparie au plus une fois de chaque côté (pas de double comptage).
        var remainingLeft = leftSet.subtracting(exact)
        var remainingRight = rightSet.subtracting(exact)
        var prefixMatches = 0.0
        for l in remainingLeft.sorted() {
            guard let hit = remainingRight.sorted().first(where: { isPrefixMatch(l, $0) }) else { continue }
            remainingRight.remove(hit)
            remainingLeft.remove(l)
            prefixMatches += 1
        }

        // Un appariement par préfixe vaut moins qu'un appariement exact.
        let matched = Double(exact.count) + prefixMatches * 0.75
        guard matched > 0 else { return 0 }

        let precision = matched / Double(leftSet.count)
        let recall = matched / Double(rightSet.count)
        let f1 = 2 * precision * recall / (precision + recall)

        // Bonus si les deux chaînes démarrent pareil (enseigne en tête).
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

    /// Découpe + normalisation identiques partout dans le module.
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

    /// Un token tronqué correspond s'il est un préfixe d'au moins 3 caractères de l'autre.
    /// Le seuil de 3 évite que "de"/"la" apparient n'importe quoi.
    private static func isPrefixMatch(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 3, short.count < long.count else { return false }
        return long.hasPrefix(short)
    }

    /// Mots vides des raisons sociales françaises. Les garder ferait apparier
    /// « SARL DUPONT » et « SARL MARTIN » sur le seul « sarl ».
    enum StopWords {
        static let all: Set<String> = [
            "sarl", "sas", "sasu", "eurl", "sa", "sci", "snc", "scop", "scm", "selarl",
            "ei", "eirl", "gie", "association", "sté", "ste", "societe",
            "de", "du", "des", "la", "le", "les", "l", "d", "et", "aux", "au", "a"
        ]
    }
}
