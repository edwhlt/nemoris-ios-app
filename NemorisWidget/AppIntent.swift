//
//  AppIntent.swift
//  NemorisWidget
//
//  Created by Edwin Helet on 20/05/2026.
//

import WidgetKit
import AppIntents
import Foundation

// MARK: - Shared decodable models (mirrors of WidgetDataStore types)

struct MonthData: Codable {
    let month: String
    let expense: Double
    let income: Double

    var shortMonth: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        let symbols = ["Jan","Fév","Mar","Avr","Mai","Jun","Jul","Aoû","Sep","Oct","Nov","Déc"]
        return m >= 1 && m <= 12 ? symbols[m - 1] : month
    }
}

struct AccountWidgetData: Codable {
    let id: Int
    let name: String
    let type: String
    let monthExpense: Double
    let monthIncome: Double
    let netBalance: Double
    let monthlyHistory: [MonthData]
    var excludedFromAggregates: Bool = false

    init(id: Int, name: String, type: String, monthExpense: Double, monthIncome: Double,
         netBalance: Double, monthlyHistory: [MonthData], excludedFromAggregates: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.monthExpense = monthExpense
        self.monthIncome = monthIncome
        self.netBalance = netBalance
        self.monthlyHistory = monthlyHistory
        self.excludedFromAggregates = excludedFromAggregates
    }

    // Mirror du décodage manuel côté app (`Core/Cache/WidgetDataStore.swift`) :
    // `decodeIfPresent` pour ne pas faire échouer la lecture d'un cache App
    // Group écrit par une version de l'app antérieure à v51.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        monthExpense = try c.decode(Double.self, forKey: .monthExpense)
        monthIncome = try c.decode(Double.self, forKey: .monthIncome)
        netBalance = try c.decode(Double.self, forKey: .netBalance)
        monthlyHistory = try c.decode([MonthData].self, forKey: .monthlyHistory)
        excludedFromAggregates = try c.decodeIfPresent(Bool.self, forKey: .excludedFromAggregates) ?? false
    }
}

struct AllAccountsData: Codable {
    let accounts: [AccountWidgetData]
    let updatedAt: Date

    var combined: AccountWidgetData {
        // Un compte "autre" garde son entrée individuelle mais n'entre pas dans
        // "Tous les comptes" — même règle que `WidgetDataStore.AllAccountsData`.
        let accounts = self.accounts.filter { !$0.excludedFromAggregates }
        let totalExpense = accounts.reduce(0) { $0 + $1.monthExpense }
        let totalIncome  = accounts.reduce(0) { $0 + $1.monthIncome }
        let allMonths = Dictionary(grouping: accounts.flatMap(\.monthlyHistory), by: \.month)
        let history = allMonths.map { month, entries in
            MonthData(
                month: month,
                expense: entries.reduce(0) { $0 + $1.expense },
                income:  entries.reduce(0) { $0 + $1.income }
            )
        }.sorted { $0.month < $1.month }
        return AccountWidgetData(
            id: -1, name: "Tous les comptes", type: "ALL",
            monthExpense: totalExpense, monthIncome: totalIncome,
            netBalance: totalIncome - totalExpense,
            monthlyHistory: history
        )
    }

    static let placeholder = AllAccountsData(
        accounts: [
            AccountWidgetData(
                id: 1, name: "Compte courant", type: "COURANT",
                monthExpense: 1_234.56, monthIncome: 2_500.00, netBalance: 1_265.44,
                monthlyHistory: [
                    MonthData(month: "2025-12", expense: 1100, income: 2200),
                    MonthData(month: "2026-01", expense:  980, income: 2100),
                    MonthData(month: "2026-02", expense: 1340, income: 2400),
                    MonthData(month: "2026-03", expense:  890, income: 2050),
                    MonthData(month: "2026-04", expense: 1567, income: 2600),
                    MonthData(month: "2026-05", expense: 1234, income: 2500),
                ]
            )
        ],
        updatedAt: Date()
    )
}

// MARK: - AppEntity

struct AccountEntity: AppEntity {
    let id: Int
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Compte" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = AccountEntityQuery()
}

// MARK: - EntityQuery

struct AccountEntityQuery: EntityStringQuery {
    private static let appGroupID  = "group.fr.hedwin.nemoris"
    private static let allAccountsKey = "nemoris.allAccountsData"

    func entities(for identifiers: [Int]) async throws -> [AccountEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AccountEntity] {
        allEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        allEntities()
    }

    private func allEntities() -> [AccountEntity] {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.allAccountsKey),
              let all = try? JSONDecoder().decode(AllAccountsData.self, from: data) else {
            return []
        }
        return all.accounts.map { AccountEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Intent

struct WidgetAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Compte" }
    static var description: IntentDescription { "Choisissez un compte ou affichez tous les comptes." }

    @Parameter(title: "Compte", optionsProvider: AccountOptionsProvider())
    var account: AccountEntity?
}

private struct AccountOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [AccountEntity] {
        try await AccountEntityQuery().suggestedEntities()
    }
}

// MARK: - Budget widget models

struct BudgetWidgetData: Codable {
    let forecastedExpenses: Double
    let actualExpenses: Double
    let variance: Double
    let envelopes: [EnvelopeWidgetItem]
    let updatedAt: Date

    var ratio: Double { forecastedExpenses > 0 ? min(actualExpenses / forecastedExpenses, 1.5) : 0 }
    var isOverBudget: Bool { variance > 0 }

    static let placeholder = BudgetWidgetData(
        forecastedExpenses: 2_000, actualExpenses: 1_234, variance: -766,
        envelopes: [
            EnvelopeWidgetItem(name: "Alimentation", spent: 450, allocated: 600),
            EnvelopeWidgetItem(name: "Loisirs", spent: 220, allocated: 200),
            EnvelopeWidgetItem(name: "Transport", spent: 90, allocated: 150),
        ],
        updatedAt: Date()
    )
}

