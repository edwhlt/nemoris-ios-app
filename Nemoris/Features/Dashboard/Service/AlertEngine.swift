import Foundation

// MARK: - AlertEngine
//
// A smart-alerts engine — aggregates several data sources and
// produces a list of `Alert`s sorted by severity. Shown in `AlertsBanner`
// at the top of the Dashboard.
//
// **3 MVP alert types**:
//   1. **Overdue goals** — a goal with `deadline < now` and `ratio < 1.0`
//   2. **Overspent budget envelope** — Σ category expenses this month > the envelope amount
//   3. **Broken Patrimoine links** — assets whose source account was deleted
//
// **Why a minimal MVP**: starting with the most actionable alerts and
// where the data is already available. More advanced detections (an
// imminent overdraft, an unusual transaction via history stats) will be added
// in a 2nd pass once this flow's UX has been validated.
//
// **No persistence**: alerts are **recomputed on every Dashboard load**.
// No "I've already seen this alert" — deliberate for the MVP: an overdue
// goal stays overdue, the user sees it until they act.

enum AlertSeverity: Int, Comparable {
    case info     = 0
    case warning  = 1
    case critical = 2

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The associated color lives in `AlertsBanner.swift`, its only
    /// consumer: this engine depends on no SwiftUI type, which makes it
    /// compilable in a pure test harness.
    var systemIcon: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// Target tab for a tap on an alert (a light deep link).
enum AlertRoute {
    case patrimoine
    case budget
    case transactions
    case none
}

struct Alert: Identifiable, Hashable {
    let id: String          // a stable unique id (= kind + ref) for SwiftUI diffing
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

/// The engine's input context. All data is supplied by the caller —
/// the engine does NOT touch the database.
///
/// ⚠️ This is what avoids double loading: before, `AlertEngine` re-ran its
/// own `fetchTransactionsAllAccounts(limit: 5000)` for the current month even though
/// the Dashboard had just loaded exactly the same rows for its Budget banner.
struct AlertContext {
    /// Envelope progressions already computed by `EnvelopeSpendingCalculator`.
    let envelopeProgresses: [EnvelopeProgress]
    let goals: [Goal]
    let assets: [PatrimoineAsset]
    /// IDs of accounts that actually exist — used to detect broken links.
    let bankAccountIds: Set<Int>
    let investmentAccountIds: Set<Int>
}

enum AlertEngine {

    /// Computes the current list of alerts. **A pure engine**: everything comes from
    /// the context, so it's testable and free of hidden queries.
    static func compute(_ context: AlertContext) -> [Alert] {
        var alerts: [Alert] = []

        alerts.append(contentsOf: overdueGoalsAlerts(goals: context.goals))
        alerts.append(contentsOf: overspentEnvelopesAlerts(progresses: context.envelopeProgresses))
        alerts.append(contentsOf: brokenPatrimoineLinksAlerts(
            assets: context.assets,
            bankIds: context.bankAccountIds,
            invIds: context.investmentAccountIds
        ))

        // Sort order: critical > warning > info, then a stable insertion order
        return alerts.sorted { $0.severity > $1.severity }
    }

    // MARK: - 1. Goals en retard

    private static func overdueGoalsAlerts(goals: [Goal]) -> [Alert] {
        let now = Date()
        var result: [Alert] = []
        for goal in goals {
            guard let deadline = goal.deadlineDate, deadline < now else { continue }
            // The Patrimoine snapshot isn't available here (the VM normally
            // supplies it to the calculator). To avoid instantiating a
            // PatrimoineViewModel just for this, it's simplified: alerting on
            // goals whose deadline has passed. The goal's detail sheet will show
            // the exact ratio via PatrimoineViewModel when the user taps it.
            // Filtering out "reached" goals (custom only, computable
            // locally with no snapshot):
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

    // MARK: - 2. Overspent budget envelopes

    /// ⚠️ The behavior changed during the factoring: progressions
    /// now come from `EnvelopeSpendingCalculator`, so a hierarchical
    /// envelope captures its sub-categories' spending (before: the exact
    /// category only) and a yearly envelope is turned monthly (before: never
    /// exceeded because a one-year budget was compared to a month of spending).
    private static func overspentEnvelopesAlerts(progresses: [EnvelopeProgress]) -> [Alert] {
        progresses.compactMap { progress in
            // Only when genuinely over budget. The "approaching overspend"
            // threshold (`.warning`) could become an `.info` later; kept simple for now.
            guard progress.healthState == .exceeded else { return nil }
            let overshoot = progress.spent - progress.allocated
            // AlertEngine is pure (project doctrine), no access to the SwiftUI
            // environment — AppLocalization re-reads the language preference directly
            // from UserDefaults, see the equivalent comment in InsightEngine.
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

    /// A link is "broken" when the asset references an account/investment_account that
    /// no longer exists (a SET NULL cascade not propagated — an edge case, but possible).
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
