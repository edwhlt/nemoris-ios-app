import Foundation

// MARK: - DashboardPeriod
//
// Fenêtre temporelle affichée par le Dashboard. Remplace les helpers de dates qui
// vivaient dans `AnnualDashboardViewModel`.
//
// ⚠️ Le mois est parsé À LA MAIN plutôt qu'avec le `dashboardMonthParser` global :
// un `DateFormatter` est une classe mutable partagée, donc pas `Sendable`, et cette
// structure traverse la frontière du `Task.detached` du builder.

struct DashboardPeriod: Hashable, Sendable {
    /// Exercice affiché.
    var year: Int
    /// Filtre mois au format "yyyy-MM". `nil` = année entière.
    var month: String?

    private var calendar: Calendar { Calendar.current }

    var yearFrom: Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
    }

    var yearTo: Date {
        calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? Date()
    }

    var previousYearFrom: Date? {
        calendar.date(from: DateComponents(year: year - 1, month: 1, day: 1))
    }

    var previousYearTo: Date? {
        calendar.date(from: DateComponents(year: year - 1, month: 12, day: 31))
    }

    /// Début de la fenêtre de détail (catégories / tags) : le mois filtré s'il y en
    /// a un, l'année entière sinon.
    var filterFrom: Date { monthStart ?? yearFrom }

    var filterTo: Date {
        guard let start = monthStart else { return yearTo }
        return calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
    }

    /// Libellé lisible du mois filtré ("juillet 2026"), `nil` si pas de filtre.
    ///
    /// Locale forcée en dur (fr_FR) : ce type est un struct pur sans accès à
    /// l'environnement SwiftUI (doctrine du projet), donc `.formatted()` retomberait
    /// sinon sur la locale RÉELLE de l'appareil au lieu du français — même
    /// précédent que `PatrimoineView.swift`.
    var monthLabel: String? {
        monthStart?.formatted(.dateTime.month(.wide).year().locale(AppLocalization.locale))
    }

    private var monthStart: Date? {
        guard let month else { return nil }
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: 1))
    }
}

// MARK: - DashboardSource
//
// Une donnée BRUTE lue en base. C'est le grain de la déduplication : chaque source
// est fetchée **exactement une fois** par passe, quel que soit le nombre d'agrégats
// qui la consomment.
//
// Avant ce découpage, les transactions du mois étaient chargées deux fois par
// `load()` (bandeau Budget + AlertEngine) et `fetchAccounts()` des investissements
// trois fois. La dédup n'était qu'une convention ; elle est désormais structurelle.

enum DashboardSource: String, Sendable, CaseIterable {
    case yearMonthlyTotals
    case previousYearMonthlyTotals
    case categoryTotals
    case tagTotals
    case activeEnvelopes
    case monthTransactions
    case categories
    case investmentAccounts
    case bankAccounts
    /// Soldes des comptes liés à un asset Patrimoine. Dérivée : dépend de
    /// `patrimoineAssets` + `bankAccounts`, donc fetchée après eux.
    case bankBalances
    case patrimoineAssets
    case patrimoineRealEstate
    case patrimoineLoans
    case goals
}

// MARK: - DashboardAggregate
//
// Une donnée PRÊTE À AFFICHER. C'est l'unité de demande : une carte déclare de quels
// agrégats elle a besoin, et le builder ne calcule que ceux-là — une carte masquée ne
// coûte donc aucune requête.

enum DashboardAggregate: String, Sendable, CaseIterable {
    /// Série mensuelle de l'année + totaux + comparaison N-1 (hero et graphe mensuel).
    case yearSeries
    case categoryBreakdown
    case tagBreakdown
    case budgetEnvelopes
    case investments
    case patrimoine
    case alerts
    case insights
    /// Dépenses Apple Pay en attente (automatisation Raccourcis, cf.
    /// `PendingApplePayRepository`). Requête directe et déjà bon marché (une
    /// poignée de lignes) : pas de `DashboardSource` dédiée, même traitement
    /// que `.insights` qui fait aussi son propre accès direct.
    case pendingApplePay

    /// Agrégats lourds, calculés dans une seconde passe à priorité basse pour que le
    /// reste de l'écran s'affiche sans les attendre.
    var isExpensive: Bool {
        self == .insights
    }

    /// Autres agrégats dont celui-ci a besoin (dépendance de niveau agrégat, pas source).
    var requires: Set<DashboardAggregate> {
        switch self {
        case .alerts: return [.budgetEnvelopes]   // les alertes lisent les EnvelopeProgress
        default:      return []
        }
    }

    var sources: Set<DashboardSource> {
        switch self {
        case .yearSeries:
            return [.yearMonthlyTotals, .previousYearMonthlyTotals]
        case .categoryBreakdown:
            return [.categoryTotals]
        case .tagBreakdown:
            return [.tagTotals]
        case .budgetEnvelopes:
            return [.activeEnvelopes, .monthTransactions, .categories]
        case .investments:
            return [.investmentAccounts]
        case .patrimoine:
            return [.patrimoineAssets, .patrimoineRealEstate, .patrimoineLoans,
                    .bankAccounts, .bankBalances, .investmentAccounts]
        case .alerts:
            return [.goals, .patrimoineAssets, .bankAccounts, .investmentAccounts]
        case .insights:
            return []   // l'InsightEngine fait son propre scan sur 180 jours
        case .pendingApplePay:
            return []   // requête directe sur pending_apple_pay_entries
        }
    }

