import SwiftUI
import Charts

// MARK: - Month parser (shared)

let dashboardMonthParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    return f
}()

// MARK: - MonthlyBarChartView

struct MonthlyBarChartView: View {
    let data: [MonthlyTotals]
    @Binding var selectedMonth: String?

    private struct BarPoint: Identifiable {
        let id = UUID()
        let date: Date
        let month: String
        let type: BarPointType
        let value: Double
    }
    
    enum BarPointType: String, Hashable, CaseIterable, Plottable {
        case income
        case expense

        var localizedResource: LocalizedStringResource {
            switch self {
            case .income: "Revenus"
            case .expense: "Dépenses"
            }
        }
    }

    private var points: [BarPoint] {
        data.flatMap { item -> [BarPoint] in
            guard let date = dashboardMonthParser.date(from: item.month) else { return [] }
            return [
                BarPoint(date: date, month: item.month, type: .income, value: item.income),
                BarPoint(date: date, month: item.month, type: .expense, value: item.expense)
            ]
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Mois", point.date, unit: .month),
                y: .value("Montant", point.value)
            )
            .foregroundStyle(by: .value("Type", point.type))
            .opacity(selectedMonth == nil || selectedMonth == point.month ? 1 : 0.3)
            .cornerRadius(4)
            .annotation(position: .top, alignment: .center, spacing: 2) {
                if selectedMonth == point.month {
                    Text(point.value, format: .currency(code: "EUR").presentation(.narrow))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(point.type == .expense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        .fixedSize()
                }
            }
        }
        .chartForegroundStyleScale([
            BarPointType.income: AppTheme.Colors.success,
            BarPointType.expense: AppTheme.Colors.danger
        ])
        .chartXAxis {
            // A general safeguard against unreadable labels (see
            // PeriodBarChartView below): even a range that looks
            // "reasonable" (several years of months) can accumulate too
            // many for the actual width — `.automatic` spaces them out instead of
            // placing one per month unconditionally.
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppTheme.Colors.surfaceSecondary)
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let date: Date = proxy.value(atX: location.x - geo[proxy.plotFrame!].minX) else { return }
                        let cal = Calendar.current
                        let comps = cal.dateComponents([.year, .month], from: date)
                        let tapped = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
                        withAnimation(AppTheme.Animations.springSnappy) {
                            selectedMonth = (selectedMonth == tapped) ? nil : tapped
                        }
                    }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 200)
        
        HStack(spacing: 8) {
            legendDot(color: AppTheme.Colors.success, label: BarPointType.income.localizedResource)
            legendDot(color: AppTheme.Colors.danger, label: BarPointType.expense.localizedResource)
        }
    }

    @ViewBuilder private func legendDot(color: Color, label: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
}

// MARK: - CategoryBarChartView

struct CategoryBarChartView: View {
    let data: [CategoryTotal]
    var expenseOnly: Bool = true
    var groupByParent: Bool = false

    private var filtered: [CategoryTotal] {
        expenseOnly ? data.filter { $0.total < 0 } : data
    }

    private var items: [CategoryTotal] {
        guard groupByParent else { return filtered }
        var dict: [String: Double] = [:]
        for item in filtered {
            let key = item.parentCategory ?? item.category
            dict[key, default: 0] += item.total
        }
        return dict
            .map { CategoryTotal(category: $0.key, parentCategory: nil, total: $0.value) }
            .sorted { abs($0.total) > abs($1.total) }
    }

