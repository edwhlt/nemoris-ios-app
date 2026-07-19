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
}

struct AllAccountsData: Codable {
    let accounts: [AccountWidgetData]
    let updatedAt: Date

    var combined: AccountWidgetData {
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
