import Foundation

// MARK: - GoalCalculator
//
// Calcul pur (sans état) du `GoalProgress` à partir d'un `Goal` et du contexte
// Patrimoine courant (`PatrimoineSnapshot` + historique de dette initial pour
// les debt_payoff). Pas de dépendance SQLite, pas de side effect — testable
// unitairement et appelable depuis n'importe quel VM.
//
// **Pourquoi pas dans le VM directement ?**
//   - Séparation de préoccupations : le VM s'occupe de la collection et du
//     refresh ; le calculator s'occupe du "comment je calcule".
//   - Testabilité : on peut tester chaque kind de goal avec des inputs fixes.
//   - Réutilisabilité : la projection (étape 4b) réutilisera la même logique
//     pour estimer des Goals atteints dans le futur.

enum GoalCalculator {

    /// Calcule le `GoalProgress` à partir du contexte Patrimoine fourni.
    ///
    /// - Parameters:
    ///   - goal: l'objectif à évaluer
    ///   - snapshot: snapshot patrimoine courant (vu d'aujourd'hui)
    ///   - totalAssetsValue: valeur des assets liquides (déjà résolus depuis les comptes liés)
    ///   - initialDebtForPayoff: dette de référence pour calculer le % de remboursement
    ///     (typiquement la dette au moment de la création du goal, ou la dette MAX si on
    ///     préfère "depuis le pic"). Si nil, on tombe sur `snapshot.totalLiabilities` à
    ///     la date courante, ce qui donnerait toujours 0% — donc à éviter.
    ///   - asOf: date d'évaluation, défaut `Date()`. Sert seulement à calculer
    ///     `daysRemaining`.
    static func progress(for goal: Goal,
                         snapshot: PatrimoineSnapshot,
                         totalAssetsValue: Double,
                         initialDebtForPayoff: Double? = nil,
                         asOf reference: Date = Date()) -> GoalProgress {

        // 1) Résolution du `currentAmount` selon le kind.
        let current: Double
        switch goal.kind {
        case .savings:
            current = max(0, totalAssetsValue)
        case .netWorth:
            current = max(0, snapshot.netWorth)
        case .debtPayoff:
            // current = montant REMBOURSÉ = initialDebt − dette actuelle.
            // Borné à [0, initialDebt] pour éviter les valeurs négatives si la
            // dette a augmenté (rare mais possible : nouveau prêt après création
            // du goal).
            let initial = initialDebtForPayoff ?? snapshot.totalLiabilities
            current = max(0, min(initial, initial - snapshot.totalLiabilities))
        case .custom:
            current = max(0, goal.customCurrentAmount)
        }

        // 2) Ratio capé à 1.0. Cas dégénéré target_amount == 0 → ratio = 0
        //    pour éviter la division par zéro et un affichage "100% atteint"
        //    trompeur sur un goal mal saisi.
        let ratio: Double = {
            // debt_payoff avec target = 0 = "rembourser entièrement". Dans ce cas
            // le ratio est current / initialDebt (et non current / target qui serait /0).
            if goal.kind == .debtPayoff && goal.targetAmount == 0 {
                let initial = initialDebtForPayoff ?? snapshot.totalLiabilities
                guard initial > 0 else { return 0 }
                return min(1.0, current / initial)
            }
            guard goal.targetAmount > 0 else { return 0 }
            return min(1.0, current / goal.targetAmount)
        }()

        // 3) Days remaining (uniquement si deadline)
        var daysRemaining: Int? = nil
        var isOverdue = false
        if let deadline = goal.deadlineDate {
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents([.day],
                                           from: cal.startOfDay(for: reference),
                                           to: cal.startOfDay(for: deadline))
            daysRemaining = comps.day
            isOverdue = (comps.day ?? 0) < 0 && ratio < 1.0
        }

        return GoalProgress(
            goal: goal,
            currentAmount: current,
            ratio: ratio,
            daysRemaining: daysRemaining,
            isOverdue: isOverdue
        )
    }

    /// Mensualité à mettre de côté pour atteindre l'objectif d'ici la deadline,
    /// au rythme constant. Nil si pas de deadline ou si l'objectif est déjà
    /// atteint (rien à faire).
    ///
    /// Sert d'**indicateur d'action** dans la row du goal : "Il vous faut
    /// économiser 320 €/mois pour atteindre cet objectif d'ici décembre".
    static func monthlyContributionNeeded(for progress: GoalProgress,
                                          asOf reference: Date = Date()) -> Double? {
        guard let deadline = progress.goal.deadlineDate else { return nil }
        guard !progress.isCompleted else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.month],
                                       from: cal.startOfDay(for: reference),
                                       to: cal.startOfDay(for: deadline))
        let months = max(1, comps.month ?? 1)  // jamais < 1 mois pour éviter /0 + UI explosée
        return progress.amountRemaining / Double(months)
    }
}
