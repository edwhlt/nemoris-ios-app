import Foundation

// MARK: - InsightEngine
//
// Moteur de détection des "insights" — opportunités d'optimisation détectées
// statistiquement à partir de l'historique de l'user. Pas de ML / LLM ici :
// 5 détecteurs purs déterministes. Le wording naturel sera optionnellement
// posé par Foundation Models (Couche 3 — voir `InsightLLMService` si activé).
//
// **Philosophie** : on préfère 3 insights solides et actionnables à 20
// insights vagues. Les seuils sont calibrés pour ne déclencher que sur des
// signaux statistiquement robustes.

enum InsightEngine {

    /// Période d'analyse — 180 jours = 6 mois glissants. Permet d'avoir une
    /// baseline solide pour la détection de drift et la moyenne des fréquences.
    private static let analysisDays = 180

    /// Génère tous les insights pertinents, triés par `compositeScore` décroissant.
    /// Cap à 8 insights max — au-delà ça devient du bruit pour l'user.
    static func compute() -> [Insight] {
        let txRepo = TransactionRepository()
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        guard let from = cal.date(byAdding: .day, value: -analysisDays, to: now) else { return [] }

        let txs = txRepo.fetchTransactionsAllAccounts(from: from, to: now, limit: 10000, offset: 0)
        let allCategories = txRepo.fetchCategories()
        let allTiers = txRepo.fetchTiers()
        let patterns = BudgetRepository.shared.fetchActivePatterns()

        var insights: [Insight] = []
        insights.append(contentsOf: detectDormantSubscriptions(patterns: patterns, txs: txs, allTiers: allTiers))
        insights.append(contentsOf: detectSmallFrequentHabits(txs: txs, allTiers: allTiers))
        insights.append(contentsOf: detectDuplicateSubscriptions(patterns: patterns, allCategories: allCategories))
        insights.append(contentsOf: detectCategoryDrift(txs: txs, allCategories: allCategories, now: now, cal: cal))
        insights.append(contentsOf: detectTopCategoryConcentration(txs: txs, allCategories: allCategories))

        // Filtre par confiance minimale et tri par score
        return insights
            .filter { $0.confidence >= 0.3 }
            .sorted { $0.compositeScore > $1.compositeScore }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - 1. Abonnements dormants

    /// Détecte les récurrents `MONTHLY` ou `YEARLY` dont le payee n'a pas eu
    /// de transaction additionnelle non-récurrente depuis 90+ jours — signal
    /// classique d'un abonnement payé mais non consommé (Netflix, Disney+,
    /// applis qu'on a oublié de désabonner).
    private static func detectDormantSubscriptions(
        patterns: [RecurringPattern],
        txs: [FinanceTransaction],
        allTiers: [Tiers]
    ) -> [Insight] {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let dormancyThresholdDays = 90

        var result: [Insight] = []
        for pattern in patterns where pattern.isExpense {
            guard let payeeId = pattern.payeeId else { continue }
            // Dernière transaction ASSOCIÉE au payee (toutes, pas seulement récurrente).
            // En MVP on n'a pas de flag "is_recurring_match" → approximation : on
            // prend la dernière tx du payee. Si elle est récente (≤ 90j) on
            // considère que l'user "consomme" — pas d'insight. Sinon on alerte.
            let payeeTxs = txs.filter { $0.tiersId == payeeId }.sorted { $0.date > $1.date }
            guard let last = payeeTxs.first else { continue }
            let daysSinceLast = cal.dateComponents([.day], from: last.date, to: now).day ?? 0
            guard daysSinceLast >= dormancyThresholdDays else { continue }

            // Coût annuel = mensualité × 12 ou montant tel quel pour yearly
            let annualCost: Double = {
                switch pattern.frequency {
                case .monthly: return abs(pattern.amountAvg) * 12
                case .yearly:  return abs(pattern.amountAvg)
                case .weekly:  return abs(pattern.amountAvg) * 52
                case .daily:   return abs(pattern.amountAvg) * 365
                }
            }()

            let payeeName = allTiers.first(where: { $0.id == payeeId })?.name ?? pattern.name
            result.append(Insight(
                id: "dormant_\(payeeId)",
                kind: .dormantSubscription,
                title: "\(payeeName) — non utilisé depuis \(daysSinceLast) jours",
                detail: "Vous payez \(monthlyEquivalent(pattern).formatted(.currency(code: "EUR").presentation(.narrow)))/mois pour \(payeeName) mais aucune transaction associée n'apparaît depuis \(daysSinceLast) jours. Envisagez de résilier — \(annualCost.formatted(.currency(code: "EUR").presentation(.narrow))) économisés par an.",
                annualImpact: annualCost,
                actionability: 5,  // Désabonnement = 1 clic dans Réglages → Abonnements iOS
                confidence: min(1.0, Double(daysSinceLast) / 180.0)  // Plus dormant longtemps → plus confiant
            ))
        }
        return result
    }

    // MARK: - 2. Habitudes café/snack

    /// Détecte les payees où l'user a un comportement "rituel" : fréquence
    /// élevée (≥ 8 transactions / 90 jours) ET montant unitaire faible
    /// (≤ 10 €). Typiquement : café Starbucks, snack midi, viennoiseries.
    /// La somme cumulée annuelle peut être surprenante pour l'user.
    private static func detectSmallFrequentHabits(
        txs: [FinanceTransaction],
        allTiers: [Tiers]
    ) -> [Insight] {
        let now = Date()
        let last90 = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let recentExpenses = txs.filter { $0.amount < 0 && $0.date >= last90 && $0.tiersId != nil }

        // Group par tiersId
        var byTier: [Int: [FinanceTransaction]] = [:]
        for tx in recentExpenses {
            byTier[tx.tiersId!, default: []].append(tx)
        }

        var result: [Insight] = []
        for (tierId, group) in byTier {
            let count = group.count
            guard count >= 8 else { continue }
            let totalAbs = group.reduce(0.0) { $0 + abs($1.amount) }
            let unitAvg = totalAbs / Double(count)
            guard unitAvg <= 10.0 else { continue }  // Filtre montants > 10 €
            // Projection annuelle
            let annualCost = totalAbs * (365.0 / 90.0)
            // Cas "réduction de moitié" : combien on économiserait en diminuant
            // la fréquence de 50 %
            let potentialSaving = annualCost * 0.5

            let payeeName = allTiers.first(where: { $0.id == tierId })?.name ?? "Inconnu"
            result.append(Insight(
                id: "habit_\(tierId)",
                kind: .smallFrequentHabit,
                title: "\(payeeName) — \(count) achats en 90 j à ~\(unitAvg.formatted(.currency(code: "EUR").presentation(.narrow)))",
                detail: "Cumulé sur l'année : \(annualCost.formatted(.currency(code: "EUR").presentation(.narrow))). Réduire la fréquence de moitié → \(potentialSaving.formatted(.currency(code: "EUR").presentation(.narrow))) économisés/an.",
                annualImpact: potentialSaving,
                actionability: 3,  // Changement d'habitude — pas trivial mais réalisable
                confidence: min(1.0, Double(count) / 30.0)  // Plus de tx → plus de confiance
            ))
        }
        return result
    }

    // MARK: - 3. Abonnements similaires (doublons)

    /// Détecte plusieurs récurrents actifs dans la même catégorie (ex : Netflix +
    /// Disney+ + Apple TV simultanés). Pas une recommandation explicite de
    /// "supprimer le plus cher" — juste un éclairage que l'user a peut-être
    /// oublié de combien il en avait.
    private static func detectDuplicateSubscriptions(
        patterns: [RecurringPattern],
        allCategories: [Category]
    ) -> [Insight] {
        let expensePatterns = patterns.filter { $0.isExpense && $0.categoryId != nil }
        var byCategory: [Int: [RecurringPattern]] = [:]
        for p in expensePatterns {
            byCategory[p.categoryId!, default: []].append(p)
        }

        var result: [Insight] = []
        for (cid, group) in byCategory {
            guard group.count >= 2 else { continue }
            let monthlyTotal = group.reduce(0.0) { $0 + monthlyEquivalent($1) }
            let catName = allCategories.first(where: { $0.id == cid })?.name ?? "Catégorie"
            let names = group.map { $0.name }.joined(separator: ", ")
            result.append(Insight(
                id: "dup_\(cid)",
                kind: .duplicateSubscriptions,
                title: "\(group.count) abonnements actifs en \(catName)",
                detail: "Vous payez actuellement \(names) — total \(monthlyTotal.formatted(.currency(code: "EUR").presentation(.narrow)))/mois (\((monthlyTotal*12).formatted(.currency(code: "EUR").presentation(.narrow)))/an). Vérifiez si tous sont vraiment utilisés.",
                annualImpact: monthlyTotal * 12 * 0.3,  // Hypothèse : 30 % réduction possible
                actionability: 4,
                confidence: 0.7
            ))
        }
        return result
    }

    // MARK: - 4. Drift de catégorie

    /// Détecte les catégories dont les dépenses du dernier mois sont
    /// significativement (> +25 %) au-dessus de la moyenne des 3 mois précédents.
    /// Signal d'une dérive comportementale récente que l'user n'a peut-être pas
    /// remarquée.
    private static func detectCategoryDrift(
        txs: [FinanceTransaction],
        allCategories: [Category],
        now: Date,
        cal: Calendar
    ) -> [Insight] {
        guard let lastMonthStart = cal.date(byAdding: .day, value: -30, to: now),
              let baselineStart = cal.date(byAdding: .day, value: -120, to: now) else { return [] }

        let recentExpenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }
        // Sum par cat sur dernier mois ET sur baseline 90 j antérieurs
        var lastMonth: [Int: Double] = [:]
        var baseline: [Int: Double] = [:]
        for tx in recentExpenses {
            guard let cid = tx.categoryId else { continue }
            if tx.date >= lastMonthStart {
                lastMonth[cid, default: 0] += abs(tx.amount)
            } else if tx.date >= baselineStart {
                baseline[cid, default: 0] += abs(tx.amount)
            }
        }

        var result: [Insight] = []
        for (cid, lastMonthSpent) in lastMonth {
            let baselineSpent = baseline[cid] ?? 0
            let baselineMonthly = baselineSpent / 3.0  // 3 mois baseline
            guard baselineMonthly > 50, lastMonthSpent > baselineMonthly * 1.25 else { continue }
            let increase = lastMonthSpent - baselineMonthly
            let increasePct = increase / baselineMonthly * 100
            let catName = allCategories.first(where: { $0.id == cid })?.name ?? "Catégorie"
            result.append(Insight(
                id: "drift_\(cid)",
                kind: .categoryDrift,
                title: "\(catName) : +\(Int(increasePct)) % vs vos 3 mois précédents",
                detail: "Ce mois-ci : \(lastMonthSpent.formatted(.currency(code: "EUR").presentation(.narrow))). Moyenne des 3 mois précédents : \(baselineMonthly.formatted(.currency(code: "EUR").presentation(.narrow))). Soit \(increase.formatted(.currency(code: "EUR").presentation(.narrow))) de plus. Pic ponctuel ou nouvelle tendance ?",
                annualImpact: increase * 12,  // Si la dérive persiste 1 an
                actionability: 2,  // Identifier la cause demande de l'analyse user
                confidence: min(1.0, baselineMonthly / 200.0)
            ))
        }
        return result
    }

