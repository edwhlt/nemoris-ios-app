import Foundation

// MARK: - EnvelopeSpendingCalculator
//
// **Moteur pur** du calcul "dépensé par enveloppe" — aucun accès base, cache ou
// réseau, donc testable sans Xcode (cf. `Tests/EnvelopeSpendingTests.swift`).
// Même doctrine que `Services/PortfolioEvolutionBuilder.swift` : un seul moteur
// partagé par tous les niveaux, qui ne peuvent donc plus diverger.
//
// **Pourquoi il existe** : avant cette factorisation, le calcul vivait en QUATRE
// exemplaires incompatibles, ce qui produisait des contradictions visibles à
// l'écran (une enveloppe "dépassée" dans l'AlertsBanner et "saine" dans le
// bandeau Budget, sur le même Dashboard) :
//
// | Implémentation                              | Sous-catégories | Enveloppes annuelles |
// |---------------------------------------------|-----------------|----------------------|
// | AnnualDashboardViewModel.computeBudgetRecap | incluses        | ignorées             |
// | BudgetViewModel.monthlySummary              | incluses        | amount / 12          |
// | AlertEngine.overspentEnvelopesAlerts        | catégorie seule | ignorées             |
// | WidgetDataStore.refreshBudget               | catégorie seule | amount / 12          |
//
// **Règles retenues** (celles de `BudgetViewModel`, la plus complète) :
//   1. `allocated` = `period == .yearly ? amount / 12 : amount` — une enveloppe
//      annuelle est mensualisée, sinon on compare un budget d'un an à un mois de
//      dépenses et rien n'est jamais "dépassé".
//   2. Le matching inclut la catégorie **et ses sous-catégories** — une enveloppe
//      "Alimentation" doit capter les dépenses de "Supermarché".
//   3. Seules les dépenses (`amount < 0`) comptent, en valeur absolue.

enum EnvelopeSpendingCalculator {

    /// Calcule la progression de chaque enveloppe sur la période couverte par
    /// `transactions`.
    ///
    /// - Parameters:
    ///   - envelopes: enveloppes à évaluer. **L'appelant filtre `isActive`** — le
    ///     moteur n'a pas à décider ce qui est pertinent pour l'écran appelant.
    ///   - transactions: transactions de la période, tous comptes confondus.
    ///   - categories: référentiel complet (sert à la hiérarchie parent/enfant et
    ///     aux libellés).
    ///   - previsions: prévisions de la période. Optionnel — sans elles,
    ///     `recurringSpent` et `forecasted` valent 0, ce qui suffit aux appelants
    ///     qui n'affichent que "dépensé vs alloué" (Dashboard, alertes, widget).
    ///   - patterns: motifs récurrents, nécessaires pour rattacher une prévision à
    ///     une catégorie. Optionnel, même raison.
    static func progresses(
        envelopes: [BudgetEnvelope],
        transactions: [FinanceTransaction],
        categories: [Category],
        previsions: [BudgetPrevision] = [],
        patterns: [RecurringPattern] = []
    ) -> [EnvelopeProgress] {
        guard !envelopes.isEmpty else { return [] }

        // --- Index construits UNE fois ---------------------------------------
        // La version d'origine refaisait un `filter` sur toutes les transactions
        // pour chaque enveloppe (O(enveloppes × transactions)) et un
        // `patterns.first(where:)` par prévision et par enveloppe.

        let childrenByParent: [Int: [Int]] = Dictionary(
            grouping: categories.compactMap { cat in cat.parentId.map { ($0, cat.id) } },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        let categoryById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var expensesByCategory: [Int: [FinanceTransaction]] = [:]
        for tx in transactions where tx.amount < 0 {
            guard let cid = tx.categoryId else { continue }
            expensesByCategory[cid, default: []].append(tx)
        }

        // Transactions déjà rattachées à un récurrent confirmé → part "fixe".
        let matchedTxIds = Set(
            previsions.filter { $0.status == .matched }.compactMap(\.actualTransactionId)
        )

        // patternId → categoryId, pour rattacher une prévision à une enveloppe.
        let categoryByPatternId = Dictionary(
            patterns.compactMap { p in p.categoryId.map { (p.id, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let activePrevisions = previsions.filter { $0.status != .skipped && $0.amount < 0 }

        // --- Calcul par enveloppe --------------------------------------------
        return envelopes.map { env in
            let ids = categoryIds(for: env.categoryId, childrenByParent: childrenByParent)

            let envTxs = ids.flatMap { expensesByCategory[$0] ?? [] }
            let spent = envTxs.reduce(0.0) { $0 + abs($1.amount) }
            let recurringSpent = envTxs
                .filter { matchedTxIds.contains($0.id) }
                .reduce(0.0) { $0 + abs($1.amount) }

            let idSet = Set(ids)
            let forecasted = activePrevisions
                .filter { prevision in
                    guard let patternId = prevision.recurringPatternId,
                          let patternCategory = categoryByPatternId[patternId] else { return false }
                    return idSet.contains(patternCategory)
                }
                .reduce(0.0) { $0 + abs($1.amount) }

            let category = env.categoryId.flatMap { categoryById[$0] }
            return EnvelopeProgress(
                envelope: env,
                categoryName: category?.name ?? env.name,
                categoryIcon: category?.displayIcon ?? "tag.fill",
                spent: spent,
                allocated: allocatedMonthly(for: env),
                recurringSpent: recurringSpent,
                forecasted: forecasted
            )
        }
    }

    /// Montant mensualisé d'une enveloppe. Une enveloppe annuelle vaut `amount / 12`
    /// sur un mois donné.
    static func allocatedMonthly(for envelope: BudgetEnvelope) -> Double {
        envelope.period == .yearly ? envelope.amount / 12 : envelope.amount
    }

    /// La catégorie de l'enveloppe + ses enfants directs. Vide si l'enveloppe n'est
    /// rattachée à aucune catégorie (elle affiche alors 0 dépensé, ce qui est exact).
    static func categoryIds(for categoryId: Int?, childrenByParent: [Int: [Int]]) -> [Int] {
        guard let id = categoryId else { return [] }
        return [id] + (childrenByParent[id] ?? [])
    }
}

// MARK: - BudgetRecap

/// État synthétique des enveloppes sur la période — pour le bandeau "Vue d'ensemble"
/// du Dashboard ("11 enveloppes · 7 ✓ · 4 ✗").
///
/// Dérivé de `[EnvelopeProgress]` : la classification vit dans `EnvelopeHealth`,
/// jamais recalculée ici.
struct BudgetRecap {
    let totalCount: Int
    let healthyCount: Int
    let warningCount: Int
    let exceededCount: Int

    var hasData: Bool { totalCount > 0 }
    var hasIssue: Bool { warningCount > 0 || exceededCount > 0 }

    static let empty = BudgetRecap(totalCount: 0, healthyCount: 0, warningCount: 0, exceededCount: 0)

    static func from(_ progresses: [EnvelopeProgress]) -> BudgetRecap {
        guard !progresses.isEmpty else { return .empty }
        var healthy = 0, warning = 0, exceeded = 0
        for progress in progresses {
            switch progress.healthState {
            case .healthy:  healthy  += 1
            case .warning:  warning  += 1
            case .exceeded: exceeded += 1
            }
        }
        return BudgetRecap(
            totalCount: progresses.count,
            healthyCount: healthy,
            warningCount: warning,
            exceededCount: exceeded
        )
    }
}
