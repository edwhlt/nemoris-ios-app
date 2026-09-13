import Foundation

// MARK: - DashboardCardID
//
// The Dashboard's card registry. This is a **pure data enum** (no
// SwiftUI import): it describes what a card is, not how it's drawn.
// Rendering happens via a single `switch` in `DashboardCardHost`, the same way
// `MainTabView.tabView(for:)` already does for modules.
//
// **Why not a protocol + a type-erased registry**: storing closures that
// return a `View` would force isolating the registry on `@MainActor` (a view
// isn't `Sendable`), and the free `Sendable` conformance would be lost —
// needed for `dependencies` to cross the builder's `Task.detached` boundary.
//
// **Adding a card** = one `case` here + one line in `DashboardCardHost`'s
// `switch` + one content view. Nothing else: the default order,
// persistence and the customization screen follow automatically.

enum DashboardCardSize: String, Codable, Sendable, CaseIterable {
    case compact
    case wide

    var label: String {
        switch self {
        case .compact: return "Compacte"
        case .wide:    return "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .compact: return "rectangle.split.2x1"
        case .wide:    return "rectangle"
        }
    }
}

enum DashboardCardID: String, CaseIterable, Identifiable, Sendable, Codable {
    // ⚠️ THE DECLARATION ORDER IS THE GRID'S DEFAULT ORDER.
    // `DashboardLayoutStore.sanitize` appends any unknown card at the end of the
    // list, so a card added later will NOT slide into the middle of a
    // layout the user has already customized.
    case insightsCoach
    case budgetEnvelopes
    case netWorth
    case monthlyFlow
    case topCategories
    case tags
    case investments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insightsCoach:   return "Coach financier"
        case .budgetEnvelopes: return "Enveloppes"
        case .netWorth:        return "Patrimoine net"
        case .monthlyFlow:     return "Flux mensuel"
        case .topCategories:   return "Top dépenses"
        case .tags:            return "Tags"
        case .investments:     return "Investissements"
        }
    }

    var systemImage: String {
        switch self {
        case .insightsCoach:   return "lightbulb.fill"
        case .budgetEnvelopes: return "chart.bar.fill"
        case .netWorth:        return "house.fill"
        case .monthlyFlow:     return "chart.bar.xaxis"
        case .topCategories:   return "list.number"
        case .tags:            return "tag.fill"
        case .investments:     return "chart.line.uptrend.xyaxis"
        }
    }

    /// The module a card depends on. If the user disabled it in Settings,
    /// the card disappears from the grid (but its preference is kept: re-enabling
    /// it restores its position and size).
    ///
    /// Deliberately **no** additional paywall gate: in this app, it's the
    /// Settings module toggle that carries the entitlement, and the sensitive
    /// views already have their own `paywallOverlay`. Adding a second barrier here would
    /// hide numbers the user already sees in the "Overview" banner.
    var requiredModule: MainTabItem? {
        switch self {
        case .budgetEnvelopes: return .budget
        case .netWorth:        return .patrimoine
        case .investments:     return .investments
        default:               return nil
        }
    }

    /// A 12-bar chart or an insight list on half an iPhone's width
    /// (~170pt) is unreadable: these cards only exist in the wide size.
    var supportedSizes: [DashboardCardSize] {
        switch self {
        case .insightsCoach, .monthlyFlow: return [.wide]
        default:                           return [.compact, .wide]
        }
    }

    var defaultSize: DashboardCardSize {
        switch self {
        case .budgetEnvelopes, .netWorth, .investments: return .compact
        default:                                        return .wide
        }
    }

    /// A niche card starts hidden: otherwise every new version would add
    /// noise for everyone. `investments` is already summarized in the fixed banner.
    var isVisibleByDefault: Bool {
        self != .investments
    }

    /// The aggregates needed to render this card. This is what makes a
    /// hidden card truly free: its aggregates aren't computed.
    var dependencies: Set<DashboardAggregate> {
        switch self {
        case .insightsCoach:   return [.insights]
        case .budgetEnvelopes: return [.budgetEnvelopes]
        case .netWorth:        return [.patrimoine]
        case .monthlyFlow:     return [.yearSeries]
        case .topCategories:   return [.categoryBreakdown]
        case .tags:            return [.tagBreakdown]
        case .investments:     return [.investments]
        }
    }
}

// MARK: - DashboardCardPreference

/// A user preference for a card. Encoded as JSON in `UserDefaults`.
struct DashboardCardPreference: Codable, Hashable, Sendable, Identifiable {
    var card: DashboardCardID
    var isVisible: Bool
    var size: DashboardCardSize

    var id: DashboardCardID { card }

    init(card: DashboardCardID, isVisible: Bool, size: DashboardCardSize) {
        self.card = card
        self.isVisible = isVisible
        self.size = size
    }

    /// A card's default setting, as defined by the registry.
    init(defaultsFor card: DashboardCardID) {
        self.init(card: card, isVisible: card.isVisibleByDefault, size: card.defaultSize)
    }
}
