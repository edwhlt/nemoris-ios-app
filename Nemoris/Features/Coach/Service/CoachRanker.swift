import Foundation

// MARK: - CoachRanker — arbitrage des recommandations
//
// Moteur PUR (`import Foundation` uniquement) : aucun accès base, réseau, IA
// ou SwiftUI. Même doctrine que `PortfolioEvolutionBuilder` /
// `EnvelopeSpendingCalculator` — la règle de priorité doit être testable sans
// modèle ni appareil, et surtout IDENTIQUE partout où l'app classe des
// recommandations (Dashboard top 3, liste d'un domaine, futurs consommateurs).
//
// ⚠️ L'arbitrage est DÉTERMINISTE, pas un troisième appel au modèle. Demander
// à une IA de classer ce qu'une IA vient de produire coûterait un aller-retour
// de plus, serait non reproductible d'un affichage à l'autre, et surtout
// intestable. Le modèle fournit les SIGNAUX (impact, effort, confiance) ; la
// pondération, elle, reste ici.

enum CoachRanker {

    // MARK: - Score

    /// Montant annuel à partir duquel l'impact sature à 1,0. Au-delà, c'est
    /// l'effort et la confiance qui départagent : entre « 4 000 €/an » et
    /// « 12 000 €/an », les deux sont déjà « énorme », et laisser le montant
    /// croître sans borne écraserait tout le reste du classement.
    static let impactCeiling: Double = 3_000

    /// Score attribué à une recommandation NON CHIFFRABLE (impact 0).
    ///
    /// ⚠️ Ne peut pas être 0. `Insight.compositeScore` multipliait les trois
    /// dimensions, donc tout insight à impact nul tombait mécaniquement à
    /// zéro et ne remontait JAMAIS — alors que « tu es à 70 % sur une seule
    /// ligne » est exactement le genre de conseil structurant qu'un
    /// consultant met en avant. Une valeur médiane le laisse concourir sur sa
    /// confiance et sa faisabilité.
    static let unquantifiedImpactScore: Double = 0.35

    /// Impact normalisé 0-1, sur une échelle LOGARITHMIQUE : l'écart utile
    /// entre 20 €/an et 200 €/an est bien plus grand que celui entre 2 000 €
    /// et 2 180 €, ce qu'une échelle linéaire ne rend pas.
    static func impactScore(_ annualImpact: Double) -> Double {
        guard annualImpact > 0 else { return unquantifiedImpactScore }
        let ratio = log10(1 + annualImpact) / log10(1 + impactCeiling)
        return min(1, max(0, ratio))
    }

    /// Priorité 0-1 d'une recommandation, toutes dimensions confondues.
    ///
    /// Pondération : impact 50 %, confiance 30 %, faisabilité 20 %. La
    /// confiance pèse plus que la faisabilité parce qu'une recommandation à
    /// laquelle le modèle ne croit qu'à moitié ne doit pas remonter juste
    /// parce qu'elle est facile à appliquer.
    static func score(_ reco: CoachRecommendation) -> Double {
        let impact = impactScore(reco.annualImpact)
        let effort = Double(min(5, max(1, reco.effort))) / 5.0
        let confidence = min(1, max(0, reco.confidence))
        return impact * 0.5 + confidence * 0.3 + effort * 0.2
    }

    // MARK: - Classement

    /// Trie par priorité décroissante. Départage STABLE en cas d'égalité
    /// (impact puis `ref`) : sans ça, deux affichages successifs de la même
    /// liste pourraient inverser deux cartes, ce qui donne l'impression que
    /// l'écran « bouge tout seul ».
    static func ranked(_ recos: [CoachRecommendation]) -> [CoachRecommendation] {
        recos.sorted { a, b in
            let sa = score(a), sb = score(b)
            if abs(sa - sb) > 0.0001 { return sa > sb }
            if abs(a.annualImpact - b.annualImpact) > 0.01 { return a.annualImpact > b.annualImpact }
            return a.ref < b.ref
        }
    }

    /// Les `limit` recommandations les plus importantes TOUS DOMAINES
    /// CONFONDUS — ce qu'affiche le Dashboard.
    ///
    /// ⚠️ Les recommandations rejetées ou déjà traitées sont écartées ICI,
    /// pas au niveau de la vue : le Dashboard et la liste d'un domaine
    /// doivent filtrer à l'identique, sinon une carte « faite » réapparaît
    /// sur un écran et pas sur l'autre.
    static func topAcrossDomains(_ recos: [CoachRecommendation], limit: Int = 3) -> [CoachRecommendation] {
        guard limit > 0 else { return [] }
        return Array(ranked(recos.filter { $0.status.isVisible }).prefix(limit))
    }

    /// Les recommandations visibles d'un domaine, classées.
    static func visible(_ recos: [CoachRecommendation], domain: CoachDomain) -> [CoachRecommendation] {
        ranked(recos.filter { $0.domain == domain && $0.status.isVisible })
    }

    // MARK: - Bornage des valeurs rendues par le modèle

    /// Ramène dans leurs bornes les trois signaux auto-évalués par le modèle.
    ///
    /// ⚠️ Indispensable : un modèle rend volontiers `effort: 12`, une
    /// confiance de `95` (au lieu de 0,95) ou un impact négatif. Sans
    /// normalisation, ces valeurs contaminent directement le classement.
    static func normalize(annualImpact: Double, effort: Int, confidence: Double)
        -> (annualImpact: Double, effort: Int, confidence: Double) {
        let impact = annualImpact.isFinite && annualImpact > 0 ? annualImpact : 0
        let boundedEffort = min(5, max(1, effort))
        // Un modèle qui répond « 85 » pense « 85 % » : on rattrape plutôt que
        // de tout écraser à 1,0, ce qui rendrait la dimension inutile.
        var conf = confidence.isFinite ? confidence : 0.5
        if conf > 1 { conf = conf / 100 }
        return (impact, boundedEffort, min(1, max(0, conf)))
    }
}
