//
//  PatrimoineWidget.swift
//  NemorisWidget
//
//  Patrimoine net (actifs - dettes). Module gratuit dans l'app (seule la
//  Projection est Pro) — ce widget ne verrouille donc rien.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline entry & provider

struct PatrimoineEntry: TimelineEntry {
    let date: Date
    let data: PatrimoineWidgetData
}

struct PatrimoineProvider: AppIntentTimelineProvider {
    private static let appGroupID = "group.fr.hedwin.nemoris"
    private static let key = "nemoris.patrimoineWidgetData"

    func placeholder(in context: Context) -> PatrimoineEntry {
        PatrimoineEntry(date: Date(), data: .placeholder)
    }
    func snapshot(for configuration: PatrimoineWidgetIntent, in context: Context) async -> PatrimoineEntry {
        PatrimoineEntry(date: Date(), data: loadData())
    }
    func timeline(for configuration: PatrimoineWidgetIntent, in context: Context) async -> Timeline<PatrimoineEntry> {
        let entry = PatrimoineEntry(date: Date(), data: loadData())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
    private func loadData() -> PatrimoineWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(PatrimoineWidgetData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
}

// MARK: - Home screen view

struct PatrimoineWidgetView: View {
    let entry: PatrimoineEntry
    @Environment(\.widgetFamily) var family
    private var data: PatrimoineWidgetData { entry.data }

    var body: some View {
        if !data.hasData {
            EmptyModuleView(title: "Patrimoine", message: "Aucun actif ou bien suivi")
        } else {
            switch family {
            case .systemSmall: smallView
            default:           mediumView
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Patrimoine net")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(widgetFormattedAmount(data.netWorth))
                .font(.title2.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if data.totalLiabilities > 0 {
                HStack(spacing: 4) {
                    Label(widgetFormattedAmount(data.totalAssets), systemImage: "arrow.up")
                        .foregroundStyle(Color.nSuccess)
                    Label(widgetFormattedAmount(data.totalLiabilities), systemImage: "arrow.down")
                        .foregroundStyle(Color.nDanger)
                }
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Patrimoine net")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(widgetFormattedAmount(data.netWorth))
                    .font(.title3.bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                amtRow("Actifs", data.totalAssets, .nSuccess)
                amtRow("Dettes", data.totalLiabilities, .nDanger)
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

struct PatrimoineLockView: View {
    let entry: PatrimoineEntry
    @Environment(\.widgetFamily) var family
    private var data: PatrimoineWidgetData { entry.data }

    var body: some View {
        switch family {
        case .accessoryCircular:    circularView
        case .accessoryRectangular: rectangularView
        default:                    inlineView
        }
    }

    private var circularView: some View {
        VStack(spacing: 1) {
            Image(systemName: "house.fill")
                .font(.system(size: 12))
            Text(widgetFormattedAmount(data.netWorth))
                .font(.system(size: 11, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Patrimoine net")
                .font(.headline)
                .minimumScaleFactor(0.8)
            HStack {
                Text("Actifs").foregroundStyle(.secondary)
                Spacer()
                Text(widgetFormattedAmount(data.totalAssets)).fontWeight(.medium)
            }
            .font(.caption)
            HStack {
                Text("Dettes").foregroundStyle(.secondary)
                Spacer()
                Text(widgetFormattedAmount(data.totalLiabilities)).fontWeight(.medium)
            }
            .font(.caption)
        }
    }

    private var inlineView: some View {
        Label(widgetFormattedAmount(data.netWorth), systemImage: "house.fill")
    }
}

// MARK: - Widgets

struct PatrimoineWidget: Widget {
    let kind = "PatrimoineWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PatrimoineWidgetIntent.self, provider: PatrimoineProvider()) { entry in
            PatrimoineWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Patrimoine net")
        .description("Actifs, dettes et patrimoine net.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PatrimoineLockWidget: Widget {
    let kind = "PatrimoineLockWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PatrimoineWidgetIntent.self, provider: PatrimoineProvider()) { entry in
            PatrimoineLockView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Patrimoine (verrouillage)")
        .description("Patrimoine net sur l'écran de verrouillage.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemSmall) {
    PatrimoineWidget()
} timeline: {
    PatrimoineEntry(date: .now, data: .placeholder)
}

#Preview(as: .accessoryRectangular) {
    PatrimoineLockWidget()
} timeline: {
    PatrimoineEntry(date: .now, data: .placeholder)
}
