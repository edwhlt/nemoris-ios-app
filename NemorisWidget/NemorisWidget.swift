//
//  NemorisWidget.swift
//  NemorisWidget
//
//  Created by Edwin Helet on 20/05/2026.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct BalanceEntry: TimelineEntry {
    let date: Date
    let accountData: AccountWidgetData
    let configuration: WidgetAccountIntent
}

// MARK: - Provider

struct BalanceProvider: AppIntentTimelineProvider {
    private static let appGroupID    = "group.fr.hedwin.nemoris"
    private static let allAccountsKey = "nemoris.allAccountsData"

    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), accountData: AllAccountsData.placeholder.combined, configuration: WidgetAccountIntent())
    }

    func snapshot(for configuration: WidgetAccountIntent, in context: Context) async -> BalanceEntry {
        BalanceEntry(date: Date(), accountData: resolvedData(for: configuration), configuration: configuration)
    }

    func timeline(for configuration: WidgetAccountIntent, in context: Context) async -> Timeline<BalanceEntry> {
        let entry = BalanceEntry(date: Date(), accountData: resolvedData(for: configuration), configuration: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func resolvedData(for configuration: WidgetAccountIntent) -> AccountWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.allAccountsKey),
              let all = try? JSONDecoder().decode(AllAccountsData.self, from: data) else {
            return AllAccountsData.placeholder.combined
        }
        if let selected = configuration.account,
           let match = all.accounts.first(where: { $0.id == selected.id }) {
            return match
        }
        return all.combined
    }
}

// MARK: - Chart

struct MonthlyBarChart: View {
    let history: [MonthData]

    private var maxValue: Double {
        history.flatMap { [$0.income, $0.expense] }.max() ?? 1
    }

    var body: some View {
        GeometryReader { geo in
            let count = history.count
            let totalWidth = geo.size.width
            let barGroupWidth = count > 0 ? totalWidth / CGFloat(count) : totalWidth
            let barWidth = barGroupWidth * 0.35
            let gap = barWidth * 0.3

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(history, id: \.month) { m in
                    VStack(spacing: 0) {
                        HStack(alignment: .bottom, spacing: gap) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.nSuccess.opacity(0.85))
                                .frame(width: barWidth, height: barHeight(m.income, total: geo.size.height))

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.nDanger.opacity(0.85))
                                .frame(width: barWidth, height: barHeight(m.expense, total: geo.size.height))
                        }
                        Text(m.shortMonth)
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func barHeight(_ value: Double, total: CGFloat) -> CGFloat {
        let labelHeight: CGFloat = 12
        let available = total - labelHeight
        guard maxValue > 0 else { return 2 }
        return max(2, CGFloat(value / maxValue) * available)
    }
}

// MARK: - Balance Widget view

struct NemorisWidgetEntryView: View {
    var entry: BalanceEntry
    @Environment(\.widgetFamily) var family

    private var data: AccountWidgetData { entry.accountData }

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(data.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(formatted(data.netBalance))
                .font(.title2.bold())
                .foregroundStyle(data.netBalance >= 0 ? Color.nSuccess : Color.nDanger)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(spacing: 4) {
                Label(formatted(data.monthIncome), systemImage: "arrow.up")
                    .foregroundStyle(Color.nSuccess)
                Label(formatted(data.monthExpense), systemImage: "arrow.down")
                    .foregroundStyle(Color.nDanger)
            }
            .font(.system(size: 9))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(data.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(formatted(data.netBalance))
                    .font(.title3.bold())
                    .foregroundStyle(data.netBalance >= 0 ? Color.nSuccess : Color.nDanger)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Label(formatted(data.monthIncome), systemImage: "arrow.up")
                        .foregroundStyle(Color.nSuccess)
                    Label(formatted(data.monthExpense), systemImage: "arrow.down")
                        .foregroundStyle(Color.nDanger)
                }
                .font(.caption2)
                .lineLimit(1)
            }
            .frame(maxWidth: 130, maxHeight: .infinity, alignment: .leading)

