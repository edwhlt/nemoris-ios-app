import Foundation
import SwiftUI

// MARK: - AlertEngine
//
// Moteur d'alertes intelligentes — agrège plusieurs sources de données et
// produit une liste d'`Alert` triée par sévérité. Affiché dans le `AlertsBanner`
// en tête du Dashboard.
//
// **3 types d'alertes MVP** :
//   1. **Goals en retard** — goal avec `deadline < now` et `ratio < 1.0`
//   2. **Enveloppe budget dépassée** — Σ dépenses catégorie ce mois > montant envelope
//   3. **Liens Patrimoine rompus** — assets dont le compte source a été supprimé
//
// **Pourquoi MVP minimaliste** : on commence par les alertes les plus actionnables
// et où les data sont déjà disponibles. Les détections plus poussées (découvert
// imminent, transaction inhabituelle via stat sur historique) seront ajoutées
// dans une 2e passe une fois qu'on aura validé la UX de ce flux.
//
// **Pas de persistance** : les alertes sont **recalculées à chaque load Dashboard**.
// Pas de "j'ai déjà vu cette alerte" — c'est volontaire pour MVP : un goal en
// retard reste en retard, l'user le voit jusqu'à action.

enum AlertSeverity: Int, Comparable {
    case info     = 0
    case warning  = 1
    case critical = 2

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .info:     return AppTheme.Colors.accent
        case .warning:  return AppTheme.Colors.warning
        case .critical: return AppTheme.Colors.danger
        }
    }

    var systemIcon: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// Tab cible pour le tap sur une alerte (deep-link léger).
enum AlertRoute {
    case patrimoine
    case budget
    case transactions
    case none
}

struct Alert: Identifiable, Hashable {
    let id: String          // unique stable (= kind + ref) pour SwiftUI diff
    let severity: AlertSeverity
    let title: String
    let message: String
    let systemIcon: String  // surcharge possible de severity.systemIcon
    let route: AlertRoute
}

enum AlertEngine {

    /// Calcule la liste d'alertes courantes en interrogeant les repos. Devrait
    /// rester < 100 ms même avec une grosse base — on lit goals + envelopes +
    /// dernières transactions du mois + assets Patrimoine.
    static func compute() -> [Alert] {
        var alerts: [Alert] = []

        alerts.append(contentsOf: overdueGoalsAlerts())
        alerts.append(contentsOf: overspentEnvelopesAlerts())
        alerts.append(contentsOf: brokenPatrimoineLinksAlerts())

        // Tri : critical > warning > info, puis ordre d'insertion stable
        return alerts.sorted { $0.severity > $1.severity }
    }

    // MARK: - 1. Goals en retard

    private static func overdueGoalsAlerts() -> [Alert] {
        let goals = GoalRepository().fetchGoals()
        let now = Date()
        var result: [Alert] = []
        for goal in goals {
            guard let deadline = goal.deadlineDate, deadline < now else { continue }
            // On n'a pas le snapshot Patrimoine ici (le VM le fournit normalement
            // au calculator). Pour éviter d'instancier un PatrimoineViewModel
            // juste pour ça, on simplifie : on alerte sur les goals dont la
            // deadline est passée. La fiche détaillée du goal montrera le ratio
            // exact via le PatrimoineViewModel quand l'user clique.
            // Filtrage des goals "atteints" (custom seulement, calculable
            // localement sans snapshot) :
            if goal.kind == .custom && goal.customCurrentAmount >= goal.targetAmount {
                continue
            }
            let daysPast = Calendar.current.dateComponents([.day], from: deadline, to: now).day ?? 0
            result.append(Alert(
                id: "goal_overdue_\(goal.id)",
                severity: .warning,
                title: "Objectif en retard : \(goal.name)",
                message: "Échéance dépassée de \(daysPast) jour\(daysPast > 1 ? "s" : "")",
                systemIcon: "target",
                route: .patrimoine
            ))
        }
        return result
    }

    // MARK: - 2. Enveloppes budget dépassées

    private static func overspentEnvelopesAlerts() -> [Alert] {
        let envelopes = BudgetRepository.shared.fetchEnvelopes().filter { $0.isActive }
        guard !envelopes.isEmpty else { return [] }

        // Période = mois courant (1er du mois → maintenant). Cohérent avec
        // l'usage standard "budget mensuel".
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let monthStart = cal.date(from: comps) else { return [] }

        // On charge les transactions du mois en cours (tous comptes) pour sommer
        // les dépenses par catégorie. fetchMonthlyTotals donne juste la somme
        // globale ; on a besoin d'un breakdown par cat → on récupère les tx brutes.
        let txs = TransactionRepository().fetchTransactionsAllAccounts(
            from: monthStart, to: now, limit: 5000, offset: 0
        )

        // Σ par categoryId pour les dépenses uniquement (amount < 0)
        var spentByCategory: [Int: Double] = [:]
        for tx in txs where tx.amount < 0 {
            guard let cid = tx.categoryId else { continue }
            spentByCategory[cid, default: 0] += abs(tx.amount)
        }

        var result: [Alert] = []
        for env in envelopes {
            guard let cid = env.categoryId, let spent = spentByCategory[cid] else { continue }
            // Seulement quand vraiment dépassé. La seuil "approche dépassement"
            // (90%) pourrait être une `.info` plus tard ; pour MVP on reste simple.
            guard spent > env.amount else { continue }
            let overshoot = spent - env.amount
            result.append(Alert(
                id: "env_overspent_\(env.id)",
                severity: .critical,
                title: "Budget dépassé : \(env.name)",
                message: "Dépassement de \(overshoot.formatted(.currency(code: "EUR").presentation(.narrow))) ce mois",
                systemIcon: "chart.bar.fill",
                route: .budget
            ))
        }
        return result
    }

    // MARK: - 3. Liens Patrimoine rompus

    private static func brokenPatrimoineLinksAlerts() -> [Alert] {
        let assets = PatrimoineRepository().fetchAssets()
        guard !assets.isEmpty else { return [] }

        // Un lien est "rompu" quand l'asset référence un account/investment_account
        // qui n'existe plus (cascade SET NULL ne l'a pas effacé — cas edge mais
        // possible si le delete ne s'est pas propagé pour une raison).
        let bankIds = Set(TransactionRepository().fetchAccounts().map(\.id))
        let invIds = Set(InvestmentRepository().fetchAccounts().map(\.id))

        let broken = assets.filter { asset in
            if let id = asset.linkedAccountId, !bankIds.contains(id) { return true }
            if let id = asset.linkedInvestmentAccountId, !invIds.contains(id) { return true }
            return false
        }

        guard !broken.isEmpty else { return [] }
        return [Alert(
            id: "patrimoine_broken_links_\(broken.count)",
            severity: .info,
            title: broken.count == 1 ? "1 lien Patrimoine rompu" : "\(broken.count) liens Patrimoine rompus",
            message: "Le compte source d'un actif a été supprimé. Relinkez ou repassez en saisie manuelle.",
            systemIcon: "link.badge.plus",
            route: .patrimoine
        )]
    }
}
