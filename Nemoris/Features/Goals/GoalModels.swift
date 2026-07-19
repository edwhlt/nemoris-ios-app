import Foundation

// MARK: - Goal Models
//
// Objectifs financiers — table `goals` (migration v39). Le progress n'est PAS
// stocké : il se calcule en mémoire dans le ViewModel en croisant avec le
// `PatrimoineSnapshot` courant. Évite tout drift entre l'objectif et la réalité.

/// Type d'objectif — détermine comment on calcule le "current amount".
enum GoalKind: String, CaseIterable {
    /// Atteindre X € d'épargne. `current` = total des actifs liquides patrimoine.
    case savings    = "SAVINGS"
    /// Atteindre X € de patrimoine net. `current` = snapshot.netWorth.
    case netWorth   = "NETWORTH"
    /// Rembourser intégralement la dette. `current` = totalLiabilities, target = 0.
    /// Progress = (1 − current/initialDebt) — capé à 100%.
    case debtPayoff = "DEBT_PAYOFF"
    /// Objectif libre — l'user édite manuellement le "current" (pas de calcul auto).
    case custom     = "CUSTOM"

    var label: String {
        switch self {
        case .savings:    return "Épargne"
        case .netWorth:   return "Patrimoine net"
        case .debtPayoff: return "Rembourser la dette"
        case .custom:     return "Objectif libre"
        }
    }

    var systemIcon: String {
        switch self {
        case .savings:    return "banknote.fill"
        case .netWorth:   return "chart.pie.fill"
        case .debtPayoff: return "creditcard.trianglebadge.exclamationmark"
        case .custom:     return "star.fill"
        }
    }

    /// Hint affichée dans le form sous le picker pour expliquer le calcul.
    var explanation: String {
        switch self {
        case .savings:
            return "Suit le total des actifs liquides (livrets, comptes, PEA, espèces…). Le progress est mis à jour automatiquement à chaque ouverture."
        case .netWorth:
            return "Suit votre patrimoine net (actifs + immobilier − dettes). Calculé automatiquement."
        case .debtPayoff:
            return "Suit le capital restant dû sur l'ensemble de vos prêts. Atteint 100 % quand toutes les dettes sont remboursées."
        case .custom:
            return "Saisissez manuellement le montant déjà atteint. Utilisez ce type pour des objectifs non liés au patrimoine (ex. cagnotte voyage)."
        }
    }
}

/// Goal persisté en SQLite. `targetAmount` doit être positif ; `customCurrentAmount`
/// n'est utilisé que pour `kind == .custom`.
struct Goal: Identifiable, Hashable {
    let id: Int
    var name: String
    var kind: GoalKind
    var targetAmount: Double
    var deadlineDate: Date?      // nil = pas de deadline
    var customCurrentAmount: Double  // utilisé uniquement si kind == .custom
    var notes: String?
    let createdAt: Date
}

// MARK: - GoalProgress (calculé en mémoire)

/// Progress d'un goal à un instant T — calculé par `GoalsViewModel` en croisant
/// avec le `PatrimoineSnapshot`. Tous les montants en EUR.
struct GoalProgress: Equatable {
    let goal: Goal
    /// Montant actuellement atteint. Pour debt_payoff c'est la dette REMBOURSÉE
    /// (= initialDebt − currentDebt), pas la dette restante.
    let currentAmount: Double
    /// Ratio 0…1.0 (capé). 1.0 = objectif atteint, > 1.0 ramené à 1.0.
    let ratio: Double
    /// Jours restants jusqu'à la deadline. Négatif si dépassée. Nil si pas de deadline.
    let daysRemaining: Int?
    /// `true` si la deadline est passée mais l'objectif pas encore atteint.
    let isOverdue: Bool

    /// Vrai si l'objectif est atteint (≥ 100%).
    var isCompleted: Bool { ratio >= 1.0 }

    /// Montant restant à atteindre (target − current). 0 si déjà atteint.
    var amountRemaining: Double { max(0, goal.targetAmount - currentAmount) }

    var percentText: String { String(format: "%.0f %%", ratio * 100) }
}
