//
//  TricountWidget.swift
//  NemorisWidget
//
//  Solde net d'un groupe Tricount ("on vous doit" / "vous devez"). Module
//  entièrement gratuit dans l'app — ce widget ne verrouille rien.
//
//  Sans groupe choisi : affiche celui dont le solde absolu est le plus élevé
//  (le plus "actionnable"), pas une somme des groupes — des devises
//  différentes par groupe rendraient une somme globale trompeuse.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline entry & provider

struct TricountEntry: TimelineEntry {
    let date: Date
    let data: TricountWidgetData
    let configuration: WidgetTricountIntent

    /// Le groupe à afficher : celui choisi en configuration, sinon celui au
    /// solde absolu le plus élevé.
    var selected: TricountGroupWidgetItem? {
        if let id = configuration.group?.id, let match = data.groups.first(where: { $0.id == id }) {
            return match
        }
        return data.groups.max { abs($0.netBalance) < abs($1.netBalance) }
    }
}

struct TricountProvider: AppIntentTimelineProvider {
    private static let appGroupID = "group.fr.hedwin.nemoris"
    private static let key = "nemoris.tricountWidgetData"

    func placeholder(in context: Context) -> TricountEntry {
        TricountEntry(date: Date(), data: .placeholder, configuration: WidgetTricountIntent())
    }
    func snapshot(for configuration: WidgetTricountIntent, in context: Context) async -> TricountEntry {
        TricountEntry(date: Date(), data: loadData(), configuration: configuration)
    }
    func timeline(for configuration: WidgetTricountIntent, in context: Context) async -> Timeline<TricountEntry> {
        let entry = TricountEntry(date: Date(), data: loadData(), configuration: configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
    private func loadData() -> TricountWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(TricountWidgetData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
}

// MARK: - Home screen view

struct TricountWidgetView: View {
    let entry: TricountEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        guard let group = entry.selected else {
            return AnyView(EmptyModuleView(title: "Tricount", message: "Aucun groupe chargé"))
        }
        switch family {
        case .systemSmall: return AnyView(smallView(group))
        default:           return AnyView(mediumView)
        }
    }

    // fileprivate (pas private) : `TricountWidget` construit cette vue via
    // l'init memberwise synthétisé (`entry:` seul, les autres gardent leur
    // défaut) depuis le même fichier mais un type différent — `private`
    // aurait rendu cet init synthétisé inaccessible (SE-0169 : `private`
    // se limite au type déclarant + ses extensions, pas au fichier entier).
    fileprivate var balanceColor: (TricountGroupWidgetItem) -> Color = { $0.netBalance >= 0 ? .nSuccess : .nDanger }

    private func statusLabel(_ group: TricountGroupWidgetItem) -> String {
        if abs(group.netBalance) < 0.01 { return "à jour" }
        return group.netBalance > 0 ? "on vous doit" : "vous devez"
    }

    private func smallView(_ group: TricountGroupWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(widgetFormattedAmount(abs(group.netBalance)))
                .font(.title2.bold())
                .foregroundStyle(balanceColor(group))
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(statusLabel(group))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Groupe précis choisi en configuration → version agrandie. Sans
    /// sélection → liste des groupes les plus significatifs (vue d'ensemble).
    private var mediumView: some View {
        Group {
            if entry.configuration.group != nil, let group = entry.selected {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(widgetFormattedAmount(abs(group.netBalance)))
                            .font(.title3.bold())
                            .foregroundStyle(balanceColor(group))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(statusLabel(group))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tricount")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(topGroups, id: \.id) { g in
                        HStack {
                            Text(g.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(widgetFormattedAmount(g.netBalance, signed: true))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(balanceColor(g))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private var topGroups: [TricountGroupWidgetItem] {
        Array(entry.data.groups.sorted { abs($0.netBalance) > abs($1.netBalance) }.prefix(4))
    }
}

// MARK: - Lock screen view

struct TricountLockView: View {
    let entry: TricountEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        guard let group = entry.selected else {
            return AnyView(Label("Tricount", systemImage: "person.2.fill"))
        }
        switch family {
        case .accessoryRectangular:
            return AnyView(rectangularView(group))
        default:
            return AnyView(inlineView(group))
        }
    }

    private func rectangularView(_ group: TricountGroupWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title)
                .font(.headline)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text(widgetFormattedAmount(group.netBalance, signed: true))
                .font(.caption.weight(.semibold))
                .foregroundStyle(group.netBalance >= 0 ? Color.nSuccess : Color.nDanger)
        }
    }

    private func inlineView(_ group: TricountGroupWidgetItem) -> some View {
        Label(widgetFormattedAmount(group.netBalance, signed: true), systemImage: "person.2.fill")
    }
}

// MARK: - Widgets

struct TricountWidget: Widget {
    let kind = "TricountWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WidgetTricountIntent.self, provider: TricountProvider()) { entry in
            TricountWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Tricount")
        .description("Solde net d'un groupe partagé.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TricountLockWidget: Widget {
    let kind = "TricountLockWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WidgetTricountIntent.self, provider: TricountProvider()) { entry in
            TricountLockView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Tricount (verrouillage)")
        .description("Solde net d'un groupe sur l'écran de verrouillage.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemSmall) {
    TricountWidget()
} timeline: {
    TricountEntry(date: .now, data: .placeholder, configuration: WidgetTricountIntent())
}

#Preview(as: .accessoryRectangular) {
    TricountLockWidget()
} timeline: {
    TricountEntry(date: .now, data: .placeholder, configuration: WidgetTricountIntent())
}