            if !data.monthlyHistory.isEmpty {
                MonthlyBarChart(history: data.monthlyHistory)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func formatted(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        if abs >= 1_000 {
            return "\(sign)\(String(format: "%.0f", abs / 1_000))k€"
        }
        return "\(sign)\(String(format: "%.0f", abs))€"
    }
}

// MARK: - Balance Widget

struct NemorisWidget: Widget {
    let kind: String = "NemorisWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WidgetAccountIntent.self, provider: BalanceProvider()) { entry in
            NemorisWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Solde mensuel")
        .description("Dépenses et revenus du mois en cours.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    NemorisWidget()
} timeline: {
    BalanceEntry(date: .now, accountData: AllAccountsData.placeholder.combined, configuration: WidgetAccountIntent())
}

#Preview(as: .systemMedium) {
    NemorisWidget()
} timeline: {
    BalanceEntry(date: .now, accountData: AllAccountsData.placeholder.combined, configuration: WidgetAccountIntent())
}

// MARK: - Budget Timeline Entry & Provider

struct BudgetEntry: TimelineEntry {
    let date: Date
    let data: BudgetWidgetData
    let configuration: BudgetWidgetIntent
    /// Le module Budget est Pro dans son ensemble (`AppFeature.budget`) — un
    /// widget déjà posé sur l'écran d'accueil ne doit pas continuer à fuiter les
    /// montants si l'abonnement expire. Résolu à chaque timeline, jamais mis en
    /// cache localement (cf. `WidgetAccessGate`).
    var isLocked: Bool = false
}

struct BudgetProvider: AppIntentTimelineProvider {
    private static let appGroupID = "group.fr.hedwin.nemoris"
    private static let budgetKey  = "nemoris.budgetWidgetData"

    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: Date(), data: .placeholder, configuration: BudgetWidgetIntent())
    }
    func snapshot(for configuration: BudgetWidgetIntent, in context: Context) async -> BudgetEntry {
        let isPro = WidgetAccessGate.isPro(await WidgetAccessGate.currentAccessLevel())
        return BudgetEntry(date: Date(), data: loadData(), configuration: configuration, isLocked: !isPro)
    }
    func timeline(for configuration: BudgetWidgetIntent, in context: Context) async -> Timeline<BudgetEntry> {
        let isPro = WidgetAccessGate.isPro(await WidgetAccessGate.currentAccessLevel())
        let entry = BudgetEntry(date: Date(), data: loadData(), configuration: configuration, isLocked: !isPro)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
    private func loadData() -> BudgetWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.budgetKey),
              let budget = try? JSONDecoder().decode(BudgetWidgetData.self, from: data) else {
            return .placeholder
        }
        return budget
    }
}

// MARK: - Budget Arc (home screen)

private struct BudgetArcView: View {
    let ratio: Double
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(ratio, 1.0))
                .stroke(arcColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(min(ratio, 1.0) * 100))%")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundStyle(arcColor)
                Text("utilisé")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var arcColor: Color {
        ratio > 1 ? .nDanger : (ratio > 0.8 ? .nWarning : .nAccent)
    }
}

// MARK: - Budget Widget Views

struct BudgetWidgetView: View {
    let entry: BudgetEntry
    @Environment(\.widgetFamily) var family
    private var data: BudgetWidgetData { entry.data }

    var body: some View {
        if entry.isLocked {
            WidgetLockedView(title: "Budget mensuel")
        } else {
            switch family {
            case .systemSmall: smallView
            default:           mediumView
            }
        }
    }

