import Foundation

// Raffinement d'un plan de requête.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT. Surtout pas `FoundationModels`.
//
// C'est le type que le planificateur consomme, produit indifféremment par :
//   • `DeterministicQueryRefiner`  — tables + règles, marche PARTOUT (iOS 18 inclus)
//   • `LLMQueryRefinementGenerable` — génération guidée, iOS/macOS 26 + Apple Intelligence
//
// Le fait que les deux chemins renvoient le MÊME type est la raison d'être du découpage :
// le planificateur n'a qu'UN seul chemin de code, et le corpus de test exerce donc le vrai
// chemin de production. C'est la doctrine CLAUDE.md (« ne jamais laisser deux chemins de
// code calculer la même chose différemment ») appliquée à la frontière de l'IA.

struct LLMQueryRefinement: Hashable, Sendable, Codable {
    /// Nom commercial seul, sans processeur ni ville ni référence.
    var merchantName: String?
    /// Ville / village / quartier tel qu'écrit dans le libellé.
    var localityName: String?
    var postalCode: String?
    /// ISO 3166-1 alpha-2, MAJUSCULES.
    var countryCode: String?
    var processorName: String?
    /// Abréviations développées en clair (« RES » → « restaurant »).
    var expandedTokens: [String]
    /// Virement nominatif vers un particulier.
    var isPersonNotBusiness: Bool
    /// 0…1.
    var confidence: Double
    var rationale: String?

    init(merchantName: String? = nil,
         localityName: String? = nil,
         postalCode: String? = nil,
         countryCode: String? = nil,
         processorName: String? = nil,
         expandedTokens: [String] = [],
         isPersonNotBusiness: Bool = false,
         confidence: Double = 0,
         rationale: String? = nil) {
        self.merchantName = merchantName
        self.localityName = localityName
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.processorName = processorName
        self.expandedTokens = expandedTokens
        self.isPersonNotBusiness = isPersonNotBusiness
        self.confidence = min(1, max(0, confidence))
        self.rationale = rationale
    }

    /// Élément neutre : n'apporte rien, ne retire rien.
    static let none = LLMQueryRefinement()

    var isEmpty: Bool {
        merchantName == nil && localityName == nil && postalCode == nil
            && countryCode == nil && expandedTokens.isEmpty && !isPersonNotBusiness
    }
}

// MARK: - Normalisation partagée avec le chemin @Generable

/// Le modèle renvoie des CHAÎNES VIDES plutôt que des optionnels (schéma plus plat, plus
/// robuste d'une version d'OS à l'autre). Cette fonction fait la conversion, le clamp et
/// la mise en majuscules.
///
/// Elle vit ici, dans un fichier PUR, et non dans le fichier `@Generable` : la macro n'est
/// pas testable au harness, mais ce mapping — vide→nil, bornes, casse — l'est, et c'est là
/// que se logent les vraies erreurs. `GeneratedQueryPlan.toRefinement()` n'est qu'un
/// renvoi d'une ligne vers cette fonction.
enum GeneratedQueryPlanMapping {

    static func map(merchantName: String,
                    localityName: String,
                    postalCode: String,
                    countryCode: String,
                    processorName: String,
                    expandedTokens: [String],
                    isPersonNotBusiness: Bool,
                    confidence: Double) -> LLMQueryRefinement {
        LLMQueryRefinement(
            merchantName: clean(merchantName),
            localityName: clean(localityName).map { $0.lowercased() },
            postalCode: clean(postalCode).flatMap { pc in
                // Un code postal FR fait exactement 5 chiffres. Tout le reste est du bruit
                // halluciné qu'on ne veut pas voir partir en filtre `code_postal`.
                pc.count == 5 && pc.allSatisfy(\.isNumber) ? pc : nil
            },
            countryCode: clean(countryCode).flatMap { cc in
                cc.count == 2 ? ForeignLocalityTable.normalizeCountryCode(cc) : nil
            },
            processorName: clean(processorName).map { $0.lowercased() },
            expandedTokens: expandedTokens.compactMap { clean($0)?.lowercased() },
            isPersonNotBusiness: isPersonNotBusiness,
            confidence: min(1, max(0, confidence))
        )
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Le modèle écrit parfois littéralement "null" / "none" quand il ne sait pas.
        guard !t.isEmpty, t.lowercased() != "null", t.lowercased() != "none" else { return nil }
        return t
    }
}
