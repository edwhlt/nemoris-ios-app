import Foundation

// MARK: - EnvelopeSuggestionService
//
// Suggère des enveloppes budgétaires à partir de l'historique de l'user.
// L'algo : on regarde les 90 derniers jours, on groupe les dépenses par
// catégorie, on calcule la moyenne mensuelle et on propose un budget de
// `moyenne × 1.10` (arrondi à la dizaine) — léger overhead pour ne pas
// rendre l'user "en dépassement" dès le 1er mois.
//
// **Filtre catégorie déjà couverte** : si une enveloppe existe déjà pour
// cette catégorie, on ne la propose pas (évite les doublons). On peut
// l'écraser via le form classique si l'user veut ajuster.
//
// **Critères de pertinence** :
//   - Minimum 3 transactions dans les 90 derniers jours (signal solide)
//   - Minimum 30 € de dépenses cumulées (catégories marginales filtrées)
//   - Catégorie non `nil` (uncategorized ignoré)

struct EnvelopeSuggestion: Identifiable, Hashable {
    var id: Int { categoryId }
    let categoryId: Int
    let categoryName: String
    let categoryIcon: String
    /// Moyenne mensuelle observée (en € positifs).
    let averageMonthly: Double
    /// Montant suggéré pour l'enveloppe (moyenne arrondie à la dizaine + 10 % d'overhead).
    let suggestedBudget: Double
    /// Nombre de transactions sur la période d'analyse — utile pour afficher
    /// la robustesse statistique de la suggestion ("18 achats sur 3 mois").
    let transactionCount: Int
}

enum EnvelopeSuggestionService {

    /// Période d'analyse — 90 jours = 3 mois glissants. Long enough pour
    /// lisser les variations saisonnières d'un mois unique mais court pour
    /// rester réactif aux changements de mode de vie récents.
    private static let analysisDays = 90

    /// Seuils de pertinence — sous ces valeurs, la catégorie est trop
    /// marginale pour mériter une enveloppe.
    private static let minTransactions = 3
    private static let minTotalSpent: Double = 30

    /// Calcule les suggestions à partir de l'historique courant. Les catégories
    /// déjà couvertes par une enveloppe existante sont exclues du résultat.
    static func computeSuggestions(
        existingEnvelopes: [BudgetEnvelope],
        allCategories: [Category]
    ) -> [EnvelopeSuggestion] {
        let txRepo = TransactionRepository()
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        guard let from = cal.date(byAdding: .day, value: -analysisDays, to: now) else { return [] }

        // Fetch les tx sur la période — toutes catégories, dépenses uniquement
        // (amount < 0). Cap à 5000 pour les gros historiques (peu probable de
        // dépasser sur 90j).
        let txs = txRepo.fetchTransactionsAllAccounts(from: from, to: now, limit: 5000, offset: 0)
        let expenses = txs.filter { $0.amount < 0 && $0.categoryId != nil }

        // Catégories déjà couvertes (set pour exclusion O(1))
        let coveredCategoryIds = Set(existingEnvelopes.compactMap { $0.categoryId })

        // Groupement par categoryId
        var byCategoryId: [Int: (count: Int, total: Double)] = [:]
        for tx in expenses {
            guard let cid = tx.categoryId, !coveredCategoryIds.contains(cid) else { continue }
            let current = byCategoryId[cid] ?? (count: 0, total: 0)
            byCategoryId[cid] = (count: current.count + 1, total: current.total + abs(tx.amount))
        }

        // Convertit en suggestions et applique les seuils
        let categoryById = Dictionary(uniqueKeysWithValues: allCategories.map { ($0.id, $0) })
        let monthlyFactor = 30.0 / Double(analysisDays)  // 90j → mensuel
        var suggestions: [EnvelopeSuggestion] = []
        for (cid, stats) in byCategoryId {
            guard stats.count >= minTransactions, stats.total >= minTotalSpent else { continue }
            guard let cat = categoryById[cid] else { continue }
            let avgMonthly = stats.total * monthlyFactor
            // Arrondi à la dizaine supérieure + 10 % d'overhead — donne une cible
            // réaliste mais pas serrée au point que l'user soit en dépassement
            // dès le 1er mois.
            let budgetRaw = avgMonthly * 1.10
            let budgetRounded = ceil(budgetRaw / 10.0) * 10.0

            suggestions.append(EnvelopeSuggestion(
                categoryId: cid,
                categoryName: cat.name,
                categoryIcon: cat.displayIcon,
                averageMonthly: avgMonthly,
                suggestedBudget: budgetRounded,
                transactionCount: stats.count
            ))
        }

        // Tri par montant suggéré décroissant (les plus impactantes d'abord)
        return suggestions.sorted { $0.suggestedBudget > $1.suggestedBudget }
    }
}