    private var smallView: some View {
        VStack(spacing: 6) {
            Text("Budget")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            BudgetArcView(ratio: data.ratio)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 2) {
                Text(fmt(data.actualExpenses))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(data.isOverBudget ? Color.nDanger : Color.primary)
                Text("/ \(fmt(data.forecastedExpenses))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                BudgetArcView(ratio: data.ratio)
                    .frame(width: 72, height: 72)
                HStack(spacing: 2) {
                    Text(fmt(data.actualExpenses))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(data.isOverBudget ? Color.nDanger : Color.primary)
                    Text("/\(fmt(data.forecastedExpenses))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if !data.envelopes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.envelopes.prefix(4), id: \.name) { env in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(env.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("\(Int(env.ratio * 100))%")
                                    .font(.system(size: 9))
                                    .foregroundStyle(env.isOver ? Color.nDanger : Color.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 4)
                                    Capsule()
                                        .fill(env.isOver ? Color.nDanger : Color.nAccent)
                                        .frame(width: geo.size.width * env.ratio, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    amtRow("Prévu",  data.forecastedExpenses, .secondary)
                    amtRow("Réel",   data.actualExpenses, data.isOverBudget ? .nDanger : .nSuccess)
                    amtRow(data.isOverBudget ? "Dépassement" : "Économie", abs(data.variance),
                           data.isOverBudget ? .nDanger : .nSuccess)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    private func amtRow(_ label: String, _ amount: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(fmt(amount)).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }
    private func fmt(_ v: Double) -> String {
        let a = Swift.abs(v)
        return a >= 1_000 ? "\(String(format: "%.0f", a/1_000))k€" : "\(String(format: "%.0f", a))€"
    }
}

// MARK: - Budget Lock Screen Views

struct BudgetLockView: View {
    let entry: BudgetEntry
    @Environment(\.widgetFamily) var family
    private var data: BudgetWidgetData { entry.data }
    private var ratio: Double { min(data.ratio, 1.0) }

    var body: some View {
        if entry.isLocked {
            WidgetLockedView(title: "Budget mensuel")
        } else {
            switch family {
            case .accessoryCircular:    circularView
            case .accessoryRectangular: rectangularView
            default:                    inlineView
            }
        }
    }

    private var circularView: some View {
        Gauge(value: ratio) {
            Image(systemName: "chart.bar.fill")
        } currentValueLabel: {
            Text("\(Int(ratio * 100))%")
                .font(.system(size: 10, weight: .semibold))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Budget mensuel")
                .font(.headline)
                .minimumScaleFactor(0.8)
            HStack {
                Text("Prévu").foregroundStyle(.secondary)
                Spacer()
                Text(fmt(data.forecastedExpenses)).fontWeight(.medium)
            }
            .font(.caption)
            HStack {
                Text("Réel").foregroundStyle(.secondary)
                Spacer()
                Text(fmt(data.actualExpenses))
                    .fontWeight(.semibold)
                    .foregroundStyle(data.isOverBudget ? .red : .primary)
            }
            .font(.caption)
        }
    }

    private var inlineView: some View {
        Label("\(fmt(data.actualExpenses)) / \(fmt(data.forecastedExpenses))", systemImage: "chart.bar.fill")
    }

    private func fmt(_ v: Double) -> String {
        let a = Swift.abs(v)
        return a >= 1_000 ? "\(String(format: "%.0f", a/1_000))k€" : "\(String(format: "%.0f", a))€"
    }
}

// MARK: - Budget Widgets

struct BudgetWidget: Widget {
    let kind = "BudgetWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: BudgetWidgetIntent.self, provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Budget mensuel")
        .description("Dépenses réelles vs budget prévisionnel du mois.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BudgetLockWidget: Widget {
    let kind = "BudgetLockWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: BudgetWidgetIntent.self, provider: BudgetProvider()) { entry in
            BudgetLockView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Budget (verrouillage)")
        .description("Aperçu rapide de votre budget sur l'écran de verrouillage.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemSmall) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, data: .placeholder, configuration: BudgetWidgetIntent())
}

#Preview(as: .accessoryRectangular) {
    BudgetLockWidget()
} timeline: {
    BudgetEntry(date: .now, data: .placeholder, configuration: BudgetWidgetIntent())
}