    var body: some View {
        let displayItems = items
        Chart(displayItems, id: \.category) { item in
            BarMark(
                x: .value("Montant", abs(item.total)),
                y: .value("Catégorie", item.category)
            )
            .foregroundStyle(item.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                Text(item.total, format: .currency(code: "EUR").presentation(.narrow))
                    .font(.caption2)
                    .foregroundStyle(item.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .frame(height: max(CGFloat(displayItems.count * 42 + 16), 60))
    }
}

// MARK: - TagBarChartView

struct TagBarChartView: View {
    let data: [TagTotal]

    var body: some View {
        let items = data.prefix(10).map { $0 }
        Chart(items) { item in
            BarMark(
                x: .value("Montant", abs(item.total)),
                y: .value("Tag", item.tag.name)
            )
            .foregroundStyle(item.total < 0 ? AppTheme.Colors.warning : AppTheme.Colors.accentSecondary)
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                Text(item.total, format: .currency(code: "EUR").presentation(.narrow))
                    .font(.caption2)
                    .foregroundStyle(item.total < 0 ? AppTheme.Colors.warning : AppTheme.Colors.accentSecondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .frame(height: max(CGFloat(items.count * 42 + 16), 60))
    }
}

// MARK: - BalanceTimeChart

struct BalanceTimeChart: View {
    let periodData: [PeriodTotal]
    let balanceData: [DailyBalance]
    let granularity: ChartGranularity

    @State private var selectedPeriod: PeriodTotal? = nil
    @State private var selectedBalance: Double? = nil

    private var calUnit: Calendar.Component {
        switch granularity {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        }
    }

    private struct BarPoint: Identifiable {
        let id: String
        let date: Date
        let type: BarPointType
        let value: Double
    }
    
    enum BarPointType: String, Hashable, CaseIterable, Plottable {
        case income
        case expense

        var localizedResource: LocalizedStringResource {
            switch self {
            case .income: "Revenus"
            case .expense: "Dépenses"
            }
        }
    }

    private var barPoints: [BarPoint] {
        periodData.flatMap { p -> [BarPoint] in [
            BarPoint(id: "\(p.id.timeIntervalSince1970)-rec", date: p.id, type: .income, value: p.income),
            BarPoint(id: "\(p.id.timeIntervalSince1970)-dep", date: p.id, type: .expense, value: p.expense)
        ]}
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionHeader
            chartContent
            
            HStack(spacing: 8) {
                legendDot(color: AppTheme.Colors.success, label: BarPointType.income.localizedResource)
                legendDot(color: AppTheme.Colors.danger, label: BarPointType.expense.localizedResource)
            }
        }
        .onChange(of: granularity) { _, _ in
            selectedPeriod = nil
            selectedBalance = nil
        }
    }

    @ViewBuilder private func legendDot(color: Color, label: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
    
    @ViewBuilder
    private var selectionHeader: some View {
        if let period = selectedPeriod {
            HStack(spacing: 6) {
                periodLabel(period.id)
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                if period.income > 0.005 {
                    Label {
                        Text(period.income, format: .currency(code: "EUR").presentation(.narrow))
                    } icon: {
                        Image(systemName: "arrow.down")
                    }
                    .font(AppTheme.Typography.labelMedium)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.success)
                }
                if period.expense < -0.005 {
                    Label {
                        Text(abs(period.expense), format: .currency(code: "EUR").presentation(.narrow))
                    } icon: {
                        Image(systemName: "arrow.up")
                    }
                    .font(AppTheme.Typography.labelMedium)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.danger)
                }
                if let bal = selectedBalance {
                    Text("·").font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(bal, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.labelMedium)
                        .fontWeight(.bold)
                        .foregroundStyle(bal >= 0 ? AppTheme.Colors.accent : AppTheme.Colors.warning)
                }
                Button {
                    withAnimation(AppTheme.Animations.easeOut) {
                        selectedPeriod = nil
                        selectedBalance = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Colors.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(AppTheme.Animations.easeInOut, value: selectedPeriod?.id)
        }
    }

    private var chartContent: some View {
        Chart {
            ForEach(barPoints) { point in
                BarMark(
                    x: .value("Date", point.date, unit: calUnit),
                    y: .value("Montant", point.value)
                )
                .foregroundStyle(by: .value("Type", point.type))
                .cornerRadius(3)
                .opacity(selectedPeriod == nil || selectedPeriod?.id == point.date ? 1.0 : 0.25)
            }
            ForEach(balanceData) { day in
                LineMark(
                    x: .value("Date", day.id, unit: .day),
                    y: .value("Solde", day.balance)
                )
                .foregroundStyle(AppTheme.Colors.accent)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
            ForEach(balanceData) { day in
                AreaMark(
                    x: .value("Date", day.id, unit: .day),
                    y: .value("Solde", day.balance)
                )
                .foregroundStyle(AppTheme.Colors.accent.opacity(0.07))
                .interpolationMethod(.monotone)
            }
            if let sel = selectedPeriod {
                RuleMark(x: .value("Sélection", sel.id))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale([
            BarPointType.income: AppTheme.Colors.success,
            BarPointType.expense: AppTheme.Colors.danger
        ])
        .chartXAxis {
            // `.stride(by: calUnit)` placed ONE mark PER DAY at "day"
            // granularity — over a range of several months/a year, that stacks
            // hundreds of labels overlapping into an unreadable block.
            // `.automatic(desiredCount:)` lets Swift
            // Charts space labels out based on the width actually
            // available instead of placing one per unit — the same fix as
            // the Investments charts (see positionChart/EvolutionChart).
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: xAxisFormat)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppTheme.Colors.surfaceSecondary)
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(proxy: proxy, geo: geo, x: value.location.x)
                            }
                    )
            }
        }
        .frame(height: 220)
        .chartLegend(.hidden)
        .animation(AppTheme.Animations.easeInOut, value: selectedPeriod?.id)
    }

    private func updateSelection(proxy: ChartProxy, geo: GeometryProxy, x: CGFloat) {
        guard let plotFrame = proxy.plotFrame else { return }
        let xInPlot = x - geo[plotFrame].minX
        guard let date: Date = proxy.value(atX: xInPlot) else { return }

        let nearest = periodData.min(by: {
            abs($0.id.timeIntervalSince(date)) < abs($1.id.timeIntervalSince(date))
        })
        guard let p = nearest, p.id != selectedPeriod?.id else { return }
        selectedPeriod = p

        let cal = Calendar.current
        let periodEnd: Date
        switch granularity {
        case .day:   periodEnd = p.id.addingTimeInterval(86400)
        case .week:  periodEnd = cal.dateInterval(of: .weekOfYear, for: p.id)?.end ?? p.id.addingTimeInterval(604800)
        case .month: periodEnd = cal.dateInterval(of: .month, for: p.id)?.end ?? p.id
        }
        selectedBalance = balanceData.filter { $0.id < periodEnd }.max(by: { $0.id < $1.id })?.balance
    }

    private func periodLabel(_ date: Date) -> Text {
        switch granularity {
        case .day:   return Text(date, format: .dateTime.day().month(.abbreviated).year())
        case .week:  return Text("Sem. du ") + Text(date, format: .dateTime.day().month(.abbreviated).year())
        case .month: return Text(date, format: .dateTime.month(.wide).year())
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch granularity {
        case .day:   return .dateTime.day().month(.narrow)
        case .week:  return .dateTime.day().month(.narrow)
        case .month: return .dateTime.month(.narrow)
        }
    }
}

// MARK: - DashboardSummaryCard (updated with AppTheme)

struct DashboardSummaryCard: View {
    let stats: DashboardStats
    let title: String
    let subtitle: String

    var body: some View {
        PremiumDashboardSummaryCard(stats: stats, title: title, subtitle: subtitle)
    }
}

// MARK: - ChartCard (updated with AppTheme)

struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        AppChartCard(title: title, subtitle: subtitle) {
            content()
        }
    }
}
