import Foundation

struct Account: Identifiable, Hashable {
    let id: Int
    var name: String
}

struct Category: Identifiable, Hashable {
    let id: Int
    var name: String
}

struct Tiers: Identifiable, Hashable {
    let id: Int
    var name: String
    var regex: String?
}

struct PaymentType: Identifiable, Hashable {
    let id: Int
    var name: String
    var regex: String?
}

struct FinanceTransaction: Identifiable, Hashable {
    let id: Int
    let accountId: Int
    let tiersId: Int?
    let categoryId: Int?
    let paymentTypeId: Int?
    let tiersName: String
    let categoryName: String
    let paymentTypeName: String
    let information: String
    let amount: Double
    let date: Date
}

struct TransactionEditDraft: Identifiable {
    var id: Int
    var tiersId: Int?
    var categoryId: Int?
    var paymentTypeId: Int?
    var information: String
    var amount: Double
    var date: Date

    init(from tx: FinanceTransaction) {
        id = tx.id
        tiersId = tx.tiersId
        categoryId = tx.categoryId
        paymentTypeId = tx.paymentTypeId
        information = tx.information
        amount = tx.amount
        date = tx.date
    }
}

struct MonthlyTotals {
    let month: String   // "2025-01"
    let income: Double
    let expense: Double
}

struct CategoryTotal {
    let category: String
    let total: Double
}

struct SQLQueryResult {
    let columns: [String]
    let rows: [[String]]
}

struct SQLError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PendingTransaction: Identifiable {
    let id = UUID()
    let accountId: Int
    var tiersId: Int?
    var mdpId: Int?
    let information: String
    let amount: Double
    let date: Date
    var tiersName: String
    var mdpName: String
}

// MARK: - Tricount Models

struct TricountGroup: Identifiable {
    let id: Int
    let tricountKey: String
    let title: String
    let currency: String
    let myName: String
    let fetchedAt: Date
    let entryCount: Int
}

struct TricountEntry: Identifiable {
    let id: Int
    let groupId: Int
    let typeTransaction: String
    let whoPaid: String
    let total: Double
    let currency: String
    let description: String
    let date: Date
    let category: String
    let userCategoryId: Int?
    let userCategoryName: String
}

struct TricountShare: Identifiable {
    let id: Int
    let entryId: Int
    let memberName: String
    let amount: Double
}

struct TricountMemberBalance: Identifiable {
    let memberName: String
    let iOwe: Double    // I owe this person
    let theyOwe: Double // They owe me
    var net: Double { theyOwe - iOwe } // positive = they owe me
    var id: String { memberName }
}
