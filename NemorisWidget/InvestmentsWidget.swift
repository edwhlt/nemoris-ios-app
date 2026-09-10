//
//  InvestmentsWidget.swift
//  NemorisWidget
//
//  Valeur totale du portefeuille + plus-value. Module gratuit dans l'app
//  (seule la Live Sync est Pro) — ce widget ne verrouille donc rien.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline entry & provider

struct InvestmentsEntry: TimelineEntry {
    let date: Date
    let data: InvestmentsWidgetData
    let range: InvestmentsWidgetRange
}

struct InvestmentsProvider: AppIntentTimelineProvider {
    private static let appGroupID = "group.fr.hedwin.nemoris"
    private static let key = "nemoris.investmentsWidgetData"

    func placeholder(in context: Context) -> InvestmentsEntry {
        InvestmentsEntry(date: Date(), data: .placeholder, range: .day)
    }
    func snapshot(for configuration: InvestmentsWidgetIntent, in context: Context) async -> InvestmentsEntry {
        InvestmentsEntry(date: Date(), data: loadData(), range: configuration.range)
    }
    func timeline(for configuration: InvestmentsWidgetIntent, in context: Context) async -> Timeline<InvestmentsEntry> {
        let entry = InvestmentsEntry(date: Date(), data: loadData(), range: configuration.range)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
    private func loadData() -> InvestmentsWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(InvestmentsWidgetData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
}

// MARK: - Home screen view

struct InvestmentsWidgetView: View {
    let entry: InvestmentsEntry
    @Environment(\.widgetFamily) var family
    private var data: InvestmentsWidgetData { entry.data }
    private var pnl: (abs: Double, percent: Double, isRangeSpecific: Bool) { data.pnl(for: entry.range) }

    var body: some View {
        if !data.hasData {
            EmptyModuleView(title: "Investissements", message: "Aucune position suivie")
        } else {
            switch family {
            case .systemSmall: smallView
            default:           mediumView
            }
        }
    }

    private var pnlColor: Color { pnl.abs >= 0 ? .nSuccess : .nDanger }

    /// "1J"/"1S"/"1M" quand la variation affichée porte vraiment sur la plage
    /// choisie ; sinon (repli sur la plus-value totale) rien, pour ne pas
    /// afficher un intervalle qui ne correspond pas au chiffre montré.
    private var rangeSuffix: String { pnl.isRangeSpecific ? " · \(entry.range.rawValue)" : "" }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Portefeuille\(rangeSuffix)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(widgetFormattedAmount(data.totalValue))
                .font(.title2.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(spacing: 3) {
                Image(systemName: pnl.abs >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(widgetFormattedAmount(pnl.abs, signed: true))
                Text(String(format: "(%@%.1f %%)", pnl.abs >= 0 ? "+" : "", pnl.percent))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(pnlColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Portefeuille\(rangeSuffix)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(widgetFormattedAmount(data.totalValue))
                    .font(.title3.bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: pnl.abs >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(widgetFormattedAmount(pnl.abs, signed: true))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(pnlColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                amtRow("Investi", data.totalValue - data.pnlAbsolute, .secondary)
                amtRow(pnl.isRangeSpecific ? "Variation \(entry.range.rawValue)" : "Plus-value", pnl.abs, pnlColor)
                Text(String(format: "%@%.1f %%", pnl.abs >= 0 ? "+" : "", pnl.percent))
                    .font(.caption2)
                    .foregroundStyle(pnlColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func amtRow(_ label: String, _ amount: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(widgetFormattedAmount(amount)).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }
}

// MARK: - Lock screen view

struct InvestmentsLockView: View {
    let entry: InvestmentsEntry
    @Environment(\.widgetFamily) var family
    private var data: InvestmentsWidgetData { entry.data }
    private var pnl: (abs: Double, percent: Double, isRangeSpecific: Bool) { data.pnl(for: entry.range) }

    var body: some View {
        switch family {
        case .accessoryCircular:    circularView
        case .accessoryRectangular: rectangularView
        default:                    inlineView
        }
    }

    private var circularView: some View {
        VStack(spacing: 1) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 12))
            Text(widgetFormattedAmount(data.totalValue))
                .font(.system(size: 11, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Portefeuille")
                .font(.headline)
                .minimumScaleFactor(0.8)
            Text(widgetFormattedAmount(data.totalValue))
                .font(.caption.weight(.semibold))
            Text(String(format: "%@%.1f %% (%@)", pnl.abs >= 0 ? "+" : "", pnl.percent, entry.range.rawValue))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var inlineView: some View {
        Label(widgetFormattedAmount(data.totalValue), systemImage: "chart.line.uptrend.xyaxis")
    }
}

// MARK: - Widgets

struct InvestmentsWidget: Widget {
    let kind = "InvestmentsWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: InvestmentsWidgetIntent.self, provider: InvestmentsProvider()) { entry in
            InvestmentsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Portefeuille")
        .description("Valeur totale et plus-value de vos investissements.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct InvestmentsLockWidget: Widget {
    let kind = "InvestmentsLockWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: InvestmentsWidgetIntent.self, provider: InvestmentsProvider()) { entry in
            InvestmentsLockView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Portefeuille (verrouillage)")
        .description("Valeur de votre portefeuille sur l'écran de verrouillage.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemSmall) {
    InvestmentsWidget()
} timeline: {
    InvestmentsEntry(date: .now, data: .placeholder, range: .week)
}

#Preview(as: .accessoryRectangular) {
    InvestmentsLockWidget()
} timeline: {
    InvestmentsEntry(date: .now, data: .placeholder, range: .week)
}
