import SwiftUI
import Charts

// MARK: - Chart data helpers

private struct MonthBarPoint: Identifiable {
    let id = UUID()
    let date: Date
    let type: String   // "Recettes" | "Dépenses"
    let value: Double
}

private let monthParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    return f
}()

// MARK: - DashboardView

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    private let repository = TransactionRepository()

    @State private var totalRecent: Double = 0
    @State private var recentCount: Int = 0
    @State private var accounts: [Account] = []
    @State private var monthlyData: [MonthlyTotals] = []
    @State private var categoryData: [CategoryTotal] = []
    @State private var showSettings = false

    // MARK: Computed

    private var monthlyChartData: [MonthBarPoint] {
        monthlyData.flatMap { item -> [MonthBarPoint] in
            guard let date = monthParser.date(from: item.month) else { return [] }
            return [
                MonthBarPoint(date: date, type: "Recettes", value: item.income),
                MonthBarPoint(date: date, type: "Dépenses", value: abs(item.expense))
            ]
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryCard
                    if !monthlyData.isEmpty  { monthlyChartSection }
                    if !categoryData.isEmpty { categoryChartSection }
                    if monthlyData.isEmpty && categoryData.isEmpty {
                        ContentUnavailableView(
                            "Aucune donnée",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Importe une base de données pour afficher les graphiques.")
                        )
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
            .navigationTitle("Finance")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environment(appState)
            }
            .task(id: appState.dataRefreshToken) { loadDashboard() }
        }
    }

    // MARK: Sections

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compte actif")
                .font(.caption).foregroundStyle(.secondary)
            Text(appState.selectedAccountName)
                .font(.title2).fontWeight(.bold)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solde sur la période")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(totalRecent, format: .currency(code: "EUR"))
                        .font(.title).fontWeight(.heavy)
                        .foregroundStyle(totalRecent >= 0 ? .green : .red)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Transactions")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(recentCount)")
                        .font(.title2).fontWeight(.semibold)
                }
            }

            Text("\(appState.filterFromDate.formatted(date: .abbreviated, time: .omitted)) – \(appState.filterToDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var monthlyChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Soldes par mois")
                .font(.headline)

            Chart(monthlyChartData) { point in
                BarMark(
                    x: .value("Mois", point.date, unit: .month),
                    y: .value("Montant", point.value)
                )
                .foregroundStyle(by: .value("Type", point.type))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(["Recettes": Color.green, "Dépenses": Color.red])
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var categoryChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top catégories")
                .font(.headline)

            Chart(categoryData, id: \.category) { item in
                BarMark(
                    x: .value("Montant", abs(item.total)),
                    y: .value("Catégorie", item.category)
                )
                .foregroundStyle(item.total < 0 ? Color.red : Color.green)
                .cornerRadius(3)
            }
            .frame(height: CGFloat(categoryData.count * 36 + 20))
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v, format: .currency(code: "EUR").presentation(.narrow))
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Data

    private func loadDashboard() {
        accounts = repository.fetchAccounts()
        if appState.selectedAccountId == nil, let first = accounts.first {
            appState.selectedAccountId   = first.id
            appState.selectedAccountName = first.name
        }
        guard let accountId = appState.selectedAccountId else {
            recentCount = 0; totalRecent = 0; monthlyData = []; categoryData = []
            return
        }
        let txs = repository.fetchTransactions(
            accountId: accountId, from: appState.filterFromDate, to: appState.filterToDate,
            limit: 5000, offset: 0
        )
        recentCount   = txs.count
        totalRecent   = txs.map(\.amount).reduce(0, +)
        monthlyData   = repository.fetchMonthlyTotals(accountId: accountId, from: appState.filterFromDate, to: appState.filterToDate)
        categoryData  = repository.fetchCategoryTotals(accountId: accountId, from: appState.filterFromDate, to: appState.filterToDate)
    }
}