    /// Ordre d'évaluation : les agrégats dont d'autres dépendent viennent d'abord.
    static let evaluationOrder: [DashboardAggregate] = [
        .yearSeries, .categoryBreakdown, .tagBreakdown,
        .investments, .patrimoine,
        .budgetEnvelopes,   // avant .alerts
        .alerts, .insights, .pendingApplePay
    ]

    /// Agrégats nécessaires aux éléments FIXES du Dashboard (hero, bandeau d'alertes,
    /// bandeau « Vue d'ensemble »). Toujours demandés, quelles que soient les cartes
    /// affichées.
    static let fixedElements: Set<DashboardAggregate> = [
        .yearSeries,        // hero : mois dominant + cumul annuel + variation N-1
        .alerts,            // AlertsBanner
        .investments,       // colonne « Investi » du bandeau
        .patrimoine,        // colonne « Patrimoine »
        .budgetEnvelopes,   // colonne « Enveloppes » (et dépendance des alertes)
        .pendingApplePay    // bandeau Apple Pay en attente
    ]

    /// Complète un ensemble demandé avec ses dépendances transitives.
    static func expanded(_ units: Set<DashboardAggregate>) -> Set<DashboardAggregate> {
        var result = units
        var changed = true
        while changed {
            changed = false
            for unit in result {
                let missing = unit.requires.subtracting(result)
                if !missing.isEmpty {
                    result.formUnion(missing)
                    changed = true
                }
            }
        }
        return result
    }
}

// MARK: - DashboardSnapshot
//
// Le résultat. **Un champ optionnel par agrégat** : `nil` signifie « pas demandé ou
// pas encore calculé », ce qui permet à chaque carte d'afficher son propre squelette
// au lieu du squelette tout-ou-rien de l'écran entier.

struct DashboardSnapshot: Sendable {
    var monthlySeries: [MonthlyTotals]?
    var stats: DashboardStats?
    var previousYearStats: DashboardStats?
    var categoryTotals: [CategoryTotal]?
    var tagTotals: [TagTotal]?
    /// Progressions d'enveloppes — consommées par le récap budget ET par les alertes.
    var envelopeProgresses: [EnvelopeProgress]?
    var budget: BudgetRecap?
    var investments: InvestmentsRecap?
    var patrimoine: PatrimoineSnapshot?
    var alerts: [Alert]?
    var insights: [Insight]?
    /// Nombre et total (positif, déjà `abs`) des dépenses Apple Pay encore
    /// `pending`. `nil` = pas encore calculé — distinct de `0` (aucune en attente).
    var pendingApplePayCount: Int?
    var pendingApplePayTotal: Double?

    /// Fusionne une passe partielle : seuls les champs renseignés écrasent les nôtres.
    /// C'est ce qui permet à la passe lourde (insights) d'arriver après coup sans
    /// effacer ce que la passe légère a déjà publié.
    func merging(_ other: DashboardSnapshot) -> DashboardSnapshot {
        var result = self
        if let v = other.monthlySeries      { result.monthlySeries = v }
        if let v = other.stats              { result.stats = v }
        if let v = other.previousYearStats  { result.previousYearStats = v }
        if let v = other.categoryTotals     { result.categoryTotals = v }
        if let v = other.tagTotals          { result.tagTotals = v }
        if let v = other.envelopeProgresses { result.envelopeProgresses = v }
        if let v = other.budget             { result.budget = v }
        if let v = other.investments        { result.investments = v }
        if let v = other.patrimoine         { result.patrimoine = v }
        if let v = other.alerts             { result.alerts = v }
        if let v = other.insights           { result.insights = v }
        if let v = other.pendingApplePayCount { result.pendingApplePayCount = v }
        if let v = other.pendingApplePayTotal { result.pendingApplePayTotal = v }
        return result
    }
}

// MARK: - DashboardCacheKey

/// Identifie une passe de calcul. Le `refreshToken` est `AppState.dataRefreshToken`,
/// déjà bumpé par l'app à chaque mutation de données — rien de nouveau à inventer.
///
/// ⚠️ Le Dashboard ne doit JAMAIS bumper ce token lui-même : précédent documenté de
/// boucle infinie dans `InvestmentsView` (cf. commentaire :429).
struct DashboardCacheKey: Hashable, Sendable {
    let refreshToken: UUID
    let period: DashboardPeriod

    /// Clé propre à un agrégat, restreinte à ce dont il dépend vraiment.
    func unitKey(for unit: DashboardAggregate) -> DashboardUnitKey {
        DashboardUnitKey(refreshToken: refreshToken, scope: unit.scope(for: period))
    }
}

/// Ce dont dépend réellement le résultat d'un agrégat.
///
/// Sans cette distinction, basculer le filtre mois du graphe recalculerait aussi le
/// budget, le patrimoine, les alertes et les insights — alors qu'aucun d'eux ne
/// regarde le mois affiché. L'ancien `toggleMonth` ne refetchait d'ailleurs que les
/// catégories et les tags ; ce découpage préserve ce comportement.
enum DashboardAggregateScope: Hashable, Sendable {
    /// Indépendant de la période affichée (mois en cours, "maintenant", etc.).
    case global
    case year(Int)
    case period(DashboardPeriod)
}

struct DashboardUnitKey: Hashable, Sendable {
    let refreshToken: UUID
    let scope: DashboardAggregateScope
}

extension DashboardAggregate {
    func scope(for period: DashboardPeriod) -> DashboardAggregateScope {
        switch self {
        case .categoryBreakdown, .tagBreakdown:
            return .period(period)
        case .yearSeries:
            return .year(period.year)
        case .budgetEnvelopes, .investments, .patrimoine, .alerts, .insights, .pendingApplePay:
            return .global
        }
    }
}
