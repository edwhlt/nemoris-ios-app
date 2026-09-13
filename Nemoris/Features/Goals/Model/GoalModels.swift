import Foundation

// MARK: - Goal Models
//
// Financial goals — the `goals` table (migration v39). Progress is NOT
// stored: it's computed in memory in the ViewModel by cross-referencing the
// current `PatrimoineSnapshot`. Avoids any drift between the goal and reality.

/// Goal kind — determines how the "current amount" is computed.
enum GoalKind: String, CaseIterable {
    /// Reach €X in savings. `current` = total liquid Patrimoine assets.
    case savings    = "SAVINGS"
    /// Atteindre X € de patrimoine net. `current` = snapshot.netWorth.
    case netWorth   = "NETWORTH"
    /// Fully repay the debt. `current` = totalLiabilities, target = 0.
    /// Progress = (1 − current/initialDebt) — capped at 100%.
    case debtPayoff = "DEBT_PAYOFF"
    /// A free-form goal — the user manually edits the "current" value (no auto calculation).
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

    /// A hint shown in the form under the picker to explain the calculation.
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

/// A goal persisted in SQLite. `targetAmount` must be positive; `customCurrentAmount`
/// is only used for `kind == .custom`.
struct Goal: Identifiable, Hashable {
    let id: Int
    var name: String
    var kind: GoalKind
    var targetAmount: Double
    var deadlineDate: Date?      // nil = pas de deadline
    var customCurrentAmount: Double  // only used if kind == .custom
    var notes: String?
    let createdAt: Date
}

// MARK: - GoalProgress (computed in memory)

/// A goal's progress at a given point in time — computed by `GoalsViewModel` by
/// cross-referencing the `PatrimoineSnapshot`. All amounts in EUR.
struct GoalProgress: Equatable {
    let goal: Goal
    /// The amount currently reached. For debt_payoff this is the REPAID debt
    /// (= initialDebt − currentDebt), not the remaining debt.
    let currentAmount: Double
    /// A 0…1.0 ratio (capped). 1.0 = goal reached, > 1.0 clamped to 1.0.
    let ratio: Double
    /// Days remaining until the deadline. Negative if past. Nil if there's no deadline.
    let daysRemaining: Int?
    /// `true` if the deadline has passed but the goal isn't reached yet.
    let isOverdue: Bool

    /// True if the goal is reached (≥ 100%).
    var isCompleted: Bool { ratio >= 1.0 }

    /// The remaining amount to reach (target − current). 0 if already reached.
    var amountRemaining: Double { max(0, goal.targetAmount - currentAmount) }

    var percentText: String { String(format: "%.0f %%", ratio * 100) }
}
