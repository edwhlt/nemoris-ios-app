import Foundation

// MARK: - Insight Models
//
// Modèle unifié pour les insights générés par `InsightEngine`. Chaque insight a
// un `kind` (qui détermine le wording de base et l'icône), un `annualImpact`
// estimé en EUR (= gain potentiel sur 12 mois), une `actionability` (1-5, plus
// haut = plus facile à appliquer) et une `confidence` (0-1 basé sur la
// volumétrie historique).
//
// Le `compositeScore` agrège ces 3 dimensions pour permettre la hiérarchisation.

enum InsightKind: String, CaseIterable {
    /// Abonnement payé mais non utilisé depuis longtemps (= aucune transaction
    /// non-récurrente associée au merchant depuis N jours).
    case dormantSubscription
    /// Habitude quotidienne / fréquente avec montant unitaire faible (café,
    /// snack, etc.) qui cumulé devient significative.
    case smallFrequentHabit
    /// Plusieurs abonnements de la même nature (streaming vidéo, musique, SaaS)
    /// actifs en parallèle.
    case duplicateSubscriptions
    /// Catégorie dont les dépenses du mois sont significativement > moyenne
    /// des 3 mois précédents (drift positif).
    case categoryDrift
    /// Catégorie qui concentre l'essentiel du budget — utile pour matérialiser
    /// "ton plus gros poste de dépenses est X (Y % du total)".
    case topCategoryConcentration

    var systemIcon: String {
        switch self {
        case .dormantSubscription:        return "moon.zzz.fill"
        case .smallFrequentHabit:         return "cup.and.saucer.fill"
        case .duplicateSubscriptions:     return "rectangle.on.rectangle"
        case .categoryDrift:              return "arrow.up.right.circle.fill"
        case .topCategoryConcentration:   return "chart.pie.fill"
        }
    }

    /// Label court pour la catégorie d'insight (affiché en eyebrow).
    var label: String {
        switch self {
        case .dormantSubscription:        return "Abonnement dormant"
        case .smallFrequentHabit:         return "Habitude récurrente"
        case .duplicateSubscriptions:     return "Abonnements similaires"
        case .categoryDrift:              return "Dérive de catégorie"
        case .topCategoryConcentration:   return "Top dépenses"
        }
    }
}

struct Insight: Identifiable, Hashable {
    let id: String           // stable (= kind + reference) pour SwiftUI diff
    let kind: InsightKind
    /// Titre court (1 ligne max) prêt à être affiché. Wording de base statistique
    /// — sera potentiellement remplacé par le LLM (Couche 3) en V2.
    let title: LocalizedStringResource
    /// Détail développé (2-3 lignes) avec chiffres et action concrète.
    let detail: LocalizedStringResource
    /// Gain potentiel annuel estimé (€). 0 si l'insight est purement informatif.
    let annualImpact: Double
    /// Faisabilité 1-5. 5 = changement marginal trivial (1 clic), 1 = drastique.
    let actionability: Int
    /// Confiance 0-1 basée sur la volumétrie historique. Sous 0.3 l'insight
    /// est ignoré (trop peu de data pour conclure).
    let confidence: Double

    /// Score composite pour le tri. `annualImpact × actionability × confidence`
    /// — donne plus de poids aux actions à fort impact ET faciles à appliquer.
    var compositeScore: Double {
        annualImpact * Double(actionability) * confidence
    }
    
    static func == (lhs: Insight, rhs: Insight) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// `true` si l'insight a une recommandation actionable (vs purement informatif).
    var isActionable: Bool { annualImpact > 0 }
}