    // MARK: - 5. Concentration top catégorie

    /// Calcule la part du top-1 dans les dépenses totales sur la période.
    /// Si > 30 %, on génère un insight informatif (pas vraiment actionable
    /// mais éclairant — souvent l'user sous-estime ce poste).
    private static func detectTopCategoryConcentration(
        txs: [FinanceTransaction],
        allCategories: [Category]
    ) -> [Insight] {
        let expenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }
        var byCat: [Int: Double] = [:]
        for tx in expenses {
            byCat[tx.categoryId!, default: 0] += abs(tx.amount)
        }
        let total = byCat.values.reduce(0, +)
        guard total > 0 else { return [] }
        let top = byCat.max { $0.value < $1.value }
        guard let (topCid, topAmount) = top else { return [] }
        let share = topAmount / total
        guard share > 0.30 else { return [] }
        let catName = allCategories.first(where: { $0.id == topCid })?.name ?? "Catégorie"
        return [Insight(
            id: "top_\(topCid)",
            kind: .topCategoryConcentration,
            title: "\(catName) = \(Int(share * 100)) % de vos dépenses",
            detail: "Sur les 6 derniers mois, vous avez dépensé \(topAmount.formatted(.currency(code: "EUR").presentation(.narrow))) en \(catName) — \(Int(share * 100)) % de votre total. C'est votre principal poste : un ajustement même modeste ici a un impact disproportionné.",
            annualImpact: 0,  // Informatif, pas d'action chiffrée
            actionability: 1,
            confidence: 0.8
        )]
    }

    // MARK: - Helpers

    private static func monthlyEquivalent(_ p: RecurringPattern) -> Double {
        let abs_amount = abs(p.amountAvg)
        switch p.frequency {
        case .daily:   return abs_amount * 30.42
        case .weekly:  return abs_amount * 4.33
        case .monthly: return abs_amount
        case .yearly:  return abs_amount / 12.0
        }
    }
}
