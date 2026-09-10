import Foundation

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
// retard reste en retard, l'utilisateur le voit jusqu'à action.

enum AlertSeverity: Int, Comparable {
    case info     = 0
    case warning  = 1
    case critical = 2

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// La couleur associée vit dans `AlertsBanner.swift`, son unique
    /// consommateur : ce moteur ne dépend d'aucun type SwiftUI, ce qui le rend
    /// compilable dans un harnais de tests pur.
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
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemIcon: String  // surcharge possible de severity.systemIcon
    let route: AlertRoute
    
    static func == (lhs: Alert, rhs: Alert) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Contexte d'entrée du moteur. Toutes les données sont fournies par l'appelant —
/// le moteur ne touche PAS la base.
///
/// ⚠️ C'est ce qui évite le double chargement : avant, `AlertEngine` refaisait son
/// propre `fetchTransactionsAllAccounts(limit: 5000)` sur le mois en cours alors que
/// le Dashboard venait de charger exactement les mêmes lignes pour son bandeau Budget.
struct AlertContext {
    /// Progressions d'enveloppes déjà calculées par `EnvelopeSpendingCalculator`.
    let envelopeProgresses: [EnvelopeProgress]
    let goals: [Goal]
    let assets: [PatrimoineAsset]
    /// Ids des comptes qui existent réellement — sert à détecter les liens rompus.
    let bankAccountIds: Set<Int>
    let investmentAccountIds: Set<Int>
}

enum AlertEngine {

    /// Calcule la liste d'alertes courantes. **Moteur pur** : tout vient du contexte,
    /// donc testable et sans requête cachée.
    static func compute(_ context: AlertContext) -> [Alert] {
        var alerts: [Alert] = []

        alerts.append(contentsOf: overdueGoalsAlerts(goals: context.goals))
        alerts.append(contentsOf: overspentEnvelopesAlerts(progresses: context.envelopeProgresses))
        alerts.append(contentsOf: brokenPatrimoineLinksAlerts(
            assets: context.assets,
            bankIds: context.bankAccountIds,
            invIds: context.investmentAccountIds
        ))

        // Tri : critical > warning > info, puis ordre d'insertion stable
        return alerts.sorted { $0.severity > $1.severity }
    }

    // MARK: - 1. Goals en retard

    private static func overdueGoalsAlerts(goals: [Goal]) -> [Alert] {
        let now = Date()
        var result: [Alert] = []
        for goal in goals {
            guard let deadline = goal.deadlineDate, deadline < now else { continue }
            // On n'a pas le snapshot Patrimoine ici (le VM le fournit normalement
            // au calculator). Pour éviter d'instancier un PatrimoineViewModel
            // juste pour ça, on simplifie : on alerte sur les goals dont la
            // deadline est passée. La fiche détaillée du goal montrera le ratio
            // exact via le PatrimoineViewModel quand l'utilisateur clique.
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

    /// ⚠️ Le comportement a changé lors de la factorisation : les progressions
    /// viennent désormais d'`EnvelopeSpendingCalculator`, donc une enveloppe
    /// hiérarchique capte les dépenses de ses sous-catégories (avant : catégorie
    /// exacte seulement) et une enveloppe annuelle est mensualisée (avant : jamais
    /// dépassée car on comparait un budget d'un an à un mois de dépenses).
    private static func overspentEnvelopesAlerts(progresses: [EnvelopeProgress]) -> [Alert] {
        progresses.compactMap { progress in
            // Seulement quand vraiment dépassé. Le seuil "approche dépassement"
            // (`.warning`) pourrait devenir une `.info` plus tard ; on reste simple.
            guard progress.healthState == .exceeded else { return nil }
            let overshoot = progress.spent - progress.allocated
            // AlertEngine est pur (doctrine du projet), pas d'accès à l'environnement
            // SwiftUI — AppLocalization relit la préférence de langue directement
            // depuis UserDefaults, cf. commentaire équivalent dans InsightEngine.
            let overshootStr = overshoot.formatted(.currency(code: "EUR").presentation(.narrow).locale(AppLocalization.locale))
            return Alert(
                id: "env_overspent_\(progress.envelope.id)",
                severity: .critical,
                title: "Budget dépassé : \(progress.envelope.name)",
                message: "Dépassement de \(overshootStr) ce mois",
                systemIcon: "chart.bar.fill",
                route: .budget
            )
        }
    }

    // MARK: - 3. Liens Patrimoine rompus

    /// Un lien est "rompu" quand l'asset référence un account/investment_account qui
    /// n'existe plus (cascade SET NULL non propagée — cas edge mais possible).
    private static func brokenPatrimoineLinksAlerts(
        assets: [PatrimoineAsset],
        bankIds: Set<Int>,
        invIds: Set<Int>
    ) -> [Alert] {
        guard !assets.isEmpty else { return [] }

        let broken = assets.filter { asset in
            if let id = asset.linkedAccountId, !bankIds.contains(id) { return true }
            if let id = asset.linkedInvestmentAccountId, !invIds.contains(id) { return true }
            return false
        }

        guard !broken.isEmpty else { return [] }
        let title = broken.count == 1
            ? LocalizedStringResource("1 lien Patrimoine rompu")
            : LocalizedStringResource("\(broken.count) liens Patrimoine rompus")
        return [Alert(
            id: "patrimoine_broken_links_\(broken.count)",
            severity: .info,
            title: title,
            message: "Le compte source d'un actif a été supprimé. Relinkez ou repassez en saisie manuelle.",
            systemIcon: "link.badge.plus",
            route: .patrimoine
        )]
    }
}
