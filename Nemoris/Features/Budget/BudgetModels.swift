import Foundation

// MARK: - Enums

enum RecurrenceFrequency: String, CaseIterable, Identifiable {
    case daily   = "DAILY"
    case weekly  = "WEEKLY"
    case monthly = "MONTHLY"
    case yearly  = "YEARLY"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:   return "Quotidien"
        case .weekly:  return "Hebdomadaire"
        case .monthly: return "Mensuel"
        case .yearly:  return "Annuel"
        }
    }

    var systemImage: String {
        switch self {
        case .daily:   return "sun.min"
        case .weekly:  return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .yearly:  return "calendar.badge.checkmark"
        }
    }

    /// Nombre de jours approximatif entre deux occurrences
    var approximateDays: Int {
        switch self {
        case .daily:   return 1
        case .weekly:  return 7
        case .monthly: return 30
        case .yearly:  return 365
        }
    }
}

enum PrevisionStatus: String, CaseIterable {
    case pending = "PENDING"   // A venir, non confirme
    case matched = "MATCHED"   // Associe a une transaction reelle
    case skipped = "SKIPPED"   // Ignore manuellement

    var label: String {
        switch self {
        case .pending: return "Attendu"
        case .matched: return "Confirme"
        case .skipped: return "Ignore"
        }
    }
}

enum BudgetPeriod: String, CaseIterable {
    case monthly = "MONTHLY"
    case yearly  = "YEARLY"

    var label: String {
        switch self {
        case .monthly: return "Mensuel"
        case .yearly:  return "Annuel"
        }
    }
}

// MARK: - Core Models

/// Motif recurrent detecte ou saisi manuellement (abonnement, loyer, salaire, etc.)
struct RecurringPattern: Identifiable, Hashable {
    let id: Int
    var name: String
    /// Montant moyen observe (negatif = depense, positif = revenu)
    var amountAvg: Double
    /// Tolerance de variation en % (0.15 = +/-15 %)
    var amountTolerance: Double
    var categoryId: Int?
    var payeeId: Int?
    var frequency: RecurrenceFrequency
    /// Jour d'ancrage : jour du mois (1-31) pour MONTHLY, ou ISO weekday (1=lundi) pour WEEKLY
    var anchorDay: Int?
    var isActive: Bool
    /// true si cree manuellement par l'utilisateur
    var isManual: Bool
    var createdAt: Date
    var lastDetectedAt: Date?
    /// Date a partir de laquelle les previsions sont generees (debut du contrat, de l'abonnement, etc.)
    var startDate: Date
    /// Date de fin optionnelle. nil = sans fin.
    var endDate: Date?

    var isExpense: Bool { amountAvg < 0 }
    var displayAmount: Double { abs(amountAvg) }
}

/// Enveloppe budgetaire : plafond de depenses alloue a une categorie sur une periode
struct BudgetEnvelope: Identifiable, Hashable {
    let id: Int
    var name: String
    var categoryId: Int?
    var amount: Double
    var period: BudgetPeriod
    var startDate: Date
    var isActive: Bool
}

/// Echeance previsionnelle d'un motif recurrent
struct BudgetPrevision: Identifiable, Hashable {
    let id: Int
    var recurringPatternId: Int?
    var amount: Double
    var expectedDate: Date
    var status: PrevisionStatus
    var actualTransactionId: Int?
    var notes: String?

    var isExpense: Bool { amount < 0 }
    var displayAmount: Double { abs(amount) }
}

// MARK: - Aggregates

/// Prevision enrichie avec les infos du pattern parent, pour l'affichage
struct EnrichedPrevision: Identifiable {
    let prevision: BudgetPrevision
    let patternName: String
    let categoryName: String?
    let frequency: RecurrenceFrequency

    var id: Int { prevision.id }
    var amount: Double { prevision.amount }
    var expectedDate: Date { prevision.expectedDate }
    var status: PrevisionStatus { prevision.status }
    var isExpense: Bool { amount < 0 }
    var displayAmount: Double { abs(amount) }
}

/// État de santé d'une enveloppe sur la période. Les seuils vivent ICI et nulle
/// part ailleurs — avant, chaque écran refaisait sa propre comparaison de ratio.
enum EnvelopeHealth {
    case healthy   // < 80 % du budget consommé
    case warning   // 80 % … 100 %
    case exceeded  // > 100 %
}

/// Resume d'une enveloppe budgetaire pour un mois donne
struct EnvelopeProgress: Identifiable {
    let envelope: BudgetEnvelope
    let categoryName: String
    let categoryIcon: String
    let spent: Double          // Total réel dépensé (positif)
    let allocated: Double      // Budget alloué (positif)
    let recurringSpent: Double // Portion issue de récurrents confirmés (positif)
    let forecasted: Double     // Total prévu (prévisions actives du mois pour cette catégorie)

    var id: Int { envelope.id }
    var variableSpent: Double { max(spent - recurringSpent, 0) }
    var remaining: Double { allocated - spent }
    /// ⚠️ Clampé à 1.0 — c'est une **largeur de barre de progression**, pas une mesure.
    /// Pour classer/comparer, utiliser `rawRatio` ou `healthState`.
    var ratio: Double { allocated > 0 ? min(spent / allocated, 1.0) : 0 }
    /// Ratio réel, non clampé. Sans lui, un dépassement est indétectable via `ratio`.
    var rawRatio: Double { allocated > 0 ? spent / allocated : 0 }
    var recurringRatio: Double { allocated > 0 ? min(recurringSpent / allocated, 1.0) : 0 }
    var forecastedRatio: Double { allocated > 0 ? min(forecasted / allocated, 1.0) : 0 }
    var isOverBudget: Bool { spent > allocated }
    var forecastExceedsBudget: Bool { forecasted > allocated }

    var healthState: EnvelopeHealth {
        if isOverBudget { return .exceeded }
        if rawRatio >= 0.8 { return .warning }
        return .healthy
    }
}

/// Resume budgetaire mensuel (pour le dashboard)
struct MonthlyBudgetSummary {
    let month: String               // "2025-01"
    let forecastedExpenses: Double  // Somme des previsions de depenses du mois
    let actualExpenses: Double      // Depenses reelles du mois
    let matchedCount: Int
    let pendingCount: Int
    let envelopes: [EnvelopeProgress]
    let totalIncome: Double        // Revenus reels du mois (positif)
    let fixedActual: Double        // Charges confirmees (recurrents matches, positif)

    var variableActual: Double { max(actualExpenses - fixedActual, 0) }
    var netSavings: Double { totalIncome - actualExpenses }
    var variance: Double { actualExpenses - forecastedExpenses }  // positif = depassement
    var isOverBudget: Bool { variance > 0 }
}

/// Journee dans le calendrier financier
struct CalendarDay: Identifiable {
    let date: Date
    let previsions: [EnrichedPrevision]
    let transactions: [FinanceTransaction]

    var id: String { DateFormatter.isoDate.string(from: date) }

    var forecastedAmount: Double {
        previsions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
    }
    var actualAmount: Double {
        transactions.reduce(0) { $0 + $1.amount }
    }
    var hasEvents: Bool { !previsions.isEmpty || !transactions.isEmpty }
}

// MARK: - Helpers

private extension DateFormatter {
    static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