struct EnvelopeWidgetItem: Codable {
    let name: String
    let spent: Double
    let allocated: Double
    var ratio: Double { allocated > 0 ? min(spent / allocated, 1.0) : 0 }
    var isOver: Bool { spent > allocated }
}

// MARK: - Budget intent

struct BudgetWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Budget" }
    static var description: IntentDescription { "Configurez le widget budget mensuel." }
}

// MARK: - Investments widget models & intent

/// Variation (abs + %) du portefeuille sur une plage donnée. Mirror de
/// `InvestmentRangeSnapshot` (app principale, `WidgetDataStore.swift`).
struct InvestmentRangeSnapshot: Codable {
    let pnlAbsolute: Double
    let pnlPercent: Double
}

struct InvestmentsWidgetData: Codable {
    let totalValue: Double
    let pnlAbsolute: Double
    let pnlPercent: Double
    let accountCount: Int
    let updatedAt: Date
    var rangePnl: [String: InvestmentRangeSnapshot] = [:]

    var hasData: Bool { accountCount > 0 }

    /// Variation à afficher pour la plage choisie dans "Modifier le widget".
    /// Repli sur la plus-value latente TOTALE (depuis l'achat) quand la plage
    /// n'a pas d'historique de prix exploitable (ex. positions sans sync).
    func pnl(for range: InvestmentsWidgetRange) -> (abs: Double, percent: Double, isRangeSpecific: Bool) {
        if let snapshot = rangePnl[range.rawValue] {
            return (snapshot.pnlAbsolute, snapshot.pnlPercent, true)
        }
        return (pnlAbsolute, pnlPercent, false)
    }

    static let placeholder = InvestmentsWidgetData(
        totalValue: 18_450, pnlAbsolute: 1_230, pnlPercent: 7.1, accountCount: 2, updatedAt: Date(),
        rangePnl: [
            InvestmentsWidgetRange.day.rawValue:   InvestmentRangeSnapshot(pnlAbsolute: 42, pnlPercent: 0.2),
            InvestmentsWidgetRange.week.rawValue:  InvestmentRangeSnapshot(pnlAbsolute: 210, pnlPercent: 1.1),
            InvestmentsWidgetRange.month.rawValue: InvestmentRangeSnapshot(pnlAbsolute: 640, pnlPercent: 3.6),
        ]
    )
}

/// Intervalle de variation choisi par l'utilisateur via "Modifier le widget"
/// (long-press → Modifier). `rawValue` doit rester synchronisé avec les clés
/// `InvestmentWidgetRangeKey` de l'app principale ("1J"/"1S"/"1M").
enum InvestmentsWidgetRange: String, AppEnum {
    case day   = "1J"
    case week  = "1S"
    case month = "1M"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Intervalle" }
    static var caseDisplayRepresentations: [InvestmentsWidgetRange: DisplayRepresentation] = [
        .day:   "1 jour",
        .week:  "1 semaine",
        .month: "1 mois",
    ]
}

struct InvestmentsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Investissements" }
    static var description: IntentDescription { "Valeur totale de votre portefeuille." }

    @Parameter(title: "Intervalle", default: .day)
    var range: InvestmentsWidgetRange
}

// MARK: - Patrimoine widget models & intent

struct PatrimoineWidgetData: Codable {
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let itemsCount: Int
    let updatedAt: Date

    var hasData: Bool { itemsCount > 0 }

    static let placeholder = PatrimoineWidgetData(netWorth: 182_400, totalAssets: 214_000, totalLiabilities: 31_600, itemsCount: 5, updatedAt: Date())
}

struct PatrimoineWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Patrimoine" }
    static var description: IntentDescription { "Patrimoine net (actifs moins dettes)." }
}

// MARK: - Tricount widget models & intent

struct TricountGroupWidgetItem: Codable {
    let id: Int
    let title: String
    let currency: String
    /// Positif = le groupe me doit ; négatif = je dois au groupe.
    let netBalance: Double
}

struct TricountWidgetData: Codable {
    let groups: [TricountGroupWidgetItem]
    let updatedAt: Date

    static let placeholder = TricountWidgetData(
        groups: [
            TricountGroupWidgetItem(id: 1, title: "Colocation", currency: "EUR", netBalance: 42.50),
            TricountGroupWidgetItem(id: 2, title: "Vacances Portugal", currency: "EUR", netBalance: -18.20),
        ],
        updatedAt: Date()
    )
}

struct TricountGroupEntity: AppEntity {
    let id: Int
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Groupe Tricount" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = TricountGroupEntityQuery()
}

struct TricountGroupEntityQuery: EntityStringQuery {
    private static let appGroupID  = "group.fr.hedwin.nemoris"
    private static let tricountKey = "nemoris.tricountWidgetData"

    func entities(for identifiers: [Int]) async throws -> [TricountGroupEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TricountGroupEntity] {
        allEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [TricountGroupEntity] {
        allEntities()
    }

    private func allEntities() -> [TricountGroupEntity] {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.tricountKey),
              let all = try? JSONDecoder().decode(TricountWidgetData.self, from: data) else {
            return []
        }
        return all.groups.map { TricountGroupEntity(id: $0.id, name: $0.title) }
    }
}

struct WidgetTricountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Tricount" }
    static var description: IntentDescription { "Choisissez un groupe ou affichez le plus significatif." }

    @Parameter(title: "Groupe", optionsProvider: TricountGroupOptionsProvider())
    var group: TricountGroupEntity?
}

private struct TricountGroupOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [TricountGroupEntity] {
        try await TricountGroupEntityQuery().suggestedEntities()
    }
}
