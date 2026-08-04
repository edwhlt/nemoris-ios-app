import SwiftUI
import Charts
import TipKit

struct ApercuPresentation: Identifiable {
    let id = UUID()
    let summary: MonthlyBudgetSummary?
    let days: [CalendarDay]
    let month: Date
}
